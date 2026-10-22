import AppKit
import Foundation
import os
import WebKit

enum FetchLog {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.example.CalvinWidget",
        category: "fetch"
    )

    /// `notice` is the default log level, so `log show` shows it without `--info`.
    static func note(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}

struct StripFailure: Error {
    var message: String
    var detail: String
}

/// Loads the GoComics page in a visible WKWebView so BunnyCDN's JavaScript check can run,
/// then downloads the strip image from featureassets.gocomics.com.
@MainActor
enum StripWebLoader {
    static func loadLatest(
        using browser: StripBrowser,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> Result<CachedStrip, StripFailure> {
        await browser.ensureVisible()
        let today = calendar.startOfDay(for: now)
        FetchLog.note("fetch start today=\(StripStore.dayString(today, calendar: calendar))")

        let todayOutcome = await load(day: today, now: now, browser: browser, calendar: calendar)
        if case .strip(let strip) = todayOutcome {
            return .success(strip)
        }

        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
            return .failure(failure(from: todayOutcome, also: nil))
        }
        FetchLog.note("fetch retry yesterday=\(StripStore.dayString(yesterday, calendar: calendar))")
        let yesterdayOutcome = await load(day: yesterday, now: now, browser: browser, calendar: calendar)
        if case .strip(let strip) = yesterdayOutcome {
            return .success(strip)
        }
        return .failure(failure(from: todayOutcome, also: yesterdayOutcome))
    }

    private enum DayOutcome {
        case strip(CachedStrip)
        case failed(detail: String)
    }

    private static func failure(from first: DayOutcome, also second: DayOutcome?) -> StripFailure {
        var lines: [String] = []
        if case .failed(let detail) = first {
            lines.append("Today: \(detail)")
        }
        if let second, case .failed(let detail) = second {
            lines.append("Yesterday: \(detail)")
        }
        let detail = lines.joined(separator: " ")
        let message: String
        if detail.contains("browser check") {
            message = "GoComics is still running its browser check. Leave the page on screen and try Refresh."
        } else if detail.contains("download") {
            message = "The strip address was found, but the image did not download."
        } else {
            message = "GoComics didn't return a strip for today or yesterday. It may not be posted yet, or the page layout may have changed."
        }
        return StripFailure(message: message, detail: detail.isEmpty ? "Step: unknown." : detail)
    }

    private static func load(
        day: Date,
        now: Date,
        browser: StripBrowser,
        calendar: Calendar
    ) async -> DayOutcome {
        let page = StripStore.pageURL(for: day, calendar: calendar)
        let label = StripStore.dayString(day, calendar: calendar)
        browser.load(page)

        let deadline = Date().addingTimeInterval(70)
        var realPageSeenAt: Date?
        var lastDetail = "Step: browser check. No page snapshot yet."
        var loggedDownload = false

        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let snapshot = await browser.snapshot() else {
                lastDetail = "Step: browser check. The page did not answer JavaScript."
                continue
            }
            let dates = StripHTML.describeJSONLD(html: snapshot.html)
            FetchLog.note(
                "snapshot day=\(label) challenge=\(snapshot.isChallenge) title=\(clip(snapshot.title)) href=\(clip(snapshot.href)) og=\(clip(snapshot.ogImage)) jsonld=\(dates)"
            )
            if snapshot.isChallenge {
                realPageSeenAt = nil
                lastDetail = "Step: browser check. Last title: \(clip(snapshot.title)). Last URL: \(clip(snapshot.href))."
                continue
            }
            if realPageSeenAt == nil {
                realPageSeenAt = Date()
            }
            guard let parsed = StripHTML.extractBest(html: snapshot.html, preferredDay: day, calendar: calendar) else {
                lastDetail = "Step: find image. Page loaded at \(clip(snapshot.href)) but no recent strip URL. og:image=\(clip(snapshot.ogImage)). JSON-LD: \(dates)."
                if let realPageSeenAt, Date().timeIntervalSince(realPageSeenAt) > 12 {
                    FetchLog.note("extract day=\(label) none")
                    return .failed(detail: lastDetail)
                }
                continue
            }
            let stripDay = parsed.day ?? day
            FetchLog.note(
                "extract day=\(label) source=\(parsed.source) image=\(parsed.imageURL.absoluteString) stripDay=\(StripStore.dayString(stripDay, calendar: calendar))"
            )
            let download = await StripLoader.downloadImage(from: parsed.imageURL, referer: page)
            FetchLog.note("download \(download.note) url=\(parsed.imageURL.absoluteString)")
            loggedDownload = true
            if let jpeg = download.jpeg {
                let isToday = calendar.isDate(stripDay, inSameDayAs: now)
                return .strip(CachedStrip(
                    pageURL: StripStore.pageURL(for: stripDay, calendar: calendar),
                    day: calendar.startOfDay(for: stripDay),
                    imageData: jpeg,
                    usedPreviousDay: !isToday,
                    fetchedAt: Date()
                ))
            }
            lastDetail = "Step: download. \(download.note). URL: \(parsed.imageURL.absoluteString)."
            if let realPageSeenAt, Date().timeIntervalSince(realPageSeenAt) > 12 {
                return .failed(detail: lastDetail)
            }
        }
        if !loggedDownload, realPageSeenAt == nil {
            return .failed(detail: lastDetail)
        }
        return .failed(detail: lastDetail)
    }

    private static func clip(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        if flat.count <= 180 { return flat.isEmpty ? "(empty)" : flat }
        return String(flat.prefix(180))
    }
}

