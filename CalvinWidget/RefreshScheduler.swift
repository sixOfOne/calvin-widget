import AppKit
import Foundation
import WidgetKit

@MainActor
final class StripModel: ObservableObject {
    static let shared = StripModel()

    enum Phase {
        case loading
        case loaded(CachedStrip)
        case failed(StripFailure)
    }

    @Published var phase: Phase = .loading
    @Published var isRefreshing = false
    @Published var containerWarning: String?
    @Published var liveBrowser: StripBrowser?

    private var inFlight: Task<Void, Never>?
    private var lastNetworkAt: Date?

    func refreshIfNeeded() async {
        await refresh(force: false)
    }

    func refresh(force: Bool) async {
        if let inFlight {
            await inFlight.value
            if !force { return }
        }
        let task = Task { @MainActor in
            await self.perform(force: force)
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func perform(force: Bool) async {
        if !force, skipNetwork() {
            showCachedStrip()
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }
        lastNetworkAt = Date()

        let browser = StripBrowser()
        liveBrowser = browser
        defer {
            liveBrowser = nil
            browser.shutdown()
        }

        if StripStore.load() == nil, !isShowingStrip {
            phase = .loading
        }

        let container = StripStore.containerURL()?.path ?? "nil"
        FetchLog.note("refresh force=\(force) container=\(container)")

        let result = await StripWebLoader.loadLatest(using: browser)
        switch result {
        case .success(let strip):
            let securedToday = !strip.usedPreviousDay && Calendar.current.isDateInToday(strip.day)
            StripStore.recordAttempt(StripAttempt(at: Date(), securedToday: securedToday))
            do {
                try StripStore.save(strip)
                containerWarning = nil
                WidgetCenter.shared.reloadAllTimelines()
                let folder = StripStore.containerURL()?.path ?? container
                FetchLog.note("save ok bytes=\(strip.imageData.count) day=\(StripStore.dayString(strip.day)) folder=\(folder)")
            } catch {
                containerWarning = StripStore.accessDescription
                FetchLog.note("save failed \(error.localizedDescription) container=\(StripStore.containerURL()?.path ?? "nil")")
            }
            phase = .loaded(strip)
        case .failure(let error):
            FetchLog.note("fetch failed \(error.detail)")
            StripStore.recordAttempt(StripAttempt(at: Date(), securedToday: false))
            if var cached = StripStore.load() {
                cached.fetchedAt = Date()
                phase = .loaded(cached)
                containerWarning = error.message
            } else {
                phase = .failed(error)
            }
        }
    }

    private var isShowingStrip: Bool {
        if case .loaded = phase { return true }
        return false
    }

    private func skipNetwork() -> Bool {
        if let cached = StripStore.load(),
           Calendar.current.isDateInToday(cached.day),
           !cached.usedPreviousDay {
            return true
        }
        if let cached = StripStore.load(),
           let attempt = StripStore.lastAttempt(),
           Date().timeIntervalSince(attempt.at) < 3 * 60 * 60,
           !attempt.securedToday,
           cached.imageData.isEmpty == false {
            return true
        }
        if StripStore.load() == nil,
           let lastNetworkAt,
           Date().timeIntervalSince(lastNetworkAt) < 10 * 60 {
            return true
        }
        return false
    }

    private func showCachedStrip() {
        if let cached = StripStore.load() {
            phase = .loaded(cached)
        }
    }
}

@MainActor
final class StripRefreshScheduler: NSObject {
    static let shared = StripRefreshScheduler()

    private var dailyTimer: Timer?
    private var activity: NSBackgroundActivityScheduler?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        ProcessInfo.processInfo.disableAutomaticTermination("Refreshing the daily strip")
        Task { await StripModel.shared.refreshIfNeeded() }
        scheduleDaily()
        scheduleBackgroundChecks()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleRefreshTrigger),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRefreshTrigger),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func handleRefreshTrigger() {
        Task { await StripModel.shared.refreshIfNeeded() }
    }

    private func scheduleDaily() {
        dailyTimer?.invalidate()
        let fire = nextMidnightCheck()
        let timer = Timer(fire: fire, interval: 0, repeats: false) { _ in
            Task { @MainActor in
                await StripModel.shared.refresh(force: true)
                StripRefreshScheduler.shared.scheduleDaily()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dailyTimer = timer
    }

    private func nextMidnightCheck() -> Date {
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.startOfDay(for: now)
        let thisMorning = calendar.date(byAdding: .minute, value: 10, to: start) ?? now
        if thisMorning > now.addingTimeInterval(30) {
            return thisMorning
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: start) ?? now.addingTimeInterval(24 * 60 * 60)
        return calendar.date(byAdding: .minute, value: 10, to: tomorrow) ?? tomorrow
    }

    private func scheduleBackgroundChecks() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.CalvinWidget"
        let scheduler = NSBackgroundActivityScheduler(identifier: "\(bundleID).refresh")
        scheduler.repeats = true
        scheduler.interval = 30 * 60
        scheduler.tolerance = 5 * 60
        scheduler.schedule { completion in
            Task { @MainActor in
                await StripModel.shared.refreshIfNeeded()
                completion(.finished)
            }
        }
        activity = scheduler
    }
}

enum LoginLaunch {
    /// 'aevt' / 'oapp' / 'prdt' / 'lgit' — SMAppService sets the login-item flag on the open event.
    static var isLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        guard event.eventClass == 0x61657674, event.eventID == 0x6F617070 else { return false }
        return event.paramDescriptor(forKeyword: 0x70726474)?.enumCodeValue == 0x6C676974
    }
}
