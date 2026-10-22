import AppKit
import SwiftUI

struct StripBrowserView: NSViewRepresentable {
    let browser: StripBrowser

    func makeNSView(context: Context) -> StripBrowserHostView {
        let view = StripBrowserHostView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.cgColor
        browser.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: StripBrowserHostView, context: Context) {
        browser.attach(to: nsView)
    }
}

struct ContentView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject private var model = StripModel.shared

    var body: some View {
        ZStack {
            StripStyle.desk.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 28)
                    .padding(.top, 22)
                    .padding(.bottom, 12)
                if let browser = model.liveBrowser {
                    StripBrowserView(browser: browser)
                        .frame(maxWidth: .infinity)
                        .frame(height: 360)
                        .background(Color.white)
                        .overlay(Rectangle().stroke(StripStyle.ink.opacity(0.88), lineWidth: 2))
                        .padding(.horizontal, 28)
                    Text("Leave this page on screen. GoComics has to finish a browser check before the strip can load.")
                        .font(.caption)
                        .foregroundStyle(StripStyle.ink.opacity(0.72))
                        .padding(.top, 8)
                        .padding(.horizontal, 28)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        stripCard
                        widgetNote
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 18)
                    .frame(maxWidth: 840)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 640)
        .preferredColorScheme(.light)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Calvin and Hobbes")
                    .font(.system(size: 34, weight: .semibold, design: .serif))
                    .foregroundStyle(StripStyle.ink)
                Text("Bill Watterson, via GoComics")
                    .font(.subheadline)
                    .foregroundStyle(StripStyle.ink.opacity(0.62))
            }
            Spacer(minLength: 16)
            Button(model.isRefreshing ? "Refreshing…" : "Refresh") {
                Task { await model.refresh(force: true) }
            }
            .buttonStyle(ReadableButtonStyle())
            .disabled(model.isRefreshing)
            .opacity(model.isRefreshing ? 0.45 : 1)
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    private var stripCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            dateLine
            stripBody
            if let warning = model.containerWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(StripStyle.ink.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Open on GoComics") {
                openURL(currentPageURL)
            }
            .buttonStyle(ReadableButtonStyle(prominent: true))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StripStyle.paper)
        .overlay(Rectangle().stroke(StripStyle.ink.opacity(0.88), lineWidth: 2))
    }

    @ViewBuilder
    private var dateLine: some View {
        switch model.phase {
        case .loading:
            Text("Opening GoComics…")
                .font(.headline)
                .foregroundStyle(StripStyle.ink)
        case .loaded(let strip):
            VStack(alignment: .leading, spacing: 4) {
                Text(dateTitle(strip.day))
                    .font(.headline)
                    .foregroundStyle(StripStyle.ink)
                if model.isRefreshing {
                    Text("Checking GoComics for a newer strip…")
                        .font(.subheadline)
                        .foregroundStyle(StripStyle.ink.opacity(0.7))
                } else if strip.usedPreviousDay {
                    Text("Today's strip isn't up yet, so this is yesterday's.")
                        .font(.subheadline)
                        .foregroundStyle(StripStyle.ink.opacity(0.7))
                }
            }
        case .failed:
            Text("Couldn't load today's strip.")
                .font(.headline)
                .foregroundStyle(StripStyle.ink)
        }
    }

    @ViewBuilder
    private var stripBody: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: 14) {
                if model.liveBrowser == nil {
                    ProgressView()
                        .controlSize(.large)
                        .tint(StripStyle.ink)
                }
                Text(model.liveBrowser == nil
                    ? "The site runs a browser check first, so this can take a minute."
                    : "The check runs in the page above. It can take a minute.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(StripStyle.ink.opacity(0.72))
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, minHeight: model.liveBrowser == nil ? 220 : 48)
        case .loaded(let strip):
            StripImageView(data: strip.imageData)
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(Color.white)
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 12) {
                Text(failure.message)
                    .font(.body)
                    .foregroundStyle(StripStyle.ink.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                Text(failure.detail)
                    .font(.caption)
                    .foregroundStyle(StripStyle.ink.opacity(0.72))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") {
                    Task { await model.refresh(force: true) }
                }
                .buttonStyle(ReadableButtonStyle())
                .disabled(model.isRefreshing)
                .opacity(model.isRefreshing ? 0.45 : 1)
            }
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
        }
    }

    private var widgetNote: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On the desktop")
                .font(.system(.headline, design: .serif))
                .foregroundStyle(StripStyle.ink)
            Text("Right-click the desktop, choose Edit Widgets, and add Calvin and Hobbes. The widget shows the strip this app last saved. It does not download the comic itself.")
                .font(.body)
                .foregroundStyle(StripStyle.ink.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
            Text("Leave the app running — the newspaper icon stays in the menu bar — or turn on Open at login. After a strip appears here, the desktop widget updates. If it stays blank, remove the widget and add it again.")
                .font(.body)
                .foregroundStyle(StripStyle.ink.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
            LoginItemToggle()
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StripStyle.paper.opacity(0.72))
    }

    private var currentPageURL: URL {
        if case .loaded(let strip) = model.phase {
            return strip.pageURL
        }
        return StripStore.pageURL(for: Date())
    }

    private func dateTitle(_ day: Date) -> String {
        day.formatted(
            Date.FormatStyle()
                .weekday(.wide)
                .month(.wide)
                .day()
                .year()
                .locale(Locale(identifier: "en_US"))
        )
    }
}

struct ReadableButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : StripStyle.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? Self.prominentFill : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(prominent ? Self.prominentFill : StripStyle.ink, lineWidth: 1.5)
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
    }

    /// Darker than the caption color so white text stays readable.
    private static let prominentFill = Color(red: 0.55, green: 0.22, blue: 0.09)
}
