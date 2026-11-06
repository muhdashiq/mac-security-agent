import AppKit
import MacSecurityCore
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let coordinator = appState.coordinator
        VStack(alignment: .leading, spacing: 12) {
            header(coordinator)
            statusBox(coordinator)

            if let message = coordinator.lastErrorMessage ?? appState.startupWarning {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            controls(coordinator)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 330)
        .onAppear {
            appState.refreshPermission()
            appState.refreshPowerSource()
        }
    }

    private func header(_ coordinator: MonitoringCoordinator) -> some View {
        HStack(spacing: 10) {
            Image(systemName: coordinator.displayState.symbolName)
                .font(.title2)
                .foregroundStyle(stateColor(coordinator.displayState))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mac Security Agent")
                    .font(.headline)
                Text(coordinator.displayState.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(stateColor(coordinator.displayState))
            }
            Spacer()
        }
    }

    private func statusBox(_ coordinator: MonitoringCoordinator) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                StatusRow(title: "Monitoring", value: coordinator.phase.isCameraPhase ? "ARMED" : (coordinator.phase == .arming ? "ARMING" : "DISARMED"),
                          color: coordinator.phase.isCameraPhase ? .green : .secondary)
                StatusRow(title: "Camera", value: coordinator.cameraStatus.title, color: cameraColor(coordinator.cameraStatus))
                StatusRow(title: "Camera access", value: appState.cameraPermission.title,
                          color: appState.cameraPermission == .authorized ? .secondary : .orange)
                StatusRow(title: "Telegram", value: coordinator.telegramStatus.title, color: telegramColor(coordinator.telegramStatus))
                StatusRow(title: "Network", value: coordinator.isNetworkAvailable ? "ONLINE" : "OFFLINE",
                          color: coordinator.isNetworkAvailable ? .secondary : .orange)
                if coordinator.pendingUploadCount > 0 {
                    StatusRow(title: "Pending uploads", value: "\(coordinator.pendingUploadCount)", color: .blue)
                }
                StatusRow(title: "Last event", value: lastEventText(coordinator.lastEvent), color: .secondary)
                StatusRow(title: "Power", value: appState.powerSource.title, color: .secondary)
            }
            .padding(4)
        }
    }

    private func controls(_ coordinator: MonitoringCoordinator) -> some View {
        VStack(spacing: 8) {
            if coordinator.canArm {
                Button {
                    appState.startMonitoring()
                } label: {
                    Label("Start Monitoring", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button {
                    appState.stopMonitoring()
                } label: {
                    Label("Stop Monitoring", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(coordinator.phase == .stopping)
            }

            Button(role: .destructive) {
                appState.emergencyStop()
            } label: {
                Label("Emergency Stop", systemImage: "exclamationmark.octagon.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(coordinator.phase == .disarmed)
            .help("Immediately releases the camera and discards any recording in progress")

            if appState.cameraPermission == .denied || appState.cameraPermission == .restricted {
                Button("Open Camera Privacy Settings…") {
                    appState.openCameraPrivacySettings()
                }
                .buttonStyle(.link)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("View Events") {
                appState.showEventsWindow()
            }
            Spacer()
            SettingsLink {
                Text("Settings…")
            }
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
        .buttonStyle(.borderless)
    }

    private func lastEventText(_ event: SecurityEvent?) -> String {
        guard let event else { return "None" }
        return "\(event.id) · \(event.detectedAt.formatted(date: .omitted, time: .standard))"
    }

    private func stateColor(_ state: MonitoringState) -> Color {
        switch state {
        case .disarmed: return .secondary
        case .arming: return .yellow
        case .armed, .uploading: return .green
        case .motionDetected, .recording: return .red
        case .offline: return .orange
        case .error: return .orange
        }
    }

    private func cameraColor(_ status: CameraStatus) -> Color {
        switch status {
        case .active: return .green
        case .inactive: return .secondary
        case .starting: return .yellow
        case .stalled, .unavailable: return .orange
        }
    }

    private func telegramColor(_ status: TelegramStatus) -> Color {
        switch status {
        case .connected: return .green
        case .notConfigured, .connecting: return .secondary
        case .offline, .error: return .orange
        }
    }
}

struct StatusRow: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .foregroundStyle(color == .secondary ? Color.primary : color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}
