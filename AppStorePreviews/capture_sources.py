"""Capture the App Store preview source screenshots from the running app.

Launches TaskMenu's testing window once per screen with `--capture <screen>`,
which renders the realistic sample data while signed in -- so the shots carry
no demo banner, and never a real Google account's tasks. The app prints the
window it wants captured, so this grabs that exact window rather than trying to
find it in a screenshot of the whole display.

Run from the repository root after building Debug:

    python3 AppStorePreviews/capture_sources.py
"""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent
SOURCES = ROOT / "sources"

SCREENS = ["list", "task", "settings"]
DESCRIPTOR = re.compile(
    r"CAPTURE window=(?P<window>\d+) titlebar=(?P<titlebar>\d+)"
    r" scale=(?P<scale>\d+) width=(?P<width>\d+)"
)


def built_app() -> Path:
    # Capture from the App Store configuration so the shots match the shipping
    # Mac App Store build: APP_STORE_BUILD compiles the update checker and the
    # donation section out of Settings, so a Debug capture would show controls
    # the listing's build does not have (App Review rejects that under 2.3.3).
    settings = subprocess.run(
        [
            "xcodebuild", "-project", "TaskMenu.xcodeproj",
            "-scheme", "TaskMenu (App Store)",
            "-configuration", "AppStore", "-destination", "platform=macOS",
            "-showBuildSettings",
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    for line in settings.splitlines():
        if " BUILT_PRODUCTS_DIR " in line:
            return Path(line.split(" = ", 1)[1].strip()) / "TaskMenu.app"
    raise SystemExit("Could not resolve BUILT_PRODUCTS_DIR; build the App Store scheme first.")


def capture(app: Path, screen: str, destination: Path) -> None:
    subprocess.run(["pkill", "-f", "TaskMenu/Contents/MacOS"], capture_output=True)
    time.sleep(1)
    process = subprocess.Popen(
        [str(app / "Contents/MacOS/TaskMenu"), "--testing-window", "--capture", screen],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    try:
        descriptor = None
        deadline = time.time() + 20
        while time.time() < deadline:
            line = process.stdout.readline()
            if not line:
                break
            descriptor = DESCRIPTOR.search(line)
            if descriptor:
                break
        if not descriptor:
            raise SystemExit(f"App did not report a capture window for '{screen}'.")

        window_number = int(descriptor.group("window"))
        titlebar = int(descriptor.group("titlebar"))
        scale = int(descriptor.group("scale"))
        expected_width = int(descriptor.group("width")) * scale
        if scale < 2:
            raise SystemExit(
                "The app's window is on a 1x display, which would ship upscaled "
                "screenshots. Move it to the Retina display and re-run."
            )
        # Let the seeded tasks land and the detail push finish animating.
        time.sleep(3)

        # screencapture refuses to write dotfiles, so keep the scratch name plain.
        with tempfile.TemporaryDirectory() as scratch:
            raw = Path(scratch) / f"raw-{screen}.png"
            # -o drops the drop shadow, so the crop is the window rect exactly.
            subprocess.run(
                ["screencapture", "-x", "-o", f"-l{window_number}", str(raw)],
                check=True,
            )
            image = Image.open(raw).convert("RGB")
            if image.width != expected_width:
                raise SystemExit(
                    f"Captured {image.width}px wide but the window is "
                    f"{expected_width}px at {scale}x; refusing to ship a rescaled shot."
                )
            image.crop((0, titlebar, image.width, image.height)).save(destination)
    finally:
        process.terminate()

    size = Image.open(destination).size
    print(f"wrote {destination.relative_to(ROOT.parent)} ({size[0]}x{size[1]})")


def main() -> None:
    app = built_app()
    if not (app / "Contents/MacOS/TaskMenu").exists():
        raise SystemExit(f"No built app at {app}; build the Debug scheme first.")
    SOURCES.mkdir(exist_ok=True)
    for index, screen in enumerate(SCREENS, start=1):
        capture(app, screen, SOURCES / f"{index:02d}-{screen}.png")


if __name__ == "__main__":
    sys.exit(main())
