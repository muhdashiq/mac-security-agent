# Architecture

MacSecurityAgent is split into a UI-free core library (`MacSecurityCore`, a
Swift package) and a thin SwiftUI menu-bar app (`Sources/App`). Every core
component takes its collaborators through its initialiser, so the whole
monitoring flow runs in tests with a fake camera and a mock Telegram API.

```
MacSecurityAgent/
  Package.swift              MacSecurityCore library + tests (+ SwiftPM app target on macOS)
  Sources/
    App/                     SwiftUI: app entry, AppState (composition root), menu bar, settings, events window
    Camera/                  CameraService, CameraPermissionManager, MotionDetector, PixelBufferConverter,
                             SnapshotCapture, VideoRecorder
    Monitoring/              MonitoringCoordinator, EventManager, EventCooldown, FrameHealthMonitor,
                             PowerManager, NetworkMonitor, SystemEventsMonitor
    Telegram/                TelegramClient, TelegramCommands, TelegramAuthenticator,
                             TelegramUpdatePoller, UploadQueue
    Storage/                 TemporaryMediaStore, EventRepository, SecureStorage, SettingsStore
    Security/                KeychainManager, CredentialStore, AuthorizationService
    Models/                  SecurityEvent, MonitoringState, ApplicationSettings
    Support/                 Logging (sanitiser), concurrency helpers, LoginItemManager
  Tests/                     XCTest suites (core, scenarios, macOS-only recording/power/hardware)
  Resources/                 Info.plist, entitlements
MacSecurityAgent.xcodeproj   App target linking the local package
```

Files that need Apple frameworks (`AVFoundation`, `IOKit`, `Security`,
`Network`, `AppKit`, `ServiceManagement`) are wrapped in `#if canImport(...)`.
That lets the rest of the core build and run its tests on Linux CI too.

## Components

| Component | Responsibility | Isolation |
|---|---|---|
| `MonitoringCoordinator` | State machine, event lifecycle, glue between camera, queue, power and Telegram | `@MainActor`, `@Observable` |
| `CameraService` | `AVCaptureSession` (video only), frame delivery, motion analysis, recording, snapshot | one serial dispatch queue |
| `MotionDetector` | Frame-difference detection on 320 × 180 luma | value type, owned by the camera queue |
| `VideoRecorder` | `AVAssetWriter` H.264 MP4, 15 FPS, exact duration | owned by the camera queue |
| `EventManager` | Event IDs, one-active-event rule, cooldown, delivery status | `actor` |
| `EventRepository` | Event metadata JSON (0600) | `actor` |
| `TemporaryMediaStore` | AES-256-GCM encrypted media, plaintext recording dir | `actor` |
| `UploadQueue` | Durable outbox, retries/backoff, dedup, expiry | `actor` |
| `TelegramClient` | Bot API over HTTPS (`sendMessage`, `sendPhoto`, `sendVideo`, `getUpdates`, `getMe`) | immutable, `Sendable` |
| `TelegramUpdatePoller` | Long polling, command authentication and replies | `actor` |
| `TelegramAuthenticator` | Owner-only command validation | value type |
| `PowerManager` | IOKit assertions, power source | `@MainActor` |
| `AuthorizationService` | Single-use local activation tokens | `@MainActor` |
| `KeychainManager` | Generic-password Keychain items | `Sendable` |

## State machine

`MonitoringPhase` is the internal state. `MonitoringPhase.canTransition(to:)`
rejects every transition not listed below, so conflicting operations (arming
twice, recording while stopping, and so on) cannot happen.

```
disarmed ──▶ arming ──▶ armed ──▶ motionDetected ──▶ recording
                │         ▲  │            │               │
                │         └──┼────────────┴───────────────┘   (event finished)
                ▼            ▼
              error ◀──── stopping ──▶ disarmed
```

