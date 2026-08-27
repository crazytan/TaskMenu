# App Store Previews

This directory contains the workflow for producing App Store screenshot assets
for the TaskMenu macOS listing. It runs in two steps: capture the app, then
frame the captures.

## 1. Capture the sources

```bash
xcodebuild build -project TaskMenu.xcodeproj -scheme "TaskMenu (App Store)" \
  -configuration AppStore -destination "platform=macOS"

python3 AppStorePreviews/capture_sources.py
```

The captures come from the **App Store** configuration on purpose: `APP_STORE_BUILD`
compiles the update checker and the donation section out of Settings, so a Debug
capture would show controls the shipping Mac App Store build does not have. App
Review rejects screenshots that don't match the current build (guideline 2.3.3).

This launches the app once per screen with `--testing-window --capture <screen>`
and writes cropped, content-only PNGs to `sources/`:

- `01-list.png` - the task list
- `02-task.png` - the task edit screen
- `03-settings.png` - the Settings window

`--capture` renders the demo sample data while signed in, so the captures show
realistic content with no demo banner, and never a real Google account's tasks.
The app prints the window it wants captured and the script grabs that window by
number, so the crop does not depend on window position, wallpaper, or whatever
else is on screen. Add a screen by extending `TaskMenuApp.CaptureScreen` and the
`SCREENS` list in the script.

## 2. Generate the previews

```bash
python3 AppStorePreviews/generate_previews.py
```

Each capture is composited onto a marketing canvas with a menu bar above it and
headline copy alongside. The list and task screens hang off the status item the
way the real popover does; Settings is framed on its own because it is a real
window, not a popover.

Captures are placed as-is. Nothing is painted over the UI, so a preview cannot
drift from what the app actually renders - re-run step 1 after UI changes and
the previews follow.

The script writes three PNGs at `2880x1800`, plus resized copies in:

- `2560x1600/`
- `1440x900/`
- `1280x800/`

All exported images are RGB PNGs sized for Apple's accepted macOS screenshot
requirements.

## Copy rules

Headline and subhead copy must not name another company's product. App Review
rejected the May 2026 submission under guideline 4.1(c) for exactly this, so
keep brand names out of the preview text and the App Store subtitle alike.

## Dependencies

Both scripts need Pillow:

```bash
python3 -m pip install Pillow
```
