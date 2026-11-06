import AppKit
import MacSecurityCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        TabView {
            MonitoringSettingsTab(settings: $appState.settings)
                .tabItem { Label("Monitoring", systemImage: "video") }
            TelegramSettingsTab()
                .tabItem { Label("Telegram", systemImage: "paperplane") }
            NotificationSettingsTab(preferences: $appState.settings.notifications)
                .tabItem { Label("Notifications", systemImage: "bell") }
            GeneralSettingsTab(settings: $appState.settings)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560)
        .padding(20)
        .onChange(of: appState.settings) {
            appState.settingsDidChange()
        }
        .onAppear {
            NSApplication.shared.activate()
            appState.refreshPermission()
            appState.refreshPowerSource()
        }
    }
}

// MARK: - Monitoring

private struct MonitoringSettingsTab: View {
    @Binding var settings: ApplicationSettings
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Motion detection") {
                LabeledContent("Sensitivity") {
                    HStack {
                        Text("Low").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $settings.motionSensitivity, in: ApplicationSettings.sensitivityRange)
                        Text("High").font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Minimum movement area") {
                    HStack {
                        Slider(value: $settings.minimumMotionAreaPercent, in: 0.2...10, step: 0.1)
                        Text(String(format: "%.1f %%", settings.minimumMotionAreaPercent))
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Stepper(value: $settings.consecutiveFramesRequired, in: ApplicationSettings.consecutiveFramesRange) {
                    LabeledContent("Consecutive frames", value: "\(settings.consecutiveFramesRequired)")
                }
                Stepper(value: $settings.eventCooldownSeconds, in: ApplicationSettings.cooldownRange, step: 5) {
                    LabeledContent("Event cooldown", value: "\(Int(settings.eventCooldownSeconds)) s")
                }
            }

            Section {
                Stepper(value: $settings.videoDurationSeconds, in: ApplicationSettings.videoDurationRange, step: 5) {
                    LabeledContent("Video duration", value: "\(Int(settings.videoDurationSeconds)) s")
                }
                Picker("Video resolution", selection: $settings.videoResolution) {
                    ForEach(VideoResolution.allCases) { resolution in
                        Text(resolution.title).tag(resolution)
                    }
                }
            } header: {
                Text("Recording (H.264 MP4, 15 FPS, ≈1.2 Mbps, no audio)")
            } footer: {
                if appState.coordinator.phase.isCameraPhase {
                    Text("Duration and resolution changes apply the next time monitoring is started.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Telegram

private struct TelegramSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var tokenInput = ""
    @State private var userIDInput = ""
    @State private var isWorking = false
    @State private var resultMessage: String?
    @State private var resultIsError = false

    var body: some View {
        Form {
            Section {
                SecureField("Bot token", text: $tokenInput, prompt: Text(appState.hasBotToken ? "Stored in Keychain – leave empty to keep" : "123456789:AA…"))
                    .autocorrectionDisabled()
                TextField("Authorized Telegram user ID", text: $userIDInput, prompt: Text("e.g. 123456789"))
                    .autocorrectionDisabled()
                HStack {
                    Button("Verify & Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking || userIDInput.isEmpty || (tokenInput.isEmpty && !appState.hasBotToken))
                    Button("Send Test Message") { sendTest() }
                        .disabled(isWorking || !appState.hasBotToken || appState.settings.authorizedTelegramUserID == nil)
                    Spacer()
                    if isWorking { ProgressView().controlSize(.small) }
                }
                if let resultMessage {
                    Label(resultMessage, systemImage: resultIsError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .foregroundStyle(resultIsError ? .red : .green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Bot configuration")
            } footer: {
                Text("The token is stored only in the macOS Keychain. Only messages from the authorized user ID in a private chat are accepted. The bot cannot start monitoring.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                LabeledContent("Connection", value: appState.coordinator.telegramStatus.title)
                LabeledContent("Bot", value: appState.botUsername.map { "@\($0)" } ?? "—")
                LabeledContent("Token", value: appState.hasBotToken ? "Stored in Keychain" : "Not set")
                if appState.hasBotToken {
                    Button("Remove Token from Keychain", role: .destructive) {
                        appState.removeTelegramToken()
                        resultMessage = nil
                    }
                }
            }

            Section("Setup") {
                Text("""
                1. In Telegram, open @BotFather, send /newbot and copy the token.
                2. Open @userinfobot to find your numeric user ID.
                3. Send /start to your new bot (bots cannot message you first).
                4. Enter both values above and click Verify & Save.
                """)
                .font(.callout)
                .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if let id = appState.settings.authorizedTelegramUserID {
                userIDInput = String(id)
            }
        }
    }

    private func save() {
        isWorking = true
        resultMessage = nil
        let token = tokenInput
        let userID = userIDInput
        Task {
            let result = await appState.saveTelegramConfiguration(tokenInput: token, userIDInput: userID)
            isWorking = false
            switch result {
            case .success(let message):
                resultMessage = message
                resultIsError = false
                tokenInput = ""
            case .failure(let error):
                resultMessage = error.localizedDescription
                resultIsError = true
            }
        }
    }

    private func sendTest() {
        isWorking = true
        Task {
            let message = await appState.sendTestMessage()
            isWorking = false
            resultMessage = message
            resultIsError = message != "Test message sent."
        }
    }
}

// MARK: - Notifications

private struct NotificationSettingsTab: View {
    @Binding var preferences: NotificationPreferences

    var body: some View {
        Form {
            Section("When motion is detected") {
                Toggle("Send text alert", isOn: $preferences.sendTextAlert)
                Toggle("Send snapshot", isOn: $preferences.sendSnapshot)
                Toggle("Record and send video", isOn: $preferences.sendVideo)
            }
            Section("Status notices") {
                Toggle("Monitoring armed / disarmed", isOn: $preferences.notifyArmingChanges)
                Toggle("Camera problems, sleep and wake", isOn: $preferences.notifyCameraProblems)
                Toggle("Failed or expired deliveries", isOn: $preferences.notifyDeliveryFailures)
                Toggle("Rejected commands from unknown users", isOn: $preferences.notifyUnauthorizedAttempts)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Binding var settings: ApplicationSettings
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open at login", isOn: $settings.launchAtLogin)
                Text("Opening at login only starts the menu-bar agent. Monitoring is never started automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if appState.loginItemStatus == .requiresApproval {
                    Button("Approve in System Settings…") { appState.openLoginItemsSettings() }
                }
                if case .unavailable(let reason) = appState.loginItemStatus {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Temporary media") {
                LabeledContent("Retention") {
                    HStack {
                        Slider(value: $settings.mediaRetentionHours, in: ApplicationSettings.retentionRange, step: 1)
                        Text("\(Int(settings.mediaRetentionHours)) h")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Text("Undelivered media is kept encrypted (AES-256-GCM) for at most this long, then deleted and reported. Delivered media is deleted immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Power & display") {
                Toggle("Keep display awake while armed", isOn: $settings.keepDisplayAwake)
                Text("Off by default: the display may sleep while the Mac stays awake. Turn this on if the display-sleep check below reports that the camera stops. Keep the lid open; closed-lid monitoring is not supported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Display sleep check", value: appState.coordinator.displaySleepCompatibility.title)
                LabeledContent("Power source", value: appState.powerSource.title)
            }

            Section("Privacy") {
                LabeledContent("Camera access", value: appState.cameraPermission.title)
                LabeledContent("Microphone", value: "Never used")
                Button("Open Camera Privacy Settings…") { appState.openCameraPrivacySettings() }
            }
        }
        .formStyle(.grouped)
    }
}
