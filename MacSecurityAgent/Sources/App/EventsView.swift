import AppKit
import MacSecurityCore
import SwiftUI

/// History of events (metadata only; media is never kept locally after
/// delivery).
struct EventsView: View {
    @Environment(AppState.self) private var appState
    @State private var confirmClear = false

    var body: some View {
        let events = appState.coordinator.recentEvents
        VStack(alignment: .leading, spacing: 0) {
            if events.isEmpty {
                ContentUnavailableView(
                    "No Events",
                    systemImage: "shield.checkered",
                    description: Text("Motion events appear here once monitoring is armed.")
                )
            } else {
                Table(events) {
                    TableColumn("Event") { event in
                        Text(event.id.rawValue).monospaced()
                    }
                    .width(min: 90, ideal: 100)
                    TableColumn("Detected") { event in
                        Text(event.detectedAt.formatted(date: .abbreviated, time: .standard))
                    }
                    .width(min: 150, ideal: 170)
                    TableColumn("Changed") { event in
                        Text(String(format: "%.1f %%", event.changedAreaPercent))
                    }
                    .width(min: 60, ideal: 70)
                    TableColumn("Stage") { event in
                        Text(event.stage.title)
                    }
                    TableColumn("Snapshot") { event in
                        DeliveryBadge(status: event.snapshotStatus)
                    }
                    TableColumn("Video") { event in
                        DeliveryBadge(status: event.videoStatus)
                    }
                }
            }
            Divider()
            HStack {
                Text("\(events.count) event(s) · \(appState.coordinator.pendingUploadCount) pending upload(s)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear History…") { confirmClear = true }
                    .disabled(events.isEmpty)
            }
            .padding(10)
        }
        .frame(minWidth: 680, minHeight: 360)
        .confirmationDialog("Clear the event history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { appState.clearEventHistory() }
        } message: {
            Text("Only local metadata is removed. Media already delivered to Telegram is not affected.")
        }
    }
}

struct DeliveryBadge: View {
    let status: DeliveryStatus

    var body: some View {
        Label(status.title, systemImage: symbol)
            .foregroundStyle(color)
            .lineLimit(1)
            .help(status.title)
    }

    private var symbol: String {
        switch status {
        case .delivered: return "checkmark.circle.fill"
        case .pending, .queued: return "clock"
        case .uploading: return "arrow.up.circle"
        case .failed, .expired: return "xmark.octagon.fill"
        case .skipped: return "minus.circle"
        }
    }

    private var color: Color {
        switch status {
        case .delivered: return .green
        case .pending, .queued, .uploading: return .blue
        case .failed, .expired: return .red
        case .skipped: return .secondary
        }
    }
}

/// Hosts the events window. An AppKit window is used (instead of a SwiftUI
/// `Window` scene) so that nothing opens automatically at launch.
@MainActor
final class EventsWindowController {
    static let shared = EventsWindowController()
    private var window: NSWindow?

    func show(appState: AppState) {
        if window == nil {
            let hosting = NSHostingController(rootView: EventsView().environment(appState))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Security Events"
            window.setContentSize(NSSize(width: 760, height: 420))
            window.styleMask.insert([.resizable, .closable, .miniaturizable])
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApplication.shared.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
