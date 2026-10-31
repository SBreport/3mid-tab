# 3mid-tab

`3mid-tab` maps a three-finger trackpad tap to a middle mouse click on macOS.

It is a small personal utility built for a school project. It uses macOS local APIs only: AppKit, CoreGraphics, Accessibility, and the private `MultitouchSupport.framework`.

## Features

- Detects global three-finger trackpad taps.
- Sends a middle mouse click at the current cursor position.
- Converts a physical middle-button drag into vertical and horizontal scrolling.
- Includes a menu bar icon and small debug window.
- Ships as a `.dmg` installer image.
- Uses no paid service or external web service.

## Install

1. Download `3mid-tab.dmg` from Releases.
2. Open the DMG.
3. Drag `3mid-tab.app` into Applications.
4. Open `3mid-tab`.
5. Enable it in:

```text
System Settings
→ Privacy & Security
→ Accessibility
→ 3mid-tab
```

## Requirements

- macOS 13 or newer
- Xcode Command Line Tools
- Accessibility permission

## Build an app bundle

```sh
chmod +x Scripts/build-app.sh
./Scripts/build-app.sh
open build/3mid-tab.app
```

For local development, install and run the app from `/Applications` so Accessibility permission matches the installed app path:

```sh
chmod +x Scripts/install-local.sh
./Scripts/install-local.sh
```

To update an installed copy, build and run the same install script again. It replaces `/Applications/3mid-tab.app`; the Accessibility permission is associated with that installed app path.

## Build a DMG

```sh
chmod +x Scripts/package-dmg.sh
./Scripts/package-dmg.sh
open dist/3mid-tab.dmg
```

## How it works

`GlobalMultitouchMonitor` loads the private `MultitouchSupport.framework` at runtime and receives global multitouch callbacks.
When it sees a short three-finger tap, it calls `MiddleClickEmitter`, which posts `kCGEventOtherMouseDown` and `kCGEventOtherMouseUp` events with `kCGMouseButtonCenter`.
The monitor also watches callback health and re-registers the touch devices automatically when callbacks stop after a USB/display or sleep-wake change.

The debug window still supports local touch testing and shows whether Accessibility permission is currently allowed.

## Mouse auto-scroll

Use the menu bar menu item `Mouse Auto Scroll (Middle + Move)` to enable or disable the feature.
It is disabled by default.
When enabled, a physical middle-button click with no movement remains a normal middle click.
Holding the middle button and moving the mouse produces vertical or horizontal scroll events instead.

Use `Restart 3mid-tab` from the menu bar menu to reload the app and re-register the global input monitors after a display or USB device change.

## Roadmap

- Keep the current global three-finger tap behavior stable.
- Add a simple launch-at-login option.
- Add a sensitivity setting only if false positives become a real problem.
- Replace private API usage only if Apple ships a public global trackpad-touch API.

## Notes

This app uses a private macOS framework, so it is intended for personal or educational use. App Store distribution is not expected to work.

The DMG produced by the local scripts is ad-hoc signed. Public distribution without Gatekeeper warnings requires an Apple Developer ID certificate and notarization.
