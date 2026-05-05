# TaskMenu

> A lightweight, native macOS menu bar app for Google Tasks.

TaskMenu brings Google Tasks to the macOS menu bar with a fast, native SwiftUI interface. It stays out of the Dock, lives entirely in the menu bar, and keeps everyday task management close at hand.

## Links

- Website: https://taskmenu.crazytan.dev/
- Privacy Policy: https://taskmenu.crazytan.dev/privacy
- Support: https://github.com/crazytan/TaskMenu/issues

## Features

- Menu bar-first macOS app with no Dock icon or main window
- Sign in with Google using OAuth 2.0
- Create, view, edit, complete, and delete tasks
- Quick add for capturing tasks inline
- Due date support
- Switch between Google Task lists
- Secure token storage in the macOS Keychain
- Optional launch at login

## Screenshots

Screenshots coming soon.

## Requirements

- macOS 14.4 or later (Sonoma)
- Xcode 16 or later
- XcodeGen
- A Google Cloud project with the Google Tasks API enabled
- Google OAuth iOS credentials for the app bundle ID

## Installation

Download signed DMGs from the GitHub releases page:

https://github.com/crazytan/TaskMenu/releases

Or build from source:

1. Clone the repository:

```bash
git clone https://github.com/crazytan/TaskMenu.git
cd TaskMenu
```

2. Create or configure a Google Cloud project:

- Enable the Google Tasks API
- Create an iOS OAuth client in Google Cloud Console for bundle ID `dev.crazytan.TaskMenu`
- If your OAuth consent screen is in Testing mode, add your Google account as a test user

3. Copy the example config and add your Google OAuth credentials:

```bash
cp Config.xcconfig.example Config.xcconfig
```

Fill in `GOOGLE_CLIENT_ID` and `GOOGLE_REDIRECT_SCHEME` in `Config.xcconfig`.

4. Generate the Xcode project:

```bash
xcodegen generate
```

5. Open `TaskMenu.xcodeproj` in Xcode and build the app.

## Tech

- Swift 6
- SwiftUI
- XcodeGen
- Apple frameworks only
- Zero third-party dependencies

## Contributing

Contributions are welcome. If you have a bug report, feature request, or a focused improvement, open an issue or submit a pull request.

Issues and feature requests: https://github.com/crazytan/TaskMenu/issues

Maintainer release instructions live in [docs/RELEASING.md](docs/RELEASING.md).

## License

GNU GPLv3
