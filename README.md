# NotchHub

A small macOS app that turns the MacBook notch into a hub. Hover over the notch and a Liquid Glass panel slides out with:

- **Now Playing:** The Spotify or Apple Music track with album art, a progress bar and play/pause/skip controls. While music plays, the collapsed notch shows a mini cover and an animated equalizer.
- **Clipboard history:** Text and images in separate tabs. Click an item to copy it again, or drag an image straight into another app. Password-manager secrets are skipped, and history is kept in memory only.
- **Shortcuts:** One-click links to your sites, plus the Claude desktop app.
- **Screen recording:** Record the screen with system audio to `~/Movies/NotchHub`. While it records, the collapsed notch shows a red dot and a timer, and NotchHub keeps itself out of the video.
- **Volume and brightness bar:** A Liquid Glass bar that drips out of the notch like liquid and replaces the native macOS overlay. While the panel is open, it slides out from under the panel instead.
- **Charging animation:** Plugging in sends a soft green light sweep across the notch, with a bolt and your battery percentage.
- **Live indicators:** The collapsed notch shows music, recording or charging status, and blur-melts from one to the next.
- **Audio visualizer:** While music plays, the collapsed notch's bars react to the real song (bass to treble).
- **Per-app volume:** Flip the Now Playing card to a mixer with a slider for every app making sound. Levels are remembered.
- **Who's watching:** When an app uses the camera or microphone, the notch shows its icon with a green or orange dot.
- **Caps Lock and keyboard language:** A glass bar flashes "Caps Lock On" or "EN → AR" when either changes.
- **Low battery glow:** An amber rim at 20% and a red one at 10% while on battery.
- **App-aware strip:** With Xcode in front, the panel shows build status with Build/Run/Stop; with Safari or Chrome, the tab with a QR code to open it on your phone.
- **Claude Code status:** An amber indicator in the notch when a Claude Code session needs your permission (see below).
- **Window snapping:** Drag a window to a screen edge or corner, or press ⌃⌥T once for a half, twice for a third, three times for full screen. Windows glide into place.
- **Downloads tidy-up:** New downloads are sorted into folders by type; files untouched for 30 days move to `Downloads/Old`; leftover installers show up in the panel. Nothing is ever deleted.
- **GlassDock toggle:** Switches the companion [GlassDock](#glassdock) app on and off, restoring the normal Dock when off.

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
| **System Audio Recording** | Per-app volume and the audio visualizer. Audio never leaves your Mac and isn't saved. |
| **Downloads folder** | Sorting your downloads. |
| **Automation (Spotify / Music / Xcode / Safari / Chrome)** | Lets NotchHub read the current track and send play, pause and skip commands. |

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

## Claude Code status

Add these hooks to `~/.claude/settings.json` (adjust the path if you cloned elsewhere). Only the event type, session ID and project folder name are sent to the notch, never your prompts.

```json
"hooks": {
  "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/NotchHub/build/NotchHub.app/Contents/MacOS/NotchHub --claude-hook", "timeout": 5 }] }],
  "Notification":     [{ "hooks": [{ "type": "command", "command": "~/NotchHub/build/NotchHub.app/Contents/MacOS/NotchHub --claude-hook", "timeout": 5 }] }],
  "Stop":             [{ "hooks": [{ "type": "command", "command": "~/NotchHub/build/NotchHub.app/Contents/MacOS/NotchHub --claude-hook", "timeout": 5 }] }],
  "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "~/NotchHub/build/NotchHub.app/Contents/MacOS/NotchHub --claude-hook", "timeout": 5 }] }]
}
```

## GlassDock

The Dock icon in the Shortcuts header turns GlassDock on and off. It expects the GlassDock app built at `~/GlassDock/build/GlassDock.app`, and is hidden if it isn't there.

## Local add-ons

If the app contains a class registered as `NotchHubLocalExtension` that conforms to `LocalExtension` (see `LocalExtensions.swift`), NotchHub loads it at launch, and otherwise nothing happens. This lets you keep personal features in a folder that git ignores only on your machine (for example by listing it in `.git/info/exclude`) without breaking the shared build.

## Screenshots in the image clipboard

To send every screenshot to the clipboard, and so to NotchHub, press **Cmd+Shift+5 → Options → Save to → Clipboard**. To send just one, add **Ctrl** to the usual shortcut, e.g. **Cmd+Ctrl+Shift+4**.
