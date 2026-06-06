# VolumeScroll

A lightweight macOS menu bar app that displays your system volume and lets you scroll over it to adjust the volume.

https://github.com/user-attachments/assets/162535d5-98dc-4666-9688-a1967cad4587

## Features

- Shows a volume icon and percentage in the menu bar
- Scroll up/down over the icon to raise or lower the volume
- Supports both trackpad and mouse wheel
- Syncs with system volume changes

## How to Install

1. Download `VolumeScroll.zip` from the [GitHub release page](https://github.com/HareChaser/VolumeScroll/releases).
2. Extract the file and copy the **VolumeScroll** app to your **Applications** folder.
   > **Note:** If you are downloading via Safari, it will automatically unzip the file for you. Just drag the downloaded app directly into Applications.

## How to Use

1. Run VolumeScroll. A volume icon displaying the volume percentage will appear in your menu bar.
2. Hover your mouse pointer over the icon and scroll (using your mouse wheel or trackpad) to adjust the volume.

## Troubleshooting

### "VolumeScroll is damaged and should be moved to the Trash"

This is a standard macOS security measure for unsigned apps downloaded outside the App Store. The app is completely safe. To fix it:

1. Copy VolumeScroll.app to Applications folder
2. Open the **Terminal** app.
3. Paste the following command and press Return:
   ```bash
   xattr -cr /Applications/VolumeScroll.app
   ```
4. Launch VolumeScroll again!

## Build & Run (only for people who want to build the app from source code)

```bash
./build.sh
open build/VolumeScroll.app
```

To install:

```bash
cp -r build/VolumeScroll.app /Applications/
```
