# NotchHub

A small macOS app that turns the MacBook notch into a hub. Hover over the notch and a Liquid Glass panel slides out with:

- **Now Playing:** The Spotify or Apple Music track with album art, a progress bar and play/pause/skip controls. While music plays, the collapsed notch shows a mini cover and an animated equalizer.
- **Clipboard history:** Text and images in separate tabs. Click an item to copy it again, or drag an image straight into another app. Password-manager secrets are skipped, and history is kept in memory only.
- **Shortcuts:** One-click links to your sites, plus the Claude desktop app.
- **Screen recording:** Record the screen with system audio to `~/Movies/NotchHub`. While it records, the collapsed notch shows a red dot and a timer, and NotchHub keeps itself out of the video.
- **Volume and brightness bar:** A Liquid Glass bar that drops out of the notch and replaces the native macOS overlay.

NotchHub has no Dock icon and starts automatically at login. To quit it, use the power button in the Shortcuts card. It starts again at your next login.

## Requirements

- macOS 26 (Tahoe) or later, on a Mac with a notch. It also runs on Macs without a notch, using a notch-sized pill at the top of the screen.
- Xcode 26 or the Xcode command line tools, for building.

## Build and run

```bash
git clone https://github.com/muneebfr-fr/NotchHub.git
cd NotchHub
./build.sh
```

`build.sh` compiles the app into `build/NotchHub.app` and launches it. Keep the folder where it is, because the login item points to that location.

## Permissions

| Prompt | Why |
| --- | --- |
| **Accessibility** | Lets NotchHub take over the volume, mute and brightness keys so the native overlay doesn't appear. Without it, the bar still shows for volume changes but the native overlay appears too. |
| **Screen Recording** | Needed for the Record button. macOS may ask you to quit and reopen NotchHub after you allow it. |
| **Automation (Spotify / Music)** | Lets NotchHub read the current track and send play, pause and skip commands. |

Each build has a new signature, so macOS treats it as a new app. `build.sh` clears the old Accessibility and Screen Recording entries and relaunches the app, so after rebuilding you only need to switch NotchHub back on when it asks.

## Your own shortcuts

Create `~/Library/Application Support/NotchHub/links.json`:

```json
[
  { "name": "Moodle", "url": "https://moodle.example.edu/", "symbol": "graduationcap.fill" },
  { "name": "Calendar", "url": "https://calendar.google.com", "symbol": "calendar" }
]
```

`symbol` is any [SF Symbols](https://developer.apple.com/sf-symbols/) name. Quit and reopen NotchHub to load your changes. Without this file, NotchHub shows a couple of example links.

## Screenshots in the image clipboard

To send every screenshot to the clipboard, and so to NotchHub, press **Cmd+Shift+5 → Options → Save to → Clipboard**. To send just one, add **Ctrl** to the usual shortcut, e.g. **Cmd+Ctrl+Shift+4**.