The menu bar shows `MonitoringState`, which is derived from the phase plus
camera health and connectivity, and covers all eight suggested states:
Disarmed, Arming, Armed, Motion Detected, Recording, Uploading, Offline and
Error. An armed session whose frames stopped arriving shows **Error**. It
never shows Armed in that case.

A `generation` counter invalidates continuations of superseded operations.
For example, if Stop is pressed while the camera is still starting, the
arming task finds its generation outdated and releases the camera instead of
finishing the arm.

## Event lifecycle

```
ARMED
  │  camera queue: 3 consecutive qualifying frames, trigger gate open
  ▼
MOTION DETECTED ── EventManager.beginEvent (rejects if active / cooldown)
  │  1. alert text enqueued                 (dedup key EVT-n.alert)
  │  2. snapshot JPEG encrypted + enqueued  (EVT-n.snapshot) → upload starts now
  ▼
RECORDING ── VideoRecorder, exactly `videoDurationSeconds`
  │  3. plaintext MP4 encrypted into the store, plaintext securely deleted
  │  4. video enqueued                      (EVT-n.video)
  ▼
ARMED ── cooldown starts; trigger gate re-opens after the cooldown
  ⋮ upload queue (independent of the camera):
  delivered → media deleted → status Delivered → stage Completed
  network loss → kept encrypted, retried with backoff, delivered on recovery
  > retention (≤ 24 h) → deleted, reported as Expired
```

Duplicate events are blocked at three levels:

1. **Pipeline gate.** After a trigger the camera queue stops emitting
   triggers until the coordinator re-opens the gate (after recording plus
   cooldown).
2. **EventManager.** It rejects a new event while one is active or the
   cooldown is running.
3. **UploadQueue.** Deduplication keys stop the same artefact from being
   queued or delivered twice.

## Concurrency and races

- **Camera processing.** Frame analysis, recorder appends, recording start
  and stop, and session teardown all run on one serial queue. Public async
  methods hop onto that queue, so analysis, recording and shutdown are never
  concurrent.
- **Camera to coordinator.** Pipeline events go through an `AsyncStream`
  that the main actor consumes in order. The outcome of a recording is
  produced exactly once, either through the stream or as the return value of
  `finishRecording`.
- **Shutdown.** `applicationShouldTerminate` returns `.terminateLater` and
  waits for `prepareForTermination()`. That call finalises the recording,
  encrypts it into the queue and releases the camera and power assertions,
  with an 8-second safety limit.
- **Uploads.** `UploadQueue` is an actor. A processing pass is not
  re-entrant, it re-checks connectivity before every item, and it marks an
  item `inFlight` on disk *before* sending it.
- **Event metadata.** Each update is one atomic read-modify-write inside the
  repository actor, so status updates from upload callbacks and from the
  motion handler cannot overwrite each other.

## Delivery guarantees

The queue is an outbox: an artefact is persisted encrypted before any
network call is made. Delivery is at-least-once. If the app dies after
Telegram accepted a request but before the queue recorded it, the item is
sent once more after restart, with the caption prefix
`[Resent after restart – may be a duplicate]`. The Bot API has no idempotency
keys, so exactly-once delivery is not possible.

## Data on disk

All of this lives in the sandbox container (`~/Library/Containers/com.macsecurityagent.app/Data/Library/Application Support/MacSecurityAgent/`):

| Path | Content | Protection |
|---|---|---|
| `events.json` | Event metadata (IDs, timestamps, statuses) | 0600 |
| `Queue/index.json` | Upload queue metadata, delivered dedup keys | 0600 |
| `Queue/Media/*.enc` | Snapshots and videos awaiting delivery | AES-256-GCM, 0600, deleted after delivery or expiry |
| `Queue/Recording/*.mp4` | The MP4 currently being written (plaintext, ≤ 30 s) | 0700 dir, securely deleted right after encryption or on next launch |

The directories are excluded from Time Machine. The bot token and the media
key are stored only in the Keychain
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never synchronised).
