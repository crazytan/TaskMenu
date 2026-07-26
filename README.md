# TaskMenu

> A lightweight, native macOS menu bar app for Google Tasks.

TaskMenu brings Google Tasks to the macOS menu bar with a fast, native AppKit interface. It stays out of the Dock, opens as a compact popover, and keeps everyday task management close without pulling you out of your work.

<p align="center">
  <img src="screenshots/task-list.png" alt="TaskMenu task list popover with quick add and filtering" width="360">
  <img src="screenshots/task-detail.png" alt="TaskMenu edit task view with due date and subtasks" width="360">
</p>

## Links

- Website: [taskmenu.crazytan.dev](https://taskmenu.crazytan.dev/)
- Privacy Policy: [taskmenu.crazytan.dev/privacy](https://taskmenu.crazytan.dev/privacy)
- Support: [taskmenu.crazytan.dev/support](https://taskmenu.crazytan.dev/support)

## Features

- Menu bar-first design with no Dock icon or main window in normal launches
- Google sign-in with OAuth 2.0 and PKCE
- Quick add, inline filtering, list switching, and refresh from the popover
- Create, edit, complete, and delete Google Tasks
- Due dates, subtasks, and local due-date reminders
- Secure token storage in the macOS Keychain
- Optional launch at login
- Native Settings window with update checks, support links, and account controls

## Requirements

To run TaskMenu:

- macOS 14.4 or later (Sonoma)

To build from source:

- Xcode 26.4 or later
- XcodeGen
- A Google Cloud project with the Google Tasks API enabled
- Google OAuth iOS credentials for the app bundle ID

## Installation

Install with Homebrew by trusting the cask first:

```bash
brew trust --cask crazytan/tap/taskmenu
brew install --cask crazytan/tap/taskmenu
```

Or download the signed and notarized DMG from the [latest GitHub release](https://github.com/crazytan/TaskMenu/releases).

## Build From Source

1. Clone the repository:

   ```bash
   git clone https://github.com/crazytan/TaskMenu.git
   cd TaskMenu
   ```

2. Create or configure a Google Cloud project:

   - Enable the Google Tasks API
   - Create an iOS OAuth client in Google Cloud Console for bundle ID `dev.crazytan.TaskMenu`

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

## Development

- Swift 6
- AppKit
- XcodeGen-generated Xcode project
- Apple frameworks only, with zero third-party dependencies
- Strict concurrency enabled
- Builds are stamped with the current git commit by `scripts/stamp_build_metadata.sh` (a scheme build pre-action), and Settings shows it next to the version

Build from the command line with:

```bash
xcodebuild build -project TaskMenu.xcodeproj -scheme TaskMenu \
  -configuration Debug \
  -destination "platform=macOS"
```

Run a focused test slice with:

```bash
xcodebuild test -project TaskMenu.xcodeproj -scheme TaskMenu \
  -configuration Debug \
  -destination "platform=macOS" \
  -only-testing:TaskMenuTests/AppStateTests
```

## FAQ: Google Tasks API Limitations

### Why does TaskMenu not match every feature in the Google Tasks web app?

TaskMenu uses the public Google Tasks API, which is smaller than the Google Tasks and Google Calendar web interfaces. The API can manage task lists and core task fields such as title, notes, completion status, ordering, subtasks, and due dates, but not every first-party UI feature is exposed as a public read/write field.

For reference, Google documents the public task resource in the [Tasks API reference](https://developers.google.com/workspace/tasks/reference/rest/v1/tasks), while the web app can also create tasks with features like date/time, deadlines, repeating schedules, and notifications in [Google Tasks Help](https://support.google.com/tasks/answer/7675838?co=GENIE.Platform%3DDesktop&hl=en).

### Why can I set a date, but not an exact task time?

The API's `due` field is date-only. Google accepts it as an RFC 3339 timestamp, but discards the time portion when the due date is set, and the API cannot read or write the time a task is due. TaskMenu therefore syncs calendar days, not task times.

### Are TaskMenu reminders the same as Google Tasks notifications?

No. Google Tasks and Google Calendar can send their own notifications for tasks, including tasks with a date and time. TaskMenu can only see the date-only value exposed by the API, so its due-date reminders are local macOS notifications scheduled by TaskMenu. They do not create or edit Google Tasks notification settings.

### Can TaskMenu create or edit repeating tasks?

Not currently. Google Tasks and Google Calendar can create repeating tasks, but the public Tasks API task resource does not expose a recurrence rule field that TaskMenu can read and write. Google's API documentation also calls out special restrictions for recurrent tasks in task moves. TaskMenu treats repeating tasks conservatively and does not create or edit repeat schedules.

See Google's [repeating tasks help](https://support.google.com/tasks/answer/12132599?co=GENIE.Platform%3DDesktop&hl=en) and the Tasks API [`move` method](https://developers.google.com/workspace/tasks/reference/rest/v1/tasks/move).

### Why does TaskMenu not show starred tasks or a Starred list?

Stars are available in Google's Tasks UI, but starred status and the Starred smart list are not fields on the public `Task` or `TaskList` resources. Without an official API field, TaskMenu cannot reliably sync, set, or filter starred tasks.

See Google's [starred tasks help](https://support.google.com/tasks/answer/12718779?co=GENIE.Platform%3DDesktop&hl=en).

### What about tasks from Gmail, Docs, Chat, or Keep?

Google's web apps can create tasks from other Workspace products. The Tasks API exposes some of that context as read-only links or assignment metadata, and assigned tasks from Docs or Chat are not returned by default unless an API client explicitly requests them. TaskMenu currently focuses on regular Google Tasks lists and does not request assigned tasks, so some source links, assignment details, and shared-task behaviors may be unavailable or read-only.

See the [`tasks.list` reference](https://developers.google.com/workspace/tasks/reference/rest/v1/tasks/list) and [Tasks API usage limits](https://developers.google.com/workspace/tasks/limits).

## Contributing

Contributions are welcome. If you have a bug report, feature request, or a focused improvement, open an issue or submit a pull request.

Issues and feature requests: [GitHub Issues](https://github.com/crazytan/TaskMenu/issues)

Maintainer release instructions live in [docs/RELEASING.md](docs/RELEASING.md).

## License

GNU GPLv3
