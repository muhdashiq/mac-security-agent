# macOS permission setup

| Resource | Used? | How |
|---|---|---|
| Camera | Yes, only while armed | TCC prompt on the first Start Monitoring (`NSCameraUsageDescription`) |
| Microphone | **Never** | No audio input is created, no permission is requested, and the sandbox entitlement `com.apple.security.device.audio-input` is absent |
| Network | Outbound HTTPS only | `com.apple.security.network.client`; there is no server entitlement, so the app cannot listen on a port |
| Keychain | Bot token and media key | App's own items, this device only |
| Login item | Optional | `SMAppService.mainApp` |

## Camera

1. Click **Start Monitoring** for the first time. macOS shows the standard
   "MacSecurityAgent would like to access the camera" dialog. Click **Allow**.
2. If you clicked Don't Allow, the menu shows *Camera access: DENIED* and
   offers **Open Camera Privacy Settings…**. Enable MacSecurityAgent under
   System Settings › Privacy & Security › Camera, then press Start Monitoring
   again.
3. To reset the decision for testing, run:
   ```bash
   tccutil reset Camera com.macsecurityagent.app
   ```

The green camera indicator next to the lens and the camera icon in the menu
bar are controlled by macOS. The app does not and cannot suppress them. They
are on exactly while monitoring is armed.

The permission is tied to the app's code signature. An ad-hoc signed build
("Sign to Run Locally") can be prompted again after rebuilding, because its
signature changes. Sign with your Apple Development team (see
[INSTALLATION.md](INSTALLATION.md)) to keep the grant across builds.

## Keychain

The first time an ad-hoc signed build reads its items, macOS may ask
"MacSecurityAgent wants to use your confidential information stored in
'com.macsecurityagent.credentials'". Click **Always Allow**. A build signed
with a team ID uses the data-protection keychain and does not prompt.

## Login item

When **Open at login** is enabled, macOS may show "Login Items Added" and,
depending on policy, require approval under System Settings › General ›
Login Items. The settings window shows a button that opens that page when
approval is pending. The app must be in `/Applications` for launchd to find it
reliably.

## Notifications

The app sends no local macOS notifications. All alerts go to Telegram. No
notification permission is needed.
