# Testing

```bash
scripts/test.sh
```

This runs `swift test` on macOS: all automated suites, including the
AVFoundation and IOKit tests.

```bash
MSA_CAMERA_TESTS=1 scripts/test.sh --filter HardwareIntegrationTests
```

This adds the real built-in camera (it shows a permission prompt).

```bash
MSA_KEYCHAIN_TESTS=1 scripts/test.sh --filter HardwareIntegrationTests
```

This adds a real Keychain round trip.

```bash
scripts/linux-test.sh
```

This runs the platform-independent core in the `swift:6.0-noble` Docker image.

Two CI workflows run on every push: `.github/workflows/macos.yml` (package
tests, Xcode Release build, SwiftPM bundle) and
`.github/workflows/linux-core.yml`.

## Suites

| Suite | Platform | Covers |
|---|---|---|
| `MotionDetectorTests` | all | grayscale/downscale, thresholds, sensitivity, minimum area, 3-frame confirmation, reset, lighting changes, sensor noise, frame throttling |
| `EventManagerTests` | all | sequential IDs, one active event, cooldown, lifecycle stages, persistence, crash recovery |
| `UploadQueueTests` | all | ordering, decryption before upload, dedup, offline, backoff (2/4/8 s), `retry_after`, permanent and configuration errors, 24 h expiry, restart recovery, in-flight resend marker, orphan purge, tamper detection |
| `TelegramAuthenticatorTests` | all | owner-only, bots, groups, chat mismatch, forwarded, stale, malformed, wrong bot, single-use local activation |
| `TelegramClientTests` | all | HTTPS JSON and multipart bodies, error mapping, token redaction, HTTP refusal, Keychain credential store |
| `TelegramCommandsTests` | all | alert text format, `/status`, `/events`, `/help`, remote-control refusal, poller backlog skip, offset persistence, silent rejection, offline backoff |
| `TemporaryMediaStoreTests` | all | AES-GCM at rest, 0700/0600 permissions, key persistence, wrong key, swapped files, plaintext deletion |
| `MonitoringCoordinatorTests` | all | end-to-end scenarios (below) with a fake camera and mock Telegram |
| `SupportTests` | all | log sanitiser, state machine, settings defaults/clamping, frame health, secure files |
| `VideoRecorderTests` | macOS | real AVAssetWriter: exactly 30 s, 450 frames, H.264, 1280 × 720, 15 FPS, **no audio track**, MP4 `ftyp`, bitrate; partial recording; JPEG snapshot; luma conversion |
| `PowerManagerTests` | macOS | `PreventUserIdleSystemSleep` held while armed, display assertion only as fallback, all released |
| `HardwareIntegrationTests` | macOS, opt-in | real camera frames and release, real 5 s recording without audio, Keychain |

## Required scenarios

| # | Scenario | Automated test | Manual check |
|---|---|---|---|
| 1 | App starts without activating camera | `testLaunchNeverActivatesCamera` | Launch: no green light |
| 2 | Start monitoring from menu bar | `testArmFromMenuStartsCameraAndPreventsIdleSleep`, `testBuiltInCameraDeliversFramesAndIsReleased` | Green light on, state ARMED |
| 3 | Camera permission denied | `testCameraPermissionDenied` | Deny the prompt → ERROR + settings link |
| 4 | Camera unavailable | `testCameraUnavailableAtStart`, `testCameraDisconnectWhileArmed` | Open another app that takes the camera exclusively |
| 5 | Motion detected | `MotionDetectorTests`, `testMotionEventFullLifecycle` | Walk past → alert |
| 6 | Snapshot captured | `testSnapshotIsJPEG`, `testMotionEventFullLifecycle` | Photo in Telegram |
| 7 | Video records exactly 30 s | `testThirtySecondRecordingIsExactH264WithoutAudio`, `testRealCameraRecording` (5 s) | Video length 0:30 |
| 8 | Video has no audio track | same as 7 | `ffprobe` or QuickTime › Movie Inspector |
| 9 | Telegram receives snapshot | `testMotionEventFullLifecycle`, `testDeliversTextPhotoAndVideoInOrder` | Real bot |
| 10 | Telegram receives video | same as 9 | Real bot |
| 11 | Network disconnects during recording | `testNetworkLossDuringRecordingQueuesAndDeliversOnRecovery` | Turn Wi-Fi off after the alert |
| 12 | Network reconnects | same as 11, `testOfflineDefersDeliveryAndRecoveryRetriesImmediately` | Turn Wi-Fi on |
| 13 | Pending uploads delivered | same as 11 | Video arrives |
| 14 | Duplicate notifications prevented | `testDuplicateEventsAreSuppressedDuringRecordingAndCooldown`, `testDuplicateKeysAreRejectedWhilePendingAndAfterDelivery` | Keep moving → one alert per event |
| 15 | Unauthorised commands rejected | `TelegramAuthenticatorTests`, `testPollerRejectsUnauthorizedUsersWithoutReplying`, `testRemoteCommandsCannotArmMonitoring` | Send `/status` from a second account |
| 16 | Restart with pending uploads | `testRestartWithPendingUploadsDeliversThem`, `testPendingUploadsSurviveRestart` | Offline event, quit, go online, relaunch |
| 17 | User stops monitoring | `testStopReleasesCameraAndPowerAssertions`, `testStopDuringRecordingStillDeliversPartialVideo`, `testEmergencyStopDiscardsRecordingAndReleasesEverything` | Stop → DISARMED |
| 18 | Camera resources released | same as 17, `testBuiltInCameraDeliversFramesAndIsReleased` | Green light off within ~1 s |
| 19 | Power assertions released | `PowerManagerTests`, coordinator stop tests | `pmset -g assertions` shows nothing from the app |
| 20 | Display sleep compatibility | `testDisplaySleepProbeVerifiesCompatibility`, `testDisplaySleepFallbackKeepsDisplayAwakeWhenFramesStop` | Procedure below |

## Manual hardware checklist (Apple Silicon MacBook)

Display sleep (scenario 20):

1. Arm monitoring with the lid open.
2. Run `pmset displaysleepnow`.
3. Wait at least 20 s, then wave in front of the camera.
4. Wake the display. Settings › General › *Display sleep check* should read
   **Verified – camera keeps running** and a Telegram alert should have
   arrived. If it reads *Display sleep interrupts camera*, the fallback has
   kept the display awake; note your model and macOS version.

Battery and charger:

1. On the charger: arm, then `pmset -g assertions` →
   `PreventUserIdleSystemSleep … "MacSecurityAgent home monitoring is armed"`.
2. Unplug: `/status` shows `Power: Battery (NN%)`; monitoring continues.
3. Wait past the battery idle-sleep timeout (System Settings › Battery). The
   Mac must stay awake while armed and sleep normally after disarming.
4. Stop: the assertion disappears from `pmset -g assertions`.

Lid: closing the lid sleeps the Mac. On wake the agent notifies you and
restarts the camera. This configuration is unsupported by design.
