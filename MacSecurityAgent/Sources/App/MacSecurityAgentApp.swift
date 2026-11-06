import AppKit
import MacSecurityCore
import SwiftUI

@main
struct MacSecurityAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            MenuBarLabel(state: appState.coordinator.displayState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

/// Menu-bar icon. The symbol changes with the state so the monitoring status
/// is always visible, in addition to the system camera indicator.
struct MenuBarLabel: View {
    let state: MonitoringState

    var body: some View {
        Image(systemName: state.symbolName)
            .accessibilityLabel("Mac Security Agent: \(state.title)")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationRequested = false
    private var terminationReplied = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Starts the agent (upload recovery, Telegram polling, network
        // monitoring). The camera is *not* started here.
        AppState.shared.launch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationRequested else { return .terminateLater }
        terminationRequested = true
        Task { @MainActor in
            await AppState.shared.prepareForTermination()
            self.replyToTermination()
        }
        // Never block quitting for long, even if finalising takes too long.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            self.replyToTermination()
        }
        return .terminateLater
    }

    private func replyToTermination() {
        guard !terminationReplied else { return }
        terminationReplied = true
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }
}
