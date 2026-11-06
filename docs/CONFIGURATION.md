# Configuration guide

All settings live in **Settings…**, opened from the menu bar. Changes apply
immediately, except video duration and resolution, which take effect the
next time monitoring is started. Settings are stored in the app's user
defaults. The bot token is never stored there; it lives in the Keychain.

## Monitoring

| Setting | Default | Range | Effect |
|---|---|---|---|
| Sensitivity | 0.5 | 0–1 | Per-pixel change threshold: 50 (low) to 12 (high) grey levels on the 320 × 180 analysis image |
| Minimum movement area | 1.0 % | 0.2–10 % | Share of the frame that must change for a frame to count |
| Consecutive frames | 3 | 1–10 | Qualifying frames in a row (at ≈5 FPS; 3 frames ≈ 0.6 s) before an event |
| Event cooldown | 30 s | 5–600 s | Quiet time after an event *finishes* before a new one may start |
| Video duration | 30 s | 5–60 s | Recording length; the file duration is exact |
| Video resolution | 1280 × 720 | 720p / 540p / 360p | Output size of the H.264 file (capture stays at 720p) |

Fixed parameters: capture 1280 × 720, recording 15 FPS, average bitrate
≈1.2 Mbps, keyframe every 2 s, MP4 container, no audio track, analysis at
≈5 FPS. Triggers are ignored for the first 3 seconds after arming so auto
exposure can settle and you can leave the room.

### Tuning tips

- **False alerts from flicker, curtains or a TV:** lower the sensitivity, or
  raise the minimum area to 2–3 %.
- **People far from the camera are missed:** raise the sensitivity, or lower
  the minimum area to 0.5 %.
- **Lights switching on or off:** suppressed automatically. A jump of more than
  18 % in mean brightness re-baselines the detector and the next 3 frames are
  ignored.
- **Pets:** raise the minimum area. Detection is pixel-based; it does not
  recognise objects.

## Telegram

See [TELEGRAM_SETUP.md](TELEGRAM_SETUP.md).

## Notifications

| Toggle | Default |
|---|---|
| Send text alert / snapshot / video | on |
| Monitoring armed / disarmed | on |
| Camera problems, sleep and wake | on |
| Failed or expired deliveries | on |
| Rejected commands from unknown users | on |

Turning **Record and send video** off also stops local recording.

## General

| Setting | Default | Notes |
|---|---|---|
| Open at login | off | Uses `SMAppService`. Starting at login never arms monitoring. If macOS asks, approve it in System Settings › General › Login Items. |
| Retention | 24 h | 1–24 h. Undelivered encrypted media is deleted after this period and reported as expired. |
| Keep display awake while armed | off | Fallback when display sleep stops the camera (see Power). |

## Power and display

While armed, the agent holds a `PreventUserIdleSystemSleep` assertion. The
Mac stays awake but the display may sleep on its normal schedule. When the
display first sleeps during a session, the agent checks after 15 seconds
whether camera frames are still arriving:

- frames continue: **Verified – camera keeps running**;
- frames stopped: the display is woken, a `PreventUserIdleDisplaySleep`
  assertion is taken for the rest of the session, and you get a Telegram
  notice. Lower the screen brightness manually to save power.

All assertions are released when monitoring stops. Check this yourself with:

```bash
pmset -g assertions | grep -A2 MacSecurityAgent
```

The lid must stay open. When the lid is closed macOS sleeps the system (and
the camera is covered), so closed-lid monitoring is not supported. Battery
operation works; the menu shows the power source and `/status` reports it.
Using the power adapter is recommended for long sessions.
