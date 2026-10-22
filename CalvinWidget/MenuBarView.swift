import AppKit
import ServiceManagement
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var model = StripModel.shared

    var body: some View {
        Button("Show Today's Strip") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            openWindow(id: "strip")
        }
        Button(model.isRefreshing ? "Refreshing…" : "Refresh Now") {
            Task { await model.refresh(force: true) }
        }
        .disabled(model.isRefreshing)
        Divider()
        LoginItemButtons()
        Divider()
        Button("Quit Calvin and Hobbes") {
            NSApplication.shared.terminate(nil)
        }
    }
}

struct LoginItemButtons: View {
    @State private var note: String?

    var body: some View {
        if SMAppService.mainApp.status == .enabled {
            Button("Don't Open at Login") {
                setEnabled(false)
            }
        } else {
            Button("Open at Login") {
                setEnabled(true)
            }
        }
        if let note {
            Text(note)
        }
    }

    private func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            if SMAppService.mainApp.status == .requiresApproval {
                note = "Allow it in System Settings → General → Login Items."
            } else {
                note = nil
            }
        } catch {
            note = error.localizedDescription
        }
    }
}

struct LoginItemToggle: View {
    @State private var enabled = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { enabled }, set: { setEnabled($0) })) {
                Text("Open at login")
                    .foregroundStyle(StripStyle.ink)
            }
            .toggleStyle(.switch)
            .tint(StripStyle.caption)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(StripStyle.ink.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            enabled = SMAppService.mainApp.status == .enabled
        }
    }

    private func setEnabled(_ turnOn: Bool) {
        do {
            if turnOn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            let status = SMAppService.mainApp.status
            enabled = status == .enabled || status == .requiresApproval
            if status == .requiresApproval {
                note = "macOS is waiting for approval in System Settings → General → Login Items."
            } else if turnOn {
                note = "For this to survive a reboot, run the copy in /Applications, then turn this on there."
            } else {
                note = nil
            }
        } catch {
            enabled = SMAppService.mainApp.status == .enabled
            note = error.localizedDescription
        }
    }
}
