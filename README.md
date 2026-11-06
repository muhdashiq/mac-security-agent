# MacSecurityAgent

A native macOS menu-bar app that turns an Apple Silicon MacBook into a
privacy-respecting home security camera while you are away.

- **Local activation only.** The camera starts only when you click *Start
  Monitoring*. It never starts at launch or login, and never from Telegram.
- **On-device motion detection.** Frame differencing on a 320 × 180 grayscale
  image at ≈5 FPS, with configurable sensitivity, minimum area, 3-frame
  confirmation, cooldown and lighting-change suppression.
- **Evidence.** A JPEG snapshot immediately, then an exactly 30-second
  **silent** H.264 MP4 (1280 × 720, 15 FPS, ≈1.2 Mbps).
- **Private Telegram bot.** Alert → snapshot → video, plus `/status`,
  `/events` and `/help`, accepted only from your numeric user ID.
- **Offline-proof.** Media is queued encrypted (AES-256-GCM) on disk,
  retried with exponential backoff, delivered after reconnects and restarts,
  and deleted after delivery or after at most 24 h.
- **Power aware.** Idle system sleep is prevented while armed, the display may
  sleep, a display-sleep check runs, and there is a keep-awake fallback.
- **Security first.** Keychain credentials, App Sandbox, hardened runtime, no
  microphone, no inbound port, sanitised logs, a visible state and an
  **Emergency Stop**.

![states](https://img.shields.io/badge/states-Disarmed·Arming·Armed·Motion·Recording·Uploading·Offline·Error-informational)

## Quick start

```bash
open MacSecurityAgent.xcodeproj
```

Then press ⌘R. Or build from the command line:

```bash
scripts/build-app.sh
```

```bash
cp -R build/MacSecurityAgent.app /Applications/
```

1. Create a bot with @BotFather and send `/start` to it
   ([Telegram setup](docs/TELEGRAM_SETUP.md)).
2. Menu bar → **Settings…** → **Telegram**: paste the token and your numeric
   user ID, click **Verify & Save**, then **Send Test Message**.
3. Before leaving: **Start Monitoring** (allow camera access the first time).
4. When back: **Stop Monitoring**. **Emergency Stop** (⌘.) releases the
   camera immediately and discards any recording in progress.

## Menu bar

```
Mac Security Agent            ARMED
Monitoring      ARMED
Camera          ACTIVE
Camera access   ALLOWED
Telegram        CONNECTED
Network         ONLINE
Last event      EVT-00003 · 14:32:18
Power           Power adapter
[ Stop Monitoring ]
[ Emergency Stop  ]
View Events   Settings…   Quit
```

## Documentation

| Document | Contents |
|---|---|
| [docs/INSTALLATION.md](docs/INSTALLATION.md) | Requirements, build (Xcode / CLI / SwiftPM), signing, install, uninstall |
| [docs/TELEGRAM_SETUP.md](docs/TELEGRAM_SETUP.md) | BotFather, user ID, commands, authentication rules, message formats |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | Every setting, defaults, tuning, power and display behaviour |
| [docs/PERMISSIONS.md](docs/PERMISSIONS.md) | Camera (TCC), Keychain, login item, no microphone |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Components, state machine, event lifecycle, concurrency, delivery guarantees, on-disk data |
| [docs/TESTING.md](docs/TESTING.md) | Test suites, the 20 required scenarios, manual hardware checklist |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Symptoms and fixes |

## Project layout

```
MacSecurityAgent.xcodeproj      App target (links the local package)
MacSecurityAgent/
  Package.swift                 MacSecurityCore library + tests
  Sources/App                   SwiftUI menu-bar app
  Sources/{Camera,Monitoring,Telegram,Storage,Security,Models,Support}
  Tests/                        XCTest suites
  Resources/                    Info.plist, entitlements
scripts/                        build-app.sh, build-app-spm.sh, test.sh, linux-test.sh
docs/
```

## Requirements

Apple Silicon MacBook, macOS 14+, Xcode 16+ (Swift 6). The app is built for
arm64 only.

## Known limitations

- **Closed lid:** not supported. macOS sleeps the system and the camera is
  covered. On wake the agent notifies you and restarts the camera.
- **Display sleep:** expected to leave the camera running. A built-in check
  verifies this on your Mac and falls back to keeping the display awake if
  frames stop. Confirm it on your own hardware with the checklist in
  [docs/TESTING.md](docs/TESTING.md).
- **Keyboard backlight:** macOS has no public API to control it, so this
  feature is not provided. The backlight follows the system's idle timeout and
  turns off with the display.
- **Delivery is at-least-once.** A crash during an upload can produce one
  duplicate, labelled "[Resent after restart – may be a duplicate]".
- **Forced termination during recording** (crash, power loss) loses that
  recording's video, because unfinalised MP4s are unplayable. A normal Quit
  finalises and delivers it.
- **Secure deletion** on APFS/SSD is best-effort. Encryption at rest is what
  protects queued media.
- **Uploads:** Telegram's Bot API limit is 50 MB. A 30 s clip at 1.2 Mbps is
  ≈4.5 MB.
- **Legal:** recording people may be regulated where you live. Tell anyone
  else who uses the space.
