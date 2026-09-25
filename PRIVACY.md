# Privacy Policy

**Last updated:** September 25, 2026

## Overview

SimpleShot is a free, open-source screenshot and annotation tool for macOS. It runs entirely on your device. There are no servers, no accounts, and no network access: the app does not request the network entitlement and contains no code that connects to the internet.

## What SimpleShot does NOT do

- **No telemetry or analytics** — nothing is tracked or sent anywhere.
- **No data collection** — no personal information, usage statistics or crash reports are collected.
- **No uploads** — screenshots never leave your Mac unless you copy, save or share them yourself.
- **No automatic updates** — the app does not check for updates. Updates come through Homebrew (`brew upgrade --cask simpleshot`) or by downloading a new release yourself.

## Data stored on your device

- **Screenshots** — saved to the folder you choose, or copied to the clipboard.
- **Preferences** — stored in macOS UserDefaults, inside the app's sandbox container.
- **Temporary files** — short-lived scratch files in the system temporary directory, cleaned up automatically.

## Permissions

- **Screen Recording** is required to capture the screen. You can revoke it in System Settings > Privacy & Security > Screen Recording.
- **Accessibility** is only requested for scroll capture and for snapping to individual interface elements. It is optional.

OCR and QR code reading use Apple's on-device Vision framework; no image data is sent to Apple or anyone else by SimpleShot.

## Open source

The complete source code is available at [https://github.com/zkmn73/SimpleShot](https://github.com/zkmn73/SimpleShot), so you can verify these claims. SimpleShot is a fork of [macshot](https://github.com/sw33tLie/macshot).

## Contact

Questions about this policy: open an issue at [https://github.com/zkmn73/SimpleShot/issues](https://github.com/zkmn73/SimpleShot/issues).
