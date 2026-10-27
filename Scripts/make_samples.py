#!/usr/bin/env python3
"""Generates the demo screenshots in Samples/.

The three PNGs are crops of one tall page with a known 150 px overlap between
neighbouring screenshots, so the app should stitch them back into a
1280 x 4200 image. Run from the repository root:

    python3 Scripts/make_samples.py
"""
from __future__ import annotations

import pathlib

from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "Samples"

PAGE_WIDTH = 1280
PAGE_HEIGHT = 4200
SHOT_HEIGHT = 1500
SHOT_STARTS = (0, 1350, 2700)  # 150 px overlap between neighbours

BACKGROUND = (246, 247, 250)
CARD = (255, 255, 255)
INK = (28, 32, 44)
MUTED = (104, 112, 130)
ACCENT = (58, 92, 214)

PALETTE = [
    (58, 92, 214),
    (14, 154, 128),
    (214, 96, 58),
    (156, 74, 196),
    (214, 168, 40),
    (56, 152, 214),
]


def load_font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    candidates = [
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for path in candidates:
        try:
            return ImageFont.truetype(path, size=size)
        except OSError:
            continue
    return ImageFont.load_default(size=size)


def make_page() -> Image.Image:
    image = Image.new("RGB", (PAGE_WIDTH, PAGE_HEIGHT), BACKGROUND)
    draw = ImageDraw.Draw(image)

    title_font = load_font(44, bold=True)
    subtitle_font = load_font(26)
    row_title_font = load_font(30, bold=True)
    row_body_font = load_font(24)
    badge_font = load_font(22, bold=True)

    # Header
    header = (32, 38, 78)
    draw.rectangle((0, 0, PAGE_WIDTH, 330), fill=header)
    draw.rounded_rectangle((72, 64, 200, 192), radius=34, fill=ACCENT)
    draw.rounded_rectangle((228, 84, 500, 118), radius=16, fill=(74, 84, 130))
    draw.rounded_rectangle((228, 140, 400, 170), radius=14, fill=(58, 66, 104))
    draw.text((72, 232), "OpenStitch sample page", font=title_font, fill=(255, 255, 255))
    draw.text((72, 286), "Three screenshots of this page are included in Samples/", font=subtitle_font, fill=(168, 178, 210))

    # Content cards
    top = 400
    for index in range(14):
        color = PALETTE[index % len(PALETTE)]
        card_top = top + index * 258
        draw.rounded_rectangle((72, card_top, PAGE_WIDTH - 72, card_top + 222), radius=30, fill=CARD)
        draw.rounded_rectangle((108, card_top + 42, 208, card_top + 142), radius=26, fill=color)
        draw.text((134, card_top + 72), f"{index + 1:02d}", font=badge_font, fill=(255, 255, 255))
        draw.text(
            (240, card_top + 48),
            f"Sample row {index + 1:02d} — {['Inbox', 'Reading list', 'Project notes', 'Photos', 'Metrics', 'Design review'][index % 6]}",
            font=row_title_font,
            fill=INK,
        )
        draw.text(
            (240, card_top + 98),
            "Overlapping content keeps the automatic stitcher anchored.",
            font=row_body_font,
            fill=MUTED,
        )
        bar_width = 460 + (index * 97) % 480
        draw.rounded_rectangle((240, card_top + 148, 240 + bar_width, card_top + 176), radius=14, fill=(232, 236, 245))
        draw.rounded_rectangle((240, card_top + 148, 240 + bar_width // 2, card_top + 176), radius=14, fill=color)
        draw.text(
            (PAGE_WIDTH - 300, card_top + 48),
            f"{index * 37 % 100:02d}%",
            font=badge_font,
            fill=MUTED,
        )

    # Footer
    draw.rectangle((0, PAGE_HEIGHT - 180, PAGE_WIDTH, PAGE_HEIGHT), fill=header)
    draw.text(
        (72, PAGE_HEIGHT - 122),
        "OpenStitch — stitch screenshots locally, on your Mac.",
        font=row_title_font,
        fill=(255, 255, 255),
    )

    return image


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    page = make_page()

    for index, start in enumerate(SHOT_STARTS, start=1):
        shot = page.crop((0, start, PAGE_WIDTH, start + SHOT_HEIGHT))
        path = OUT_DIR / f"screenshot-{index}.png"
        shot.save(path)
        print(f"wrote {path} ({shot.width}x{shot.height}, top={start})")

    page.save(OUT_DIR / "sample-page-full.png")
    print(f"wrote {OUT_DIR / 'sample-page-full.png'} ({page.width}x{page.height})")


if __name__ == "__main__":
    main()
