import AppKit
import MacSecurityCore
import Observation
import SwiftUI

/// Composition root: builds every service, wires them together and exposes
/// state and actions to the SwiftUI views.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    enum ConfigurationError: LocalizedError {
        case invalidToken
        case invalidUserID
        case missingToken
        case verificationFailed(String)
        case keychain(String)

        var errorDescription: String? {
            switch self {
            case .invalidToken: return "The bot token format is invalid. Copy it exactly as BotFather shows it."
            case .invalidUserID: return "The user ID must be your numeric Telegram user ID (digits only)."
            case .missingToken: return "Enter the bot token."
            case .verificationFailed(let detail): return "Telegram rejected the configuration: \(detail)"
            case .keychain(let detail): return "Could not store the token in the Keychain: \(detail)"
            }
        }
    }

    let coordinator: MonitoringCoordinator
    /// Edited directly by the Settings window (via `@Bindable`);
    /// `settingsDidChange` validates, persists and applies it.
    var settings: ApplicationSettings
    private(set) var cameraPermission: CameraPermissionStatus
    private(set) var hasBotToken: Bool
    private(set) var botUsername: String?
    private(set) var loginItemStatus: LoginItemManager.Status
    private(set) var startupWarning: String?
    private(set) var powerSource: PowerSourceState = .unknown

    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let credentialStore: TelegramCredentialStore
    @ObservationIgnored private let telegramConfiguration: TelegramConfigurationStore
    @ObservationIgnored private let permissions: CameraPermissionManager
    @ObservationIgnored private let authorization: AuthorizationService
    @ObservationIgnored private let power: PowerManager
    @ObservationIgnored private let networkMonitor: NetworkMonitor
    @ObservationIgnored private let systemEvents: SystemEventsMonitor
    @ObservationIgnored private let loginItems: LoginItemManager
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var poller: TelegramUpdatePoller?
    @ObservationIgnored private var launched = false
    @ObservationIgnored private var appliedSettings: ApplicationSettings
    @ObservationIgnored private let logger = AppLogger(category: "App")
    private static let botUsernameKey = "telegram.bot-username.v1"

    private init() {
        let settingsStore = SettingsStore()
        let settings = settingsStore.load()
        let keychain = KeychainManager()
        let support = Self.supportDirectory()
        let telegramConfiguration = TelegramConfigurationStore()
        let permissions = CameraPermissionManager()
        let loginItems = LoginItemManager()
        let defaults = UserDefaults.standard
        var warning: String?

        let mediaStore: TemporaryMediaStore
        do {
            mediaStore = try TemporaryMediaStore(
                rootDirectory: support.appendingPathComponent("Queue", isDirectory: true),
                keyProvider: MediaKeyProvider(storage: keychain)
            )
        } catch {
            // Keychain or disk problem: keep monitoring possible with an
            // ephemeral key (queued media will not survive a restart).
            warning = "Secure storage unavailable (\(error.localizedDescription)). Pending uploads will not survive a restart."
            do {
                mediaStore = try TemporaryMediaStore(
                    rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("MacSecurityAgent-\(UUID().uuidString)"),
                    keyProvider: MediaKeyProvider(storage: InMemorySecureStorage())
                )
            } catch {
                fatalError("Cannot create temporary media storage: \(error.localizedDescription)")
            }
        }

        let repository = EventRepository(fileURL: support.appendingPathComponent("events.json"))
        let eventManager = EventManager(repository: repository, cooldownInterval: settings.eventCooldownSeconds)
        let uploadQueue = UploadQueue(
            indexURL: support.appendingPathComponent("Queue/index.json"),
            mediaStore: mediaStore,
            sessionProvider: telegramConfiguration,
            retention: settings.mediaRetentionInterval
        )
        let authorization = AuthorizationService()
        let power = PowerManager()
        let dependencies = MonitoringDependencies(
            camera: CameraService(),
            permissions: permissions,
            power: power,
            eventManager: eventManager,
            uploadQueue: uploadQueue,
            mediaStore: mediaStore,
            authorization: authorization
        )

        self.telegramConfiguration = telegramConfiguration
        self.permissions = permissions
        self.networkMonitor = NetworkMonitor()
        self.systemEvents = SystemEventsMonitor()
        self.loginItems = loginItems
        self.defaults = defaults
        self.settingsStore = settingsStore
        self.settings = settings
        self.appliedSettings = settings
        self.credentialStore = TelegramCredentialStore(storage: keychain)
        self.authorization = authorization
        self.power = power
        self.coordinator = MonitoringCoordinator(dependencies: dependencies, settings: settings)
        self.cameraPermission = permissions.currentStatus()
        self.hasBotToken = false
        self.botUsername = defaults.string(forKey: Self.botUsernameKey)
        self.loginItemStatus = loginItems.status
        self.startupWarning = warning
        rebuildTelegramSession()
    }

    // MARK: Lifecycle

    func launch() {
        guard !launched else { return }
        launched = true
        let coordinator = self.coordinator
        Task {
            await coordinator.launch()
            coordinator.startHealthMonitoring()
        }
        networkMonitor.start { available in
            Task { @MainActor in
                await coordinator.networkAvailabilityChanged(available)
            }
        }
        systemEvents.start(handlers: .init(
            displayDidSleep: { coordinator.displayDidSleep() },
            displayDidWake: { coordinator.displayDidWake() },
            systemWillSleep: { coordinator.systemWillSleep() },
            systemDidWake: { Task { await coordinator.systemDidWake() } }
        ))
        startPoller()
        syncLoginItem()
        refreshPermission()
        refreshPowerSource()
    }

    func prepareForTermination() async {
        systemEvents.stop()
        networkMonitor.stop()
        await poller?.stop()
        await coordinator.prepareForTermination()
    }

    // MARK: Monitoring actions (local UI only)

    func startMonitoring() {
        let request = authorization.makeLocalActivationRequest(origin: .menuBar)
        Task {
            await coordinator.arm(request)
            refreshPermission()
            refreshPowerSource()
        }
    }

    func stopMonitoring() {
        Task { await coordinator.disarm() }
    }

    func emergencyStop() {
        Task { await coordinator.emergencyStop() }
    }

    // MARK: Settings

    func settingsDidChange() {
        let validated = settings.validated()
        if validated != settings {
            settings = validated
        }
        guard validated != appliedSettings else { return }
        let previous = appliedSettings
        appliedSettings = validated
        settingsStore.save(validated)
        Task { await coordinator.apply(settings: validated) }
        if previous.launchAtLogin != validated.launchAtLogin {
            setLaunchAtLogin(validated.launchAtLogin)
        }
        if previous.authorizedTelegramUserID != validated.authorizedTelegramUserID {
            rebuildTelegramSession()
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItems.setEnabled(enabled)
        } catch {
            logger.error("Login item change failed: \(error.localizedDescription)")
        }
        loginItemStatus = loginItems.status
    }

    private func syncLoginItem() {
        if settings.launchAtLogin, loginItems.status == .disabled {
            setLaunchAtLogin(true)
        }
        loginItemStatus = loginItems.status
    }

    func openLoginItemsSettings() {
        loginItems.openSystemSettings()
    }

    // MARK: Telegram configuration

    /// Verifies the token with `getMe`, then stores it in the Keychain.
    /// An empty `tokenInput` keeps the stored token.
    func saveTelegramConfiguration(tokenInput: String, userIDInput: String) async -> Result<String, ConfigurationError> {
        let trimmedID = userIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let userID = Int64(trimmedID), userID > 0 else { return .failure(.invalidUserID) }

        let token: BotToken
        if tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let stored = try? credentialStore.loadToken() else { return .failure(.missingToken) }
            token = stored
        } else {
            guard let parsed = BotToken(tokenInput) else { return .failure(.invalidToken) }
            token = parsed
        }

        let client = TelegramClient(token: token)
        let bot: TelegramUser
        do {
            bot = try await client.getMe()
        } catch let error as TelegramError {
            return .failure(.verificationFailed(error.safeDescription))
        } catch {
            return .failure(.verificationFailed("Unexpected error"))
        }

        do {
            try credentialStore.saveToken(token)
        } catch {
            return .failure(.keychain(error.localizedDescription))
        }
        botUsername = bot.username
        defaults.set(bot.username, forKey: Self.botUsernameKey)
        settings.authorizedTelegramUserID = userID
        settingsDidChange()
        rebuildTelegramSession()
        await poller?.reset()
        await coordinator.telegramConfigurationChanged()
        return .success("Connected to @\(bot.username ?? "bot"). Send /start to the bot from your Telegram account if you have not done so yet.")
    }

    func sendTestMessage() async -> String {
        guard let session = telegramConfiguration.currentSession() else {
            return "Telegram is not configured."
        }
        do {
            _ = try await session.api.sendMessage(
                chatID: session.ownerUserID,
                text: "Mac Security Agent test message. Notifications are working."
            )
            return "Test message sent."
        } catch let error as TelegramError {
            return error.safeDescription
        } catch {
            return "Sending failed."
        }
    }

    func removeTelegramToken() {
        try? credentialStore.deleteToken()
        defaults.removeObject(forKey: Self.botUsernameKey)
        botUsername = nil
        rebuildTelegramSession()
    }

    private func rebuildTelegramSession() {
        let token = try? credentialStore.loadToken()
        hasBotToken = token != nil
        guard let token, let owner = settings.authorizedTelegramUserID else {
            telegramConfiguration.update(nil)
            coordinator.telegramStatusChanged(.notConfigured)
            return
        }
        telegramConfiguration.update(TelegramSession(api: TelegramClient(token: token), ownerUserID: owner, botUsername: botUsername))
        coordinator.telegramStatusChanged(.connecting)
    }

    private func startPoller() {
        let coordinator = self.coordinator
        let poller = TelegramUpdatePoller(
            sessionProvider: telegramConfiguration,
            offsetStore: UserDefaultsOffsetStore(),
            handler: TelegramCommandHandler(reporter: CoordinatorStatusReporter(coordinator: coordinator)),
            callbacks: .init(
                statusChanged: { status in await coordinator.telegramStatusChanged(status) },
                unauthorizedAttempt: { userID in await coordinator.reportUnauthorizedAttempt(userID: userID) }
            )
        )
        self.poller = poller
        Task { await poller.start() }
    }

    // MARK: Permissions / power

    func refreshPermission() {
        cameraPermission = permissions.currentStatus()
    }

    func openCameraPrivacySettings() {
        NSWorkspace.shared.open(CameraPermissionManager.privacySettingsURL)
    }

    func refreshPowerSource() {
        powerSource = power.currentPowerSource()
    }

    // MARK: Events

    func clearEventHistory() {
        Task { await coordinator.clearEventHistory() }
    }

    func showEventsWindow() {
        EventsWindowController.shared.show(appState: self)
    }

    private static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("MacSecurityAgent", isDirectory: true)
        try? SecureFiles.createPrivateDirectory(at: directory)
        return directory
    }
}
