# NotchHub

A small macOS app that turns the MacBook notch into a hub. Hover over the notch and a Liquid Glass panel slides out with:

- **Now Playing:** The Spotify or Apple Music track with album art, a progress bar and play/pause/skip controls. While music plays, the collapsed notch shows a mini cover and an animated equalizer.
- **Clipboard history:** Text and images in separate tabs. Click an item to copy it again, or drag an image straight into another app. Password-manager secrets are skipped, and history is kept in memory only.
- **Clipboard actions:** After you copy text, a glass pill drops from the notch with Fix grammar, Summarize (longer text) or Translate; a link offers a QR code to open it on your phone, and a screenshot offers Extract text. The same actions are on every history item (✦ on hover, or right-click). Results go onto the clipboard as a new item, so the original is never lost. Everything runs on-device with Apple's model and text recognition.
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
- **Companion app toggles:** Switch [GlassDock](#glassdock) and [Edge Shelf](#edge-shelf) on and off from the Shortcuts header. Each runs as its own app and is restarted if it crashes.

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
| **Apple Intelligence** (no prompt) | Clipboard actions use Apple's on-device model when it's enabled in System Settings; Extract text works either way. |
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

GlassDock (in the `GlassDock/` folder) is a companion app that adds window previews to the **real** macOS Dock. The Dock itself is never hidden or changed, so its look, magnification, menus, badges and Mission Control behaviour are all Apple's own.

- Hover a running app's icon and its windows appear as glass cards above it. Moving to another icon switches instantly.
- Click a card to bring up that exact window, sliding to its desktop if it's on another one.
- Drag a file over a Dock icon, onto a card, and hold: that window springs open with the cursor at the same spot, so you drop the file exactly where you aimed.

**⌥Tab window switcher:** hold ⌥ and tap Tab for live thumbnails of every window on every desktop (⇧Tab goes back, Esc cancels); release ⌥ to jump to that window. A quick ⌥Tab flips straight to your previous window. ⌘Tab is left untouched.

It follows the Dock's own hover through Accessibility, so it's event-driven and idles at zero. `./build.sh` builds it alongside NotchHub; turn it on with the Dock icon in the Shortcuts header. It asks for Accessibility (following the Dock, focusing windows) and Screen Recording (previews). Switching to a window on another desktop uses the "Move left/right a space" shortcuts (⌃← / ⌃→), which are on by default. Previews assume the Dock is at the bottom of the screen.

## Edge Shelf

Edge Shelf (in the `EdgeShelf/` folder) is a companion app: a glass shelf that slides out of the right edge of the screen. Rest the cursor against the edge for a moment, or drag something there, and drop in files, links, images or text. Click a card to open it (text is copied), drag it out into any app, or right-click for Open / Copy / Show in Finder / Remove. Files are referenced, not copied, and followed if moved; items stay until you remove them. It needs no permissions. Turn it on with the sidebar icon in the Shortcuts header.

## Local add-ons

If the app contains a class registered as `NotchHubLocalExtension` that conforms to `LocalExtension` (see `LocalExtensions.swift`), NotchHub loads it at launch, and otherwise nothing happens. This lets you keep personal features in a folder that git ignores only on your machine (for example by listing it in `.git/info/exclude`) without breaking the shared build.

## Screenshots in the image clipboard

To send every screenshot to the clipboard, and so to NotchHub, press **Cmd+Shift+5 → Options → Save to → Clipboard**. To send just one, add **Ctrl** to the usual shortcut, e.g. **Cmd+Ctrl+Shift+4**.
