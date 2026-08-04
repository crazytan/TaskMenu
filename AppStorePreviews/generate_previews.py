"""Composite the App Store preview images for the TaskMenu macOS listing.

Reads the window captures in ``sources/`` (produced by ``capture_sources.py``)
and frames each one on a marketing canvas: menu bar above, popover attached
beneath it, headline and supporting copy alongside.

The captures are used as-is. Nothing is redrawn or painted over them, so the
previews always show the shipping UI. Copy avoids other companies' product
names, which App Review flags under guideline 4.1(c).

    python3 AppStorePreviews/generate_previews.py
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent
SOURCES = ROOT / "sources"
SIZE = (2880, 1800)
EXPORT_SIZES = [(2560, 1600), (1440, 900), (1280, 800)]

FONT_PATH = "/System/Library/Fonts/HelveticaNeue.ttc"
REGULAR, BOLD = 0, 1

INK = "#10233a"
INK_SOFT = "#456379"
MENU_BAR_HEIGHT = 64

# Headline copy per screen. Deliberately free of other companies' brand names.
# `tethered` draws the popover hanging off the status item; Settings is a real
# window rather than a popover, so it is framed without the tether.
SPECS = [
    (
        "01-list.png",
        "taskmenu-preview-01-tasks.png",
        "Your day, one click away",
        "Every list lives in the menu bar. Add, filter, and tick things off without leaving what you're doing.",
        True,
    ),
    (
        "02-task.png",
        "taskmenu-preview-02-edit.png",
        "Details without a detour",
        "Due dates, notes, and subtasks in one compact panel that opens and closes right where you are.",
        True,
    ),
    (
        "03-settings.png",
        "taskmenu-preview-03-settings.png",
        "Quiet by design",
        "No Dock icon and no window to manage. Launch at login, switch on due-date reminders, and forget it's there.",
        False,
    ),
]


def font(size: int, weight: int = REGULAR) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT_PATH, size=size, index=weight)


def rgba(hex_color: str, alpha: int = 255) -> tuple[int, int, int, int]:
    hex_color = hex_color.lstrip("#")
    return tuple(int(hex_color[i : i + 2], 16) for i in (0, 2, 4)) + (alpha,)


def background() -> Image.Image:
    """Soft vertical wash with a few blurred colour pools for depth."""
    height = SIZE[1]
    base = Image.new("RGB", (1, height))
    top, bottom = (238, 244, 251), (214, 227, 242)
    for y in range(height):
        t = y / (height - 1)
        base.putpixel(
            (0, y),
            tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)),
        )
    img = base.resize(SIZE, Image.Resampling.BILINEAR).convert("RGBA")

    pools = Image.new("RGBA", SIZE, (0, 0, 0, 0))
    draw = ImageDraw.Draw(pools)
    for cx, cy, radius, colour in [
        (420, 1500, 720, rgba("#8fb6ff", 58)),
        (2500, 250, 640, rgba("#a9d8f5", 66)),
        (1500, 1750, 900, rgba("#c9d4ff", 44)),
    ]:
        draw.ellipse((cx - radius, cy - radius, cx + radius, cy + radius), fill=colour)
    pools = pools.filter(ImageFilter.GaussianBlur(150))
    return Image.alpha_composite(img, pools)


def menu_bar(canvas: Image.Image, icon_x: int, active: bool) -> None:
    """Translucent menu bar; `active` highlights the status item as macOS does
    while its popover is open."""
    draw = ImageDraw.Draw(canvas)
    bar = Image.new("RGBA", (SIZE[0], MENU_BAR_HEIGHT), rgba("#ffffff", 150))
    canvas.alpha_composite(bar, (0, 0))
    draw.line((0, MENU_BAR_HEIGHT, SIZE[0], MENU_BAR_HEIGHT), fill=rgba("#ffffff", 120), width=2)

    centre_y = MENU_BAR_HEIGHT // 2
    draw.text((44, centre_y), "TaskMenu", font=font(26, BOLD), fill=rgba(INK, 205), anchor="lm")
    for offset, label in ((190, "File"), (268, "Edit"), (346, "View"), (434, "Window"), (556, "Help")):
        draw.text((offset, centre_y), label, font=font(25), fill=rgba(INK, 150), anchor="lm")

    draw.text((SIZE[0] - 60, centre_y), "Mon 9:41 AM", font=font(25), fill=rgba(INK, 165), anchor="rm")

    if active:
        draw.rounded_rectangle(
            (icon_x - 34, 8, icon_x + 34, MENU_BAR_HEIGHT - 8),
            radius=14,
            fill=rgba("#2a6df4", 220),
        )
    glyph = rgba("#ffffff") if active else rgba(INK, 200)
    for row, filled in ((-11, True), (7, False)):
        cy = centre_y + row
        if filled:
            draw.ellipse((icon_x - 22, cy - 8, icon_x - 6, cy + 8), fill=glyph)
            draw.line(
                (icon_x - 19, cy, icon_x - 15, cy + 4, icon_x - 9, cy - 4),
                fill=rgba("#2a6df4") if active else rgba("#ffffff"),
                width=3,
                joint="curve",
            )
        else:
            draw.ellipse((icon_x - 22, cy - 8, icon_x - 6, cy + 8), outline=glyph, width=3)
        draw.line((icon_x - 1, cy, icon_x + 22, cy), fill=glyph, width=3)


def rounded(image: Image.Image, radius: int) -> Image.Image:
    """Mask the capture's square corners back to the popover's rounded ones."""
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, image.width - 1, image.height - 1), radius=radius, fill=255)
    out = image.convert("RGBA")
    out.putalpha(mask)
    return out


def drop_shadow(canvas: Image.Image, panel: Image.Image, xy: tuple[int, int]) -> None:
    shadow = Image.new("RGBA", (panel.width + 260, panel.height + 260), (0, 0, 0, 0))
    shadow.paste(rgba("#0d2b46", 92), (130, 130), panel.getchannel("A"))
    shadow = shadow.filter(ImageFilter.GaussianBlur(46))
    canvas.alpha_composite(shadow, (xy[0] - 130, xy[1] - 108))
    canvas.alpha_composite(panel, xy)


def wrap_lines(draw: ImageDraw.ImageDraw, text: str, typeface: ImageFont.FreeTypeFont, limit: int) -> list[str]:
    lines: list[str] = []
    for paragraph in text.split("\n"):
        line = ""
        for word in paragraph.split():
            candidate = f"{line} {word}".strip()
            if draw.textlength(candidate, font=typeface) <= limit or not line:
                line = candidate
            else:
                lines.append(line)
                line = word
        lines.append(line)
    return lines


def compose(source: Path, headline: str, subhead: str, filename: str, tethered: bool) -> None:
    canvas = background()
    capture = Image.open(source).convert("RGB")

    # Scale each capture to a consistent on-canvas height so the three
    # previews read as a set, whatever the window's own size is.
    target_height = 1180
    scale = target_height / capture.height
    panel = rounded(
        capture.resize(
            (round(capture.width * scale), target_height),
            Image.Resampling.LANCZOS,
        ),
        radius=round(20 * scale),
    )

    panel_x = SIZE[0] - panel.width - 300
    panel_y = 300
    icon_x = panel_x + panel.width // 2

    menu_bar(canvas, icon_x, active=tethered)

    if tethered:
        # Leader connecting the status item to the popover below it.
        ImageDraw.Draw(canvas).polygon(
            [(icon_x, panel_y - 46), (icon_x - 34, panel_y + 6), (icon_x + 34, panel_y + 6)],
            fill=rgba("#f4f8fd", 240),
        )

    drop_shadow(canvas, panel, (panel_x, panel_y))

    draw = ImageDraw.Draw(canvas)
    text_left = 210
    text_width = panel_x - text_left - 190

    headline_font = font(104, BOLD)
    headline_lines = wrap_lines(draw, headline, headline_font, text_width)
    body_font = font(42)
    body_lines = wrap_lines(draw, subhead, body_font, text_width)

    headline_leading, body_leading = 122, 64
    block_height = len(headline_lines) * headline_leading + 54 + len(body_lines) * body_leading
    y = (SIZE[1] - block_height) // 2

    for line in headline_lines:
        draw.text((text_left, y), line, font=headline_font, fill=rgba(INK), anchor="la")
        y += headline_leading
    y += 54
    for line in body_lines:
        draw.text((text_left, y), line, font=body_font, fill=rgba(INK_SOFT, 235), anchor="la")
        y += body_leading

    canvas.convert("RGB").save(ROOT / filename, "PNG", optimize=True)


def main() -> None:
    missing = [name for name, *_ in SPECS if not (SOURCES / name).exists()]
    if missing:
        raise SystemExit(
            "Missing source captures: "
            + ", ".join(missing)
            + "\nRun: python3 AppStorePreviews/capture_sources.py"
        )

    for source_name, filename, headline, subhead, tethered in SPECS:
        compose(SOURCES / source_name, headline, subhead, filename, tethered)
        print(f"wrote {filename}")

    for export_size in EXPORT_SIZES:
        export_dir = ROOT / f"{export_size[0]}x{export_size[1]}"
        export_dir.mkdir(exist_ok=True)
        for _, filename, *_ in SPECS:
            Image.open(ROOT / filename).convert("RGB").resize(
                export_size, Image.Resampling.LANCZOS
            ).save(export_dir / filename, "PNG", optimize=True)
        print(f"wrote {export_dir.name}/")


if __name__ == "__main__":
    main()