final class StripBrowserHostView: NSView {
    weak var browser: StripBrowser?

}

@MainActor
final class StripBrowser: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var fallbackWindow: NSWindow?
    private weak var hostView: StripBrowserHostView?
    private var closed = false

    private static let script = """
    (function() {
      function content(selector) {
        var node = document.querySelector(selector);
        return node ? (node.getAttribute('content') || '') : '';
      }
      var scripts = [];
      var nodes = document.querySelectorAll('script[type="application/ld+json"]');
      for (var i = 0; i < nodes.length; i++) {
        scripts.push(nodes[i].textContent || '');
      }
      var title = document.title || '';
      var href = location.href || '';
      var ogImage = content('meta[property="og:image"]');
      var hasFeature = ogImage.indexOf('featureassets.gocomics.com') !== -1;
      var markers = title.indexOf('Establishing a secure') !== -1
        || href.indexOf('about:blank') === 0
        || href.indexOf('bunny-shield') !== -1
        || !!document.querySelector('[data-pow], script[src*="bunny-shield"]');
      return JSON.stringify({
        challenge: markers && !hasFeature,
        title: title,
        href: href,
        ogImage: ogImage,
        twitterImage: content('meta[name="twitter:image"]'),
        vfImage: content('meta[property="vf:image"]'),
        ogURL: content('meta[property="og:url"]'),
        ogTitle: content('meta[property="og:title"]'),
        scripts: scripts
      });
    })()
    """

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 640), configuration: configuration)
        webView.customUserAgent = StripLoader.userAgent
        super.init()
        webView.navigationDelegate = self
    }

    func attach(to host: StripBrowserHostView) {
        guard !closed else { return }
        hostView = host
        host.browser = self
        if webView.superview !== host {
            webView.removeFromSuperview()
            fallbackWindow?.orderOut(nil)
            host.addSubview(webView)
            webView.autoresizingMask = [.width, .height]
        }
        fit(in: host)
    }

    func fit(in host: NSView) {
        guard !closed, webView.superview === host else { return }
        webView.frame = host.bounds
    }

    /// WebKit does not run the challenge script in a tiny, translucent, or off-screen window.
    func ensureVisible() async {
        guard !closed else { return }
        for _ in 0..<10 {
            if hostedOnScreen() {
                if let hostView {
                    fit(in: hostView)
                }
                FetchLog.note("browser visible in app window \(sizeText)")
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        showFallbackWindow()
    }

    func load(_ url: URL) {
        guard !closed else { return }
        FetchLog.note("load \(url.absoluteString)")
        webView.load(URLRequest(url: url))
    }

    func shutdown() {
        closed = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        fallbackWindow?.orderOut(nil)
        fallbackWindow = nil
    }

    func snapshot() async -> PageSnapshot? {
        guard !closed else { return nil }
        let result: Any?
        do {
            result = try await webView.evaluateJavaScript(Self.script)
        } catch {
            FetchLog.note("snapshot error \(error.localizedDescription)")
            return nil
        }
        guard let json = result as? String, let data = json.data(using: .utf8) else {
            FetchLog.note("snapshot returned \(String(describing: type(of: result as Any)))")
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            FetchLog.note("snapshot json parse failed")
            return nil
        }
        return PageSnapshot(
            isChallenge: object["challenge"] as? Bool ?? false,
            href: object["href"] as? String ?? "",
            title: object["title"] as? String ?? "",
            ogImage: object["ogImage"] as? String ?? "",
            html: Self.html(from: object)
        )
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        FetchLog.note("navigation start \(webView.url?.absoluteString ?? "")")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        FetchLog.note("navigation commit \(webView.url?.absoluteString ?? "")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        FetchLog.note("navigation finish \(webView.url?.absoluteString ?? "") title=\(webView.title ?? "")")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FetchLog.note("navigation fail \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            FetchLog.note("navigation cancelled")
            return
        }
        FetchLog.note("navigation provisional fail \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let status = (navigationResponse.response as? HTTPURLResponse)?.statusCode ?? -1
        let url = navigationResponse.response.url?.absoluteString ?? ""
        FetchLog.note("response \(status) \(url)")
        decisionHandler(.allow)
    }

    private var sizeText: String {
        let bounds = hostView?.bounds ?? .zero
        return "\(Int(bounds.width))x\(Int(bounds.height))"
    }

    private func hostedOnScreen() -> Bool {
        guard let host = hostView, let window = host.window, !window.isMiniaturized else { return false }
        guard host.bounds.width > 240, host.bounds.height > 160 else { return false }
        window.orderFrontRegardless()
        return true
    }

    private func showFallbackWindow() {
        guard !closed else { return }
        let window: NSWindow
        if let fallbackWindow {
            window = fallbackWindow
        } else {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            created.title = "Opening GoComics"
            created.isReleasedWhenClosed = false
            created.alphaValue = 1
            created.isOpaque = true
            created.level = .normal
            fallbackWindow = created
            window = created
        }
        webView.removeFromSuperview()
        window.contentView = webView
        window.center()
        window.orderFrontRegardless()
        NSApp.activate()
        FetchLog.note("browser visible in Opening GoComics window")
    }

    private static func html(from object: [String: Any]) -> String {
        var parts: [String] = ["<html><head>"]
        func meta(attribute: String, name: String, key: String) {
            guard let value = object[key] as? String, !value.isEmpty else { return }
            parts.append("<meta \(attribute)=\"\(escape(name))\" content=\"\(escape(value))\">")
        }
        meta(attribute: "property", name: "og:image", key: "ogImage")
        meta(attribute: "name", name: "twitter:image", key: "twitterImage")
        meta(attribute: "property", name: "vf:image", key: "vfImage")
        meta(attribute: "property", name: "og:url", key: "ogURL")
        meta(attribute: "property", name: "og:title", key: "ogTitle")
        if let href = object["href"] as? String, !href.isEmpty {
            parts.append("<link rel=\"canonical\" href=\"\(escape(href))\">")
        }
        if let scripts = object["scripts"] as? [String] {
            for script in scripts {
                let safe = script.replacingOccurrences(of: "</", with: "<\\/")
                parts.append("<script type=\"application/ld+json\">\(safe)</script>")
            }
        }
        parts.append("</head></html>")
        return parts.joined()
    }

    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }
}

struct PageSnapshot {
    var isChallenge: Bool
    var href: String
    var title: String
    var ogImage: String
    var html: String
}
