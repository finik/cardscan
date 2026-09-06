#!/usr/bin/env python3
"""Generate a demo card archive with placeholder art, for previewing the site.

    python3 site/make_demo.py site/sample

Draws simple but tidy 5:7 card faces (vector suit pips + Arial rank) so the
gallery can be built and eyeballed without a real scan on disk.
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

S = 2  # supersample: design in 500x700 units, render at 1000x1400 (matches real scans)
W, H = 500 * S, 700 * S
RANKS = ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]
SUITS = ["S", "H", "D", "C"]
RED = (196, 40, 48)
BLACK = (26, 30, 34)
FONT_PATH = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"


def font(size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT_PATH, int(size * S))


def suit_color(s: str) -> tuple[int, int, int]:
    return RED if s in ("H", "D") else BLACK


def draw_suit(d: ImageDraw.ImageDraw, cx: float, cy: float, r: float, s: str, color) -> None:
    if s == "D":
        d.polygon([(cx, cy - r), (cx + r * 0.72, cy), (cx, cy + r), (cx - r * 0.72, cy)], fill=color)
    elif s == "H":
        d.ellipse([cx - r, cy - r * 0.9, cx, cy + r * 0.1], fill=color)
        d.ellipse([cx, cy - r * 0.9, cx + r, cy + r * 0.1], fill=color)
        d.polygon([(cx - r * 0.98, cy - r * 0.25), (cx + r * 0.98, cy - r * 0.25), (cx, cy + r)], fill=color)
    elif s == "S":
        d.polygon([(cx, cy - r), (cx + r * 0.95, cy + r * 0.35), (cx - r * 0.95, cy + r * 0.35)], fill=color)
        d.ellipse([cx - r * 0.95, cy - r * 0.1, cx - r * 0.02, cy + r * 0.55], fill=color)
        d.ellipse([cx + r * 0.02, cy - r * 0.1, cx + r * 0.95, cy + r * 0.55], fill=color)
        d.polygon([(cx - r * 0.28, cy + r), (cx + r * 0.28, cy + r), (cx, cy + r * 0.2)], fill=color)
    else:  # Clubs
        rr = r * 0.52
        d.ellipse([cx - rr, cy - r * 0.85, cx + rr, cy - r * 0.85 + 2 * rr], fill=color)
        d.ellipse([cx - r * 0.9, cy - r * 0.15, cx - r * 0.9 + 2 * rr, cy - r * 0.15 + 2 * rr], fill=color)
        d.ellipse([cx + r * 0.9 - 2 * rr, cy - r * 0.15, cx + r * 0.9, cy - r * 0.15 + 2 * rr], fill=color)
        d.polygon([(cx - r * 0.24, cy + r), (cx + r * 0.24, cy + r), (cx, cy + r * 0.1)], fill=color)


def make_card(rank: str, suit: str, bg: tuple[int, int, int], border: tuple[int, int, int]) -> Image.Image:
    img = Image.new("RGB", (W, H), border)
    d = ImageDraw.Draw(img)
    pad = 14 * S
    d.rounded_rectangle([pad, pad, W - pad, H - pad], radius=34 * S, fill=bg)
    color = suit_color(suit)
    sym = {"S": "♠", "H": "♥", "D": "♦", "C": "♣"}[suit]

    # Corner indices.
    rf = font(66)
    d.text((40 * S, 34 * S), rank, font=rf, fill=color)
    draw_suit(d, 58 * S, 132 * S, 22 * S, suit, color)
    # Bottom-right, rotated.
    corner = Image.new("RGBA", (110 * S, 190 * S), (0, 0, 0, 0))
    cd = ImageDraw.Draw(corner)
    cd.text((6 * S, 0), rank, font=rf, fill=color + (255,))
    draw_suit(cd, 24 * S, 98 * S, 22 * S, suit, color + (255,))
    rot = corner.rotate(180)
    img.paste(rot, (W - 150 * S, H - 214 * S), rot)

    # Center.
    if rank in ("J", "Q", "K"):
        d.text((W / 2 - font(150).getlength(rank) / 2, H / 2 - 150 * S), rank, font=font(230), fill=color)
    elif rank == "A":
        draw_suit(d, W / 2, H / 2, 120 * S, suit, color)
    else:
        draw_suit(d, W / 2, H / 2 - 20 * S, 70 * S, suit, color)
        big = font(120)
        d.text((W / 2 - big.getlength(rank) / 2, H / 2 + 60 * S), rank, font=big, fill=color)
    return img


def make_plain(label: str, bg, border, accent) -> Image.Image:
    """Box / back / extra filler art."""
    img = Image.new("RGB", (W, H), border)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([14 * S, 14 * S, W - 14 * S, H - 14 * S], radius=34 * S, fill=bg)
    for i in range(-H, W, 42 * S):
        d.line([(i, 14 * S), (i + H, H - 14 * S)], fill=accent, width=6 * S)
    d.rounded_rectangle([54 * S, H / 2 - 70 * S, W - 54 * S, H / 2 + 70 * S], radius=18 * S, fill=bg)
    f = font(52)
    d.text((W / 2 - f.getlength(label) / 2, H / 2 - 34 * S), label, font=f, fill=accent)
    return img


DECKS = [
    dict(name="Vikings", added="2026-08-30", designer="Erik Halvorsen", publisher="Northlore Cards", year=2021,
         edition="Fenrir Edition", bg=(244, 240, 231), border=(120, 90, 40), accent=(150, 110, 50),
         tags=["custom courts", "kickstarter", "foil"], missing=[],
         description="Norse-mythology courts with hand-inked runework on ivory stock. Gilded box, matching back.",
         links={"Kickstarter": "https://example.com/vikings", "Store": "https://example.com/shop"},
         related=["Midnight Tarot", "Botanica"], extras=3, featured=None),
    dict(name="Neon Nights", added="2026-07-12", designer="Mika Tran", publisher="Vaporwave Union", year=2023,
         edition="Retrowave", bg=(20, 16, 34), border=(90, 30, 120), accent=(255, 70, 200),
         tags=["cyberpunk", "neon", "dark"], missing=[],
         description="Synthwave grid lines and chrome pips glowing against a midnight deck.",
         links={"Store": "https://example.com/neon"}, related=["Midnight Tarot"],
         extras=2, featured=None),
    dict(name="Botanica", added="2026-08-15", designer="Lena Frost", publisher="Wildpress", year=2022,
         edition="Herbarium", bg=(238, 244, 236), border=(60, 110, 70), accent=(70, 130, 80),
         tags=["botanical", "pastel", "nature"],
         missing=["3C", "7D", "9S", "JH", "10C", "6H", "4D", "KC"],
         description="Pressed-flower illustrations; a work in progress — a handful of cards still to shoot.",
         links={}, related=["Vikings"], extras=1, featured=None),
    dict(name="Bicycle Classic", added="2026-06-01", designer="USPCC", publisher="Bicycle", year=2019,
         edition="Rider Back", bg=(250, 248, 245), border=(150, 40, 45), accent=(170, 45, 50),
         tags=["classic", "standard"], missing=[],
         description="The everyday standard, scanned flat for reference.",
         links={}, extras=0, featured=None),
    dict(name="Midnight Tarot", added="2026-09-01", designer="Sol Reyes", publisher="Arcana Press", year=2024,
         edition="Prototype", bg=(24, 22, 40), border=(70, 60, 130), accent=(210, 180, 90),
         tags=["tarot", "gilded", "prototype"],
         missing=["2C", "5D", "8S", "JC", "QD", "KH", "3H", "6S", "9D", "4C", "7H", "10D"],
         description="Early prototype scans; courts done, spots trickling in.",
         links={"Preview": "https://example.com/tarot"},
         related=["Neon Nights", "Vikings"], extras=1, featured=None),
]


def build(root: Path) -> None:
    root.mkdir(parents=True, exist_ok=True)
    for spec in DECKS:
        d = root / spec["name"]
        d.mkdir(exist_ok=True)
        bg, border, accent = spec["bg"], spec["border"], spec["accent"]
        missing = set(spec["missing"])
        for suit in SUITS:
            for rank in RANKS:
                code = f"{rank}{suit}"
                if code in missing:
                    continue
                make_card(rank, suit, bg, border).save(d / f"{code}.jpg", "JPEG", quality=90)
        make_plain("TUCK", bg, border, accent).save(d / "box_01.jpg", "JPEG", quality=90)
        make_plain("TUCK BACK", bg, border, accent).save(d / "box_02.jpg", "JPEG", quality=90)
        make_plain("BACK", bg, border, accent).save(d / "back.jpg", "JPEG", quality=90)
        if spec["extras"]:
            ex = d / "extras"
            ex.mkdir(exist_ok=True)
            labels = {1: "JOKER 1", 2: "JOKER 2"}
            for i in range(1, spec["extras"] + 1):
                make_plain(labels.get(i, f"EXTRA {i - 2}"), bg, border, accent).save(ex / f"{i:02d}.jpg", "JPEG", quality=90)
        meta = {k: spec[k] for k in ("name", "designer", "publisher", "year", "edition",
                                     "description", "tags", "links")}
        if spec.get("added"):
            meta["added"] = spec["added"]
        if spec.get("related"):
            meta["related"] = spec["related"]
        if spec["featured"]:
            meta["featured"] = spec["featured"]
        (d / "deck.json").write_text(json.dumps(meta, indent=2), "utf-8")
        made = 52 - len(missing)
        print(f"  {spec['name']}: {made}/52 cards")
    print(f"demo archive -> {root}")


if __name__ == "__main__":
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("site/sample")
    build(out)
