# Telegram bot setup

The agent talks only to the official Bot API (`https://api.telegram.org`)
and only outbound: it uses `getUpdates` long polling, not webhooks, so no
port is ever opened on the Mac.

## 1. Create the bot

1. In Telegram, open a chat with **@BotFather**.
2. Send `/newbot`, choose a display name and a username ending in `bot`.
3. BotFather replies with a token such as `123456789:AAH…`. Treat it like a
   password.
4. Optional hardening in BotFather:
   - `/setjoingroups` → **Disable**. The bot only answers private chats anyway.
   - `/setprivacy` → **Enable**.
   - `/setcommands` → paste:
     ```
     status - Monitoring, camera, network and last event
     events - Recent event history
     help - Available commands
     ```

## 2. Find your numeric user ID

Open **@userinfobot** (or any "user id" bot) and send it any message. It
replies with your numeric ID, for example `123456789`. This is a user ID, not
your @username.

## 3. Start the chat

Open your new bot and press **Start** (or send `/start`). Telegram does not let
a bot message someone who has never written to it first.

## 4. Configure the agent

Menu bar → **Settings…** → **Telegram**:

1. Paste the token into **Bot token**.
2. Enter your numeric ID into **Authorized Telegram user ID**.
3. Click **Verify & Save**. The agent calls `getMe` to check the token, then
   stores it in the Keychain. The token field is cleared again afterwards.
4. Click **Send Test Message**. The message should arrive within a few
   seconds.

To rotate the token, run `/revoke` in BotFather, paste the new token and click
Verify & Save. **Remove Token from Keychain** deletes the stored token.

## Commands

| Command | Reply |
|---|---|
| `/status` | Monitoring state, camera state, network, Telegram, armed-since time, last event, pending uploads, power source |
| `/events` | The 10 most recent events with snapshot and video delivery status |
| `/help`, `/start` | Command list |
| `/arm`, `/start_monitoring`, … | Explains that remote control is not supported |

Commands are accepted only when **all** of these hold:

- the sender's numeric ID equals the authorised ID and the sender is not a bot;
- it arrives in the private chat with that user (chat ID equals user ID);
- the message is not forwarded and not sent through an inline bot;
- it is less than 5 minutes old (an old backlog is never replayed);
- it is a short `/command` or `/command@YourBot` with no arguments and no
  unusual characters.

Messages from anyone else get **no reply**. If notifications for this are
enabled, the owner receives a notice that names the rejected user ID, at most
once every 10 minutes per user.

No command can activate the camera. Arming requires a click on the Mac
itself.

## Notifications

On motion, three messages arrive in this order:

1. Text alert:
   ```
   MAC SECURITY ALERT
   Motion detected.
   Event ID: EVT-00001
   Time: 14:32:18
   Camera: Active
   Video recording: Started
   Snapshot will be delivered first.
   Video will follow after recording completes.
   ```
2. Snapshot, with event ID, time and changed area.
3. 30-second silent video, sent as a streamable MP4.

Optional notices, each switchable in Settings › Notifications: armed or
disarmed, camera problems, sleep and wake, failed or expired deliveries, and
rejected users.
