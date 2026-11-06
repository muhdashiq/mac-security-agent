# Troubleshooting

Logs go to the unified log (subsystem `com.macsecurityagent.app`) and are
sanitised: tokens, secrets and media never appear in them. To stream them:

```bash
log stream --predicate 'subsystem == "com.macsecurityagent.app"' --level info
```

| Symptom | Cause / fix |
|---|---|
| No menu-bar icon | The menu bar is full (hidden behind the notch). Remove other items or use a menu-bar manager. The app has no Dock icon by design (`LSUIElement`). |
| *Camera access: DENIED* | System Settings › Privacy & Security › Camera → enable MacSecurityAgent. Reset with `tccutil reset Camera com.macsecurityagent.app`. |
| Camera permission asked again after every build | Ad-hoc signatures change on each build. Select your team under Signing & Capabilities. |
| "No built-in camera was found" | Only the built-in FaceTime camera is used. Check that no other app holds it exclusively and that `system_profiler SPCameraDataType` lists it. |
| Camera **NO FRAMES** / state **ERROR** while armed | Frames stopped for more than 5 s. The agent alerts you and restarts the session (at most every 2 min). Causes: lid closed, another app took the camera, system sleep. |
| Camera stops when the display sleeps | Settings › General › **Keep display awake while armed**. The display-sleep check enables this automatically when it detects the problem. |
| Mac sleeps anyway | Lid closed (unsupported) or manual sleep. Check `pmset -g assertions` for `PreventUserIdleSystemSleep` from MacSecurityAgent while armed. Low-battery shutdown cannot be prevented. |
| Telegram **NOT CONFIGURED** | Token or user ID missing. Re-enter both and click Verify & Save. |
| Verify fails with `Telegram error 401`/`404` | Wrong or revoked token. Copy it again from @BotFather. |
| Messages never arrive, status **ERROR: chat not found** | You never sent `/start` to the bot, or the user ID is wrong (it must be the numeric ID, not the @username). |
| Status **ERROR: 409 Conflict** | Another program polls the same bot, or a webhook is set. Stop it, or delete the webhook: `curl "https://api.telegram.org/bot<TOKEN>/deleteWebhook"`. |
| Telegram **OFFLINE**, menu shows *ARMED · OFFLINE* | No internet. Monitoring continues and uploads are queued encrypted, then sent automatically on reconnection. |
| *Pending uploads* never drops | Open View Events to see the status. Configuration errors retry every 5 min; fix the settings and they are retried immediately. Items older than the retention period are deleted and reported. |
| Message prefixed "[Resent after restart – may be a duplicate]" | The app stopped while that upload was in flight. See "Delivery guarantees" in [ARCHITECTURE.md](ARCHITECTURE.md). |
| Video missing after a crash or forced quit | A recording that was never finalised cannot be played. Its plaintext is deleted at the next launch and the event shows *Application terminated during recording*. A normal Quit finalises and delivers the partial video. |
| Too many or too few alerts | See "Tuning tips" in [CONFIGURATION.md](CONFIGURATION.md). |
| Keychain prompt on launch | Ad-hoc build using the login keychain: click Always Allow, or sign with a team. |
| `Open at login` does nothing | Move the app to `/Applications` and approve it under System Settings › General › Login Items. |
