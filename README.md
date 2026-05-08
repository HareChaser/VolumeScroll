# VolumeScroll

A lightweight macOS menu bar app that displays your system volume and lets you scroll over it to adjust the volume.

https://github.com/user-attachments/assets/de981287-168f-4a9d-829f-dc574472ef80

## Features

- Shows a volume icon and percentage in the menu bar
- Scroll up/down over the icon to raise or lower the volume
- Supports both trackpad (smooth scrolling) and mouse wheel
- Icon updates dynamically: muted, low, medium, or high volume
- Syncs with system volume changes (keyboard shortcuts, Control Center, other apps)
- Right-click the icon to quit

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode Command Line Tools

## Build & Run

```bash
./build.sh
open build/VolumeScroll.app
```

To install permanently:

```bash
cp -r build/VolumeScroll.app /Applications/
```

## Project Structure

```
src/
  main.swift          # App logic, menu bar view, CoreAudio integration
  generate_icon.swift # Programmatically generates the app icon
  Info.plist          # App bundle metadata
build.sh              # Build script
```

## How It Works

VolumeScroll uses CoreAudio to read and set the system output volume. It listens for device changes (e.g. plugging in headphones or switching to AirPlay) and automatically re-attaches its listeners to the new default output device.
