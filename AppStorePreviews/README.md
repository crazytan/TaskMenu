# App Store Previews

This directory contains App Store screenshot assets for the TaskMenu macOS listing.

The source screenshots are expected at:

- `/Users/tan/Documents/Screenshot 2026-04-27 at 15.07.43.png`
- `/Users/tan/Documents/Screenshot 2026-04-27 at 15.07.58.png`
- `/Users/tan/Documents/Screenshot 2026-04-27 at 15.08.12.png`

Run the generator from the repository root:

```bash
python3 AppStorePreviews/generate_previews.py
```

The script creates three App Store-ready PNGs at `2880x1800`, plus resized copies in:

- `2560x1600/`
- `1440x900/`
- `1280x800/`

All exported images are 16:10 RGB PNGs. The generator also replaces real task names in the task list and edit screenshots with fake sample tasks.
