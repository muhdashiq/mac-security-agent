# Build and installation

## Requirements

- MacBook with Apple Silicon (M1 or later)
- macOS 14 Sonoma or later
- Xcode 16 or later (Swift 6 language mode). Xcode 26 works too.

Check your toolchain:

```bash
xcodebuild -version
```

```bash
swift --version
```

## Option A – Xcode (recommended)

1. Open `MacSecurityAgent.xcodeproj`.
2. Select the **MacSecurityAgent** scheme and **My Mac**.
3. *Optional but recommended:* under Target › Signing & Capabilities, choose
   your team. This keeps the camera permission and Keychain access stable
   across rebuilds. Without a team the project signs ad hoc ("Sign to Run
   Locally").
4. Run it with **⌘R**. A shield icon appears in the menu bar; no window and no
   Dock icon.
5. Run the tests with **⌘U**. The scheme runs the package's `MacSecurityCoreTests`.

## Option B – command line

Build a Release `.app` and a zip:

```bash
scripts/build-app.sh
```

To sign with your team instead of ad hoc:

```bash
TEAM_ID=ABCDE12345 scripts/build-app.sh
```

Run the tests:

```bash
scripts/test.sh
```

Option C builds without the Xcode project, using SwiftPM and a hand-assembled
bundle:

```bash
scripts/build-app-spm.sh
```

## Install

```bash
cp -R build/MacSecurityAgent.app /Applications/
```

```bash
open /Applications/MacSecurityAgent.app
```

1. Settings › Telegram: configure the bot (see [TELEGRAM_SETUP.md](TELEGRAM_SETUP.md)).
2. Settings › General: enable **Open at login** if you want it.
3. Position the MacBook, lid open, with the camera facing the area to
   watch. Connect power for long sessions.
4. Before leaving, click **Start Monitoring**. Allow camera access the first
   time.
5. When you return, click **Stop Monitoring**.

A locally built app is not quarantined. If you copy a zip to another Mac,
Gatekeeper blocks the unsigned or ad-hoc app. Either right-click › Open, or
sign with a Developer ID and notarise:

```bash
xcrun notarytool submit build/MacSecurityAgent.zip --keychain-profile <profile> --wait
```

```bash
xcrun stapler staple build/MacSecurityAgent.app
```

## Uninstall

Quit the app from the menu, then:

```bash
rm -rf /Applications/MacSecurityAgent.app ~/Library/Containers/com.macsecurityagent.app
```

```bash
security delete-generic-password -s com.macsecurityagent.credentials -a telegram.bot-token.v1
```

```bash
security delete-generic-password -s com.macsecurityagent.credentials -a media-encryption-key.v1
```

```bash
tccutil reset Camera com.macsecurityagent.app
```
