# App Store Previews

This directory contains the reusable workflow for producing App Store screenshot
assets for the TaskMenu macOS listing.

## Inputs

The generator uses three source screenshots:

- The main task list popover
- The task edit/detail popover
- The settings popover

These screenshots should be captured from the real app so the generated App
Store assets reflect the current UI. The source paths are configured in
`generate_previews.py`.

## Workflow

Run the generator from the repository root:

```bash
python3 AppStorePreviews/generate_previews.py
```

The script composites each source screenshot into a 16:10 macOS desktop-style
marketing frame. It adds short product copy, places the menu bar popover in
context, masks the captured popover edges for clean rounded corners, and
replaces any real task names in task-related screenshots with fake sample data.

The script creates three App Store-ready PNGs at `2880x1800`, plus resized
copies in:

- `2560x1600/`
- `1440x900/`
- `1280x800/`

All exported images are RGB PNGs sized for Apple's accepted macOS screenshot
requirements.
