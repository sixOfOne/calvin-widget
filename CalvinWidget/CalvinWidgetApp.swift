import AppKit
import SwiftUI

@main
struct CalvinWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Calvin and Hobbes", systemImage: "newspaper") {
            MenuBarView()
        }
        WindowGroup(id: "strip") {
            ContentView()
        }
        .defaultSize(width: 780, height: 760)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchedAtLogin = LoginLaunch.isLoginItem
        if launchedAtLogin {
            NSApp.setActivationPolicy(.accessory)
        }
        StripRefreshScheduler.shared.start()
        guard launchedAtLogin else { return }
        for delay in [0.4, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Task { @MainActor in
                    Self.closeStripWindows()
                }
            }
        }
    }

    private static func closeStripWindows() {
        for window in NSApp.windows {
            let title = window.title
            if window.canBecomeMain || title.localizedCaseInsensitiveContains("Calvin") {
                window.close()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
