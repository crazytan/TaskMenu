from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
DOCS = Path("/Users/tan/Documents")
OUT = ROOT
SIZE = (2880, 1800)

SCREENSHOTS = [
    DOCS / "Screenshot 2026-04-27 at 15.07.43.png",
    DOCS / "Screenshot 2026-04-27 at 15.07.58.png",
    DOCS / "Screenshot 2026-04-27 at 15.08.12.png",
]


def font(size: int, weight: str = "regular") -> ImageFont.FreeTypeFont:
    path = "/System/Library/Fonts/HelveticaNeue.ttc"
    return ImageFont.truetype(path, size=size)


def rgba(hex_color: str, alpha: int = 255) -> tuple[int, int, int, int]:
    hex_color = hex_color.lstrip("#")
    return tuple(int(hex_color[i : i + 2], 16) for i in (0, 2, 4)) + (alpha,)


def text(
    draw: ImageDraw.ImageDraw,
    xy: tuple[int, int],
    value: str,
    size: int,
    fill: tuple[int, int, int, int],
    anchor: str = "la",
    weight: str = "regular",
) -> None:
    draw.text(xy, value, font=font(size, weight), fill=fill, anchor=anchor)


def desktop_background() -> Image.Image:
    width, height = SIZE
    img = Image.new("RGB", SIZE, "#dff4ff")
    px = img.load()
    for y in range(height):
        for x in range(width):
            nx = x / width
            ny = y / height
            wave = math.sin((nx * 2.8 + ny * 1.3) * math.pi) * 10
            r = int(218 - 34 * ny + 18 * nx + wave)
            g = int(244 - 18 * ny + 10 * math.sin(nx * math.pi))
            b = int(255 - 4 * nx - 18 * ny)
            px[x, y] = (max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))

    overlay = Image.new("RGBA", SIZE, (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    for cx, cy, rad, color in [
        (350, 260, 520, rgba("#7ad6d1", 54)),
        (2290, 1200, 760, rgba("#81a7ff", 58)),
        (1450, 410, 620, rgba("#fff5b7", 42)),
    ]:
        d.ellipse((cx - rad, cy - rad, cx + rad, cy + rad), fill=color)
    overlay = overlay.filter(ImageFilter.GaussianBlur(90))
    img = Image.alpha_composite(img.convert("RGBA"), overlay)

    d = ImageDraw.Draw(img)
    d.rounded_rectangle((96, 96, 2784, 1704), radius=54, outline=rgba("#ffffff", 82), width=2)
    d.rectangle((0, 0, width, 56), fill=rgba("#f9fbfd", 176))
    text(d, (40, 33), "TaskMenu", 25, rgba("#1e3e56", 210), anchor="lm")
    text(d, (220, 33), "File   Edit   View   Window   Help", 22, rgba("#1e3e56", 150), anchor="lm")
    text(d, (2548, 33), "Mon Apr 27  3:12 PM", 22, rgba("#1e3e56", 150), anchor="lm")
    d.rounded_rectangle((2454, 9, 2505, 47), radius=18, fill=rgba("#cfe6f8", 220))
    d.ellipse((2471, 19, 2488, 36), fill=rgba("#1d6fe8", 255))
    return img.convert("RGBA")


def scrub_list(src: Image.Image) -> Image.Image:
    img = src.convert("RGBA")
    d = ImageDraw.Draw(img)
    bg = rgba("#c7e9ff", 255)
    d.rectangle((0, 226, img.width, 895), fill=bg)
    d.line((0, 226, img.width, 226), fill=rgba("#a8cfe6", 160), width=1)
    d.line((0, 895, img.width, 895), fill=rgba("#93bbd6", 145), width=1)

    for cy in (278, 363):
        d.ellipse((57, cy - 16, 91, cy + 18), outline=rgba("#4f7188"), width=2)

    def calendar_icon(x: int, y: int, color: tuple[int, int, int, int]) -> None:
        d.rounded_rectangle((x, y, x + 19, y + 18), radius=3, outline=color, width=2)
        d.rectangle((x + 2, y + 5, x + 17, y + 7), fill=color)
        for dx in (5, 10, 15):
            d.rectangle((x + dx, y + 10, x + dx + 2, y + 12), fill=color)

    text(d, (112, 252), "Review project brief", 26, rgba("#06131f"), anchor="la")
    calendar_icon(114, 287, rgba("#45687d"))
    text(d, (153, 292), "Apr 29, 2026", 21, rgba("#45687d"), anchor="la")
    text(d, (112, 339), "Book team lunch", 26, rgba("#06131f"), anchor="la")
    calendar_icon(114, 374, rgba("#ff2d55"))
    text(d, (153, 379), "Apr 17, 2026", 21, rgba("#ff2d55"), anchor="la")

    d.line((40, 461, 47, 468), fill=rgba("#4d7084"), width=3)
    d.line((47, 468, 40, 475), fill=rgba("#4d7084"), width=3)
    text(d, (57, 460), "Completed (24)", 22, rgba("#4d7084"), anchor="la")
    return img


def scrub_detail(src: Image.Image) -> Image.Image:
    img = src.convert("RGBA")
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((66, 253, 560, 289), radius=8, fill=rgba("#b9d9ee", 255))
    text(d, (71, 258), "Review project brief", 25, rgba("#06131f"), anchor="la")
    d.rounded_rectangle((427, 454, 560, 499), radius=12, fill=rgba("#c7e1f4", 255))
    text(d, (446, 467), "4/29/2026", 24, rgba("#06131f"), anchor="la")
    return img


def add_shadow(base: Image.Image, image: Image.Image, xy: tuple[int, int], blur: int = 36) -> None:
    x, y = xy
    shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    mask = image.getchannel("A")
    shadow.paste((32, 68, 96, 112), mask=mask)
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    base.alpha_composite(shadow, (x + 0, y + 18))
    base.alpha_composite(image, xy)


def popover_cutout(image: Image.Image) -> Image.Image:
    raw = image.convert("RGBA")
    crop = raw.crop((8, 4, raw.width - 6, raw.height - 6))
    width, height = crop.size
    radius = int(min(width, height) * 0.065)

    panel = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    d = ImageDraw.Draw(panel)
    d.rounded_rectangle(
        (0, 0, width - 1, height - 1),
        radius=radius,
        fill=rgba("#c4e8ff"),
        outline=rgba("#50728a", 210),
        width=2,
    )

    mask = Image.new("L", (width, height), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (2, 2, width - 3, height - 3),
        radius=radius - 2,
        fill=255,
    )
    panel.alpha_composite(crop)
    panel.putalpha(mask.filter(ImageFilter.GaussianBlur(0.2)))

    outline = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    ImageDraw.Draw(outline).rounded_rectangle(
        (1, 1, width - 2, height - 2),
        radius=radius,
        outline=rgba("#4d6f86", 180),
        width=2,
    )
    panel.alpha_composite(outline)
    return panel


def compose(idx: int, screenshot: Image.Image, headline: str, subhead: str, filename: str) -> None:
    canvas = desktop_background()
    d = ImageDraw.Draw(canvas)

    text(d, (180, 430), headline, 92, rgba("#12344b"), anchor="la")
    lines = subhead.split("\n")
    for line_idx, line in enumerate(lines):
        text(d, (184, 585 + line_idx * 62), line, 42, rgba("#365b71", 225), anchor="la")

    scale = 1.34 if idx != 2 else 1.55
    pop = popover_cutout(screenshot).resize(
        (int(screenshot.width * scale), int(screenshot.height * scale)),
        Image.Resampling.LANCZOS,
    )
    pop_x = 1710 if idx != 2 else 1750
    pop_y = 205 if idx != 2 else 320
    canvas.alpha_composite(pop, (pop_x, pop_y))

    # Tiny pointer to make the window feel attached to the real menu bar.
    d.polygon([(2477, 55), (2445, 112), (2509, 112)], fill=rgba("#b9def5", 235))

    canvas = canvas.convert("RGB")
    canvas.save(OUT / filename, "PNG", optimize=True)


def main() -> None:
    raw = [Image.open(path) for path in SCREENSHOTS]
    images = [scrub_list(raw[0]), scrub_detail(raw[1]), raw[2].convert("RGBA")]
    specs = [
        (
            0,
            images[0],
            "Tasks, one click away",
            "Open Google Tasks from the menu bar.\nAdd, filter, and complete work without breaking flow.",
            "taskmenu-preview-01-tasks.png",
        ),
        (
            1,
            images[1],
            "Edit details in seconds",
            "Set due dates, notes, and subtasks in a compact native panel.",
            "taskmenu-preview-02-edit.png",
        ),
        (
            2,
            images[2],
            "Quiet by design",
            "Launch at login, enable due-date alerts, and keep TaskMenu out of the Dock.",
            "taskmenu-preview-03-settings.png",
        ),
    ]
    for spec in specs:
        compose(*spec)

    for export_size in [(2560, 1600), (1440, 900), (1280, 800)]:
        export_dir = OUT / f"{export_size[0]}x{export_size[1]}"
        export_dir.mkdir(exist_ok=True)
        for _, _, _, _, filename in specs:
            large = Image.open(OUT / filename).convert("RGB")
            large.resize(export_size, Image.Resampling.LANCZOS).save(
                export_dir / filename,
                "PNG",
                optimize=True,
            )


if __name__ == "__main__":
    main()
