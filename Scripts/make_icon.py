#!/usr/bin/env python3
"""Generates the macOS AppIcon asset PNGs for OpenStitch.

The icon is a 1024x1024 master that is downscaled to every size macOS asks for.
Run from the repository root:  python3 Scripts/make_icon.py
"""
from __future__ import annotations

import pathlib

from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parent.parent
ASSET_DIR = ROOT / "OpenStitch" / "Assets.xcassets" / "AppIcon.appiconset"

MASTER = 1024
INSET = 92
RADIUS = 208

TOP_COLOR = (58, 92, 214)
BOTTOM_COLOR = (26, 30, 74)
CARD_COLOR = (247, 249, 255)
SCREEN_COLOR = (255, 255, 255)
ACCENT = (120, 214, 255)


def vertical_gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    image = Image.new("RGB", (size, size))
    draw = ImageDraw.Draw(image)
    for y in range(size):
        t = y / max(1, size - 1)
        color = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        draw.line([(0, y), (size, y)], fill=color)
    return image


def rounded_mask(size: int, inset: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((inset, inset, size - inset, size - inset), radius=radius, fill=255)
    return mask


def make_master() -> Image.Image:
    icon = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))

    background = vertical_gradient(MASTER, TOP_COLOR, BOTTOM_COLOR).convert("RGBA")
    icon.paste(background, (0, 0), rounded_mask(MASTER, INSET, RADIUS))

    draw = ImageDraw.Draw(icon)

    # Soft highlight across the upper half of the tile.
    highlight = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    highlight_draw = ImageDraw.Draw(highlight)
    highlight_draw.rounded_rectangle(
        (INSET + 26, INSET + 26, MASTER - INSET - 26, MASTER // 2),
        radius=RADIUS - 40,
        fill=(255, 255, 255, 26),
    )
    icon.alpha_composite(highlight)

    # Two overlapping "screenshots" making up the long image.
    card_left, card_width = 286, 452
    first_top, first_bottom = 206, 566
    second_top, second_bottom = 486, 846
    draw.rounded_rectangle(
        (card_left, first_top, card_left + card_width, first_bottom),
        radius=46,
        fill=CARD_COLOR + (255,),
    )
    draw.rounded_rectangle(
        (card_left + 66, second_top, card_left + 66 + card_width, second_bottom),
        radius=46,
        fill=SCREEN_COLOR + (255,),
    )

    # Content lines inside the top card.
    for index, y in enumerate(range(first_top + 58, first_top + 200, 34)):
        width = 300 - index * 26
        draw.rounded_rectangle(
            (card_left + 54, y, card_left + 54 + width, y + 16),
            radius=8,
            fill=(70, 92, 150, 210),
        )
    draw.rounded_rectangle(
        (card_left + 54, first_top + 250, card_left + 300, first_top + 300),
        radius=18,
        fill=(58, 92, 214, 255),
    )
    draw.rounded_rectangle(
        (card_left + 54, first_bottom - 62, card_left + 380, first_bottom - 34),
        radius=12,
        fill=(190, 202, 232, 255),
    )

    # Stitched result card content.
    for index, y in enumerate(range(second_top + 52, second_bottom - 120, 30)):
        width = 330 - (index % 3) * 40
        draw.rounded_rectangle(
            (card_left + 120, y, card_left + 120 + width, y + 14),
            radius=7,
            fill=(90, 110, 168, 190),
        )
    draw.rounded_rectangle(
        (card_left + 120, second_bottom - 96, card_left + 330, second_bottom - 64),
        radius=14,
        fill=ACCENT + (255,),
    )

    # The overlap marker: three accent dashes where the two screenshots join.
    seam_y = 526
    for x in range(card_left + 132, card_left + 386, 64):
        draw.rounded_rectangle((x, seam_y - 7, x + 46, seam_y + 7), radius=7, fill=ACCENT + (255,))

    return icon


def main() -> None:
    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    master = make_master()

    sizes = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }
    for name, size in sizes.items():
        master.resize((size, size), Image.LANCZOS).save(ASSET_DIR / name)
        print(f"wrote {ASSET_DIR / name} ({size}px)")


if __name__ == "__main__":
    main()
