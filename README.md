# NotchNotes

A lightweight macOS menu-bar utility that lives in the notch area of your screen. Press **⌥ + Space** to slide out a compact panel with notes, tasks, a timer, clipboard history, and a file shelf — no windows, no dock icon.

🇷🇺 [Читать на русском](README.ru.md)

## Features

- **Notes** — quick scratchpad notes
- **Tasks** — a simple to-do list
- **Timer** — countdown/stopwatch timer
- **Clipboard** — clipboard history
- **Shelf** — drag & drop files to keep them close at hand (drop onto the notch panel or the menu-bar icon)

Additional niceties:
- Global hotkey **⌥ + Space** to toggle the panel
- Menu-bar icon with quick access to every tab
- "Launch at login" toggle
- Runs as a background accessory app (no Dock icon, no regular windows)

## Requirements

- macOS 14.0+
- Swift 5.9+ (Xcode 15+ command line tools)

## Build & Run

```sh
./build.sh debug --run     # build and launch
./build.sh release         # release build only
```

The script builds via `swift build`, packages `build/NotchNotes.app`, and ad-hoc signs it.

## Self-check

Run the app's internal logic checks without launching the UI:

```sh
swift run NotchNotes --selfcheck
```

## Data

Your data is stored locally under `~/Library/Application Support/NotchNotes`. You can jump to it from the menu-bar icon → "Data folder".

## License

MIT © 2026 ProstoDev
