# Privacy Policy

**Last updated:** March 22, 2026

## Overview

macshot is a free, open-source screenshot and screen recording tool for macOS. It is designed to run entirely on your device. We do not operate any servers, and we do not collect, store, or have access to any of your data.

## What macshot does NOT do

- **No telemetry or analytics** — macshot does not phone home, track usage, or send any data to us.
- **No data collection** — we do not collect personal information, usage statistics, crash reports, or any other data.
- **No server-side storage** — we do not operate any servers. All screenshots, recordings, and settings are stored locally on your Mac.
- **No access to your uploads** — when you upload to Google Drive, files go directly to your own Google Drive account. We cannot see, access, or download your files. When you upload to imgbb, files go directly to imgbb's servers under their privacy policy.

## Data stored on your device

macshot stores the following data locally on your Mac:

- **Screenshots and recordings** — saved to your chosen folder (default: Pictures).
- **Screenshot history** — recent captures stored in `~/Library/Application Support/com.zkmn73.simpleshot/history/`. You control the history size in Preferences (set to 0 to disable).
- **Preferences** — settings stored in macOS UserDefaults.
- **Google Drive OAuth tokens** — if you sign in to Google Drive, authentication tokens are stored in `~/Library/Application Support/com.zkmn73.simpleshot/gdrive_tokens.json` with owner-only permissions (0600). Tokens are used solely to upload files to your own Google Drive. You can sign out at any time in Preferences, which deletes the token file.

## Third-party services

macshot integrates with the following optional third-party services. Use of these services is entirely opt-in:

### Google Drive
- **Purpose:** Upload screenshots and recordings to your own Google Drive.
- **Scope:** `drive.file` — macshot can only access files it created in your Drive. It cannot read, list, or modify any other files in your Drive.
- **Data sent:** The image or video file you choose to upload, plus a filename.
- **Authentication:** OAuth 2.0. You sign in via Google's login page in your browser. macshot stores a refresh token locally (see above) to avoid repeated sign-ins.
- **Revoking access:** You can sign out in macshot Preferences, or revoke access at any time from [Google Account Permissions](https://myaccount.google.com/permissions).

### imgbb
- **Purpose:** Upload screenshots to imgbb for shareable image links.
- **Data sent:** The image file you choose to upload.
- **imgbb's privacy policy:** [https://imgbb.com/privacy](https://imgbb.com/privacy)

### Sparkle (auto-updates)
- **Purpose:** Check for and install macshot updates.
- **Data sent:** A request to `https://raw.githubusercontent.com/sw33tLie/macshot/main/appcast.xml` to check for new versions. No personal data is included in the request.

## Permissions

macshot requests **Screen Recording** permission from macOS. This permission is required to capture screenshots and record your screen. macOS controls this permission — you can revoke it at any time in System Settings > Privacy & Security > Screen Recording.

## Open source

macshot is fully open source. You can inspect the complete source code at [https://github.com/sw33tLie/macshot](https://github.com/sw33tLie/macshot) to verify these claims.

## Contact

If you have questions about this privacy policy, open an issue at [https://github.com/sw33tLie/macshot/issues](https://github.com/sw33tLie/macshot/issues).
