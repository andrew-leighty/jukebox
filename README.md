# Jukebox

Scan an NFC card → Home Assistant → the Mac Mini's Music app plays that album on the HomePods.

```
NFC card ──scan──▶ Home Assistant ──jukebox_command event──▶ jukebox helper (Mac Mini) ──AppleScript──▶ Music ──AirPlay──▶ HomePods
           (phone app now,          automation:                  LaunchAgent, connects to
            ESPHome reader later)   "Jukebox: play scanned card"   HA over WebSocket
```

## One-time setup

1. **Home Assistant token.** In Home Assistant, open your profile → Security → Long-lived access tokens → Create token (name it "Jukebox") and copy the whole token. Then save it from the clipboard into the Mac's Keychain. Don't use the interactive `-w` prompt; it cuts off long tokens.

   ```bash
   security delete-generic-password -s jukebox-ha-token 2>/dev/null; security add-generic-password -s jukebox-ha-token -a jukebox -w "$(pbpaste)" && pbcopy < /dev/null
   ```

   Check it. This should print `200`:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $(security find-generic-password -s jukebox-ha-token -w)" http://homeassistant.local:8123/api/
   ```

2. **Restart the helper**, so it picks up the token:

   ```bash
   launchctl kickstart -k gui/$(id -u)/com.andrewleighty.jukebox
   ```

3. **Allow it to control Music.** The helper runs as `~/Applications/Jukebox.app` (no Dock icon). When it starts, it checks that it can control Music. If macOS asks whether "Jukebox" may control "Music", click **Allow**. This permission shows up under System Settings → Privacy & Security → Automation → Jukebox.

## Making a card

In the Home Assistant iPhone app: Settings → Tags → **+** → Write tag, then hold the phone to a blank NTAG215 card. Give the tag a name:

| Tag name | What it does |
|---|---|
| `Frayed At Both Ends` | Plays that album from your library on the default speaker (Theater Room) |
| `Greatest Hits \| Queen` | Picks the artist when several albums share a title |
| `Frayed At Both Ends @ Office` | Plays on another AirPlay speaker |
| `Jukebox: Stop` | Also `Pause`, `Play`, `Play/Pause`, `Next`, `Previous`, `Volume Up`, `Volume Down`, `Volume 40` |

The album must be in your Music library (add it from Apple Music first). If the exact title doesn't match, the helper falls back to any library album whose title contains the name. Problems show up as a "Jukebox" notification in Home Assistant.

Cards written by the Home Assistant app keep working when you add an ESPHome reader box.

## Home Assistant pieces

- Automation **Jukebox: play scanned card**: forwards every tag scan to the helper. Turn it off to pause the jukebox.
- Scripts **Jukebox: play album / stop / play/pause / next track / volume up / volume down**: for dashboards and voice. They work without a card.

## Settings

`~/Library/Application Support/Jukebox/config.json`:

```json
{ "defaultRoom": "Theater Room", "startVolume": 35, "volumeStep": 5,
  "haURL": "http://homeassistant.local:8123", "keychainService": "jukebox-ha-token" }
```

After editing it, restart the helper with the `launchctl kickstart` command above.

## Maintenance

- Log: `~/Library/Logs/Jukebox.log`. Each scan logs a `Received …` line, then the result. A `Received` line with nothing after it means the helper is waiting on a macOS permission.
- Rebuild/reinstall after code changes: `./install.sh`. A rebuild can ask for the Music permission again. If scans hang and no prompt appears, check Automation → Jukebox → Music.
- One or two "offline" lines right after the helper starts are normal (macOS checking local-network access); it reconnects on its own.
- Try a card without scanning: `./build/jukebox card "Frayed At Both Ends @ Office"`
- List speaker names: `./build/jukebox rooms`
