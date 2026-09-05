#!/usr/bin/env python3
"""Generate a static HTML catalog from a Card Scan archive.

Usage:
  python3 server/generate_catalog.py /path/to/cards -o site

Each deck folder may contain an optional deck.json (see DECK_JSON_SCHEMA below).
Images are copied as-is; CSS object-fit handles thumbnail framing (no Pillow).
"""

from __future__ import annotations

import argparse
import html
import json
import re
import shutil
import sys
from dataclasses import dataclass, field
from pathlib import Path

DECK_JSON_SCHEMA = """
deck.json (optional, inside each deck folder)
---------------------------------------------
{
  "title": "Human title",          # string; default: folder name
  "description": "Short blurb",    # string; default: ""
  "tags": ["vintage", "bicycle"],  # list of strings; default: []
  "cover": "box_01.jpg",           # filename under the deck (or extras/01.jpg);
                                   # default: first box, else back, else first card
  "notes": "Optional longer text"  # string; default: ""
}

Unknown keys are ignored. Invalid JSON or a missing file falls back to defaults.
"""

CARD_STEM_RE = re.compile(
    r"^(A|[2-9]|10|J|Q|K)[SHDC](_[0-9]+)?$",
    re.IGNORECASE,
)
BACK_STEM_RE = re.compile(r"^back(_[0-9]+)?$", re.IGNORECASE)
BOX_STEM_RE = re.compile(r"^box_\d+$", re.IGNORECASE)
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp", ".gif"}
SKIP_DIRS = {"_debug", ".git"}

RANK_ORDER = {
    "A": 1,
    "2": 2,
    "3": 3,
    "4": 4,
    "5": 5,
    "6": 6,
    "7": 7,
    "8": 8,
    "9": 9,
    "10": 10,
    "J": 11,
    "Q": 12,
    "K": 13,
}
SUIT_ORDER = {"S": 0, "H": 1, "D": 2, "C": 3}


@dataclass
class ImageItem:
    rel_path: str  # path relative to deck folder, POSIX style
    label: str
    category: str  # box | back | card | extra | other


@dataclass
class Deck:
    folder_name: str
    slug: str
    title: str
    description: str = ""
    tags: list[str] = field(default_factory=list)
    notes: str = ""
    cover: str | None = None  # rel path within deck
    images: list[ImageItem] = field(default_factory=list)
    source_dir: Path | None = None


def slugify(name: str) -> str:
    s = name.strip().lower()
    s = re.sub(r"[^a-z0-9]+", "-", s)
    s = s.strip("-")
    return s or "deck"


def unique_slug(name: str, used: set[str]) -> str:
    base = slugify(name)
    slug = base
    n = 2
    while slug in used:
        slug = f"{base}-{n}"
        n += 1
    used.add(slug)
    return slug


def load_deck_json(deck_dir: Path) -> dict:
    path = deck_dir / "deck.json"
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}
    return data


def classify_image(rel_posix: str) -> tuple[str, str]:
    """Return (category, label) for a path relative to the deck root."""
    parts = rel_posix.split("/")
    name = parts[-1]
    stem = Path(name).stem

    if len(parts) >= 2 and parts[0].lower() == "extras":
        return "extra", f"Extra {stem}"

    if BOX_STEM_RE.match(stem):
        return "box", stem.replace("_", " ").title()
    if BACK_STEM_RE.match(stem):
        return "back", "Back" if stem.lower() == "back" else stem.replace("_", " ").title()
    if CARD_STEM_RE.match(stem):
        m = re.match(r"^((?:A|[2-9]|10|J|Q|K)[SHDC])", stem, re.IGNORECASE)
        code = m.group(1).upper() if m else stem.upper()
        return "card", code
    return "other", stem


def card_sort_key(label: str) -> tuple:
    m = re.match(r"^((?:A|[2-9]|10|J|Q|K))([SHDC])", label, re.IGNORECASE)
    if not m:
        return (99, 99, label)
    rank, suit = m.group(1).upper(), m.group(2).upper()
    return (SUIT_ORDER.get(suit, 9), RANK_ORDER.get(rank, 99), label)


def discover_images(deck_dir: Path) -> list[ImageItem]:
    items: list[ImageItem] = []
    for path in sorted(deck_dir.rglob("*")):
        if not path.is_file():
            continue
        if path.name.lower() == "deck.json":
            continue
        if path.suffix.lower() not in IMAGE_SUFFIXES:
            continue
        try:
            rel = path.relative_to(deck_dir)
        except ValueError:
            continue
        # skip nested skip dirs
        if any(part in SKIP_DIRS or part.startswith(".") for part in rel.parts[:-1]):
            continue
        if any(part in SKIP_DIRS for part in rel.parts):
            continue
        rel_posix = rel.as_posix()
        category, label = classify_image(rel_posix)
        items.append(ImageItem(rel_path=rel_posix, label=label, category=category))

    def sort_key(item: ImageItem) -> tuple:
        cat_order = {"box": 0, "back": 1, "card": 2, "extra": 3, "other": 4}
        if item.category == "card":
            return (cat_order[item.category],) + card_sort_key(item.label)
        return (cat_order.get(item.category, 9), item.rel_path.lower())

    items.sort(key=sort_key)
    return items


def pick_cover(meta: dict, images: list[ImageItem]) -> str | None:
    cover = meta.get("cover")
    if isinstance(cover, str) and cover.strip():
        want = cover.strip().replace("\\", "/")
        for img in images:
            if img.rel_path == want or img.rel_path.lower() == want.lower():
                return img.rel_path
        # allow bare filename match
        for img in images:
            if Path(img.rel_path).name.lower() == Path(want).name.lower():
                return img.rel_path
    for cat in ("box", "back", "card", "extra", "other"):
        for img in images:
            if img.category == cat:
                return img.rel_path
    return None


def load_deck(deck_dir: Path, used_slugs: set[str]) -> Deck | None:
    if not deck_dir.is_dir():
        return None
    if deck_dir.name.startswith(".") or deck_dir.name in SKIP_DIRS:
        return None
    images = discover_images(deck_dir)
    if not images:
        return None
    meta = load_deck_json(deck_dir)
    title = meta.get("title")
    if not isinstance(title, str) or not title.strip():
        title = deck_dir.name
    else:
        title = title.strip()
    description = meta.get("description") if isinstance(meta.get("description"), str) else ""
    notes = meta.get("notes") if isinstance(meta.get("notes"), str) else ""
    tags_raw = meta.get("tags")
    tags: list[str] = []
    if isinstance(tags_raw, list):
        tags = [str(t).strip() for t in tags_raw if str(t).strip()]
    cover = pick_cover(meta, images)
    return Deck(
        folder_name=deck_dir.name,
        slug=unique_slug(deck_dir.name, used_slugs),
        title=title,
        description=description.strip(),
        tags=tags,
        notes=notes.strip(),
        cover=cover,
        images=images,
        source_dir=deck_dir,
    )


def discover_decks(archive_root: Path) -> list[Deck]:
    used: set[str] = set()
    decks: list[Deck] = []
    if not archive_root.is_dir():
        return decks
    for child in sorted(archive_root.iterdir(), key=lambda p: p.name.lower()):
        deck = load_deck(child, used)
        if deck:
            decks.append(deck)
    return decks


def esc(s: str) -> str:
    return html.escape(s, quote=True)


def render_css() -> str:
    return """:root {
  color-scheme: dark;
  --bg: #0f1115;
  --bg-elev: #181b22;
  --bg-card: #1c2029;
  --border: #2a3040;
  --text: #e8eaef;
  --muted: #9aa3b5;
  --accent: #7aa2ff;
  --accent-soft: rgba(122, 162, 255, 0.15);
  --shadow: 0 12px 40px rgba(0, 0, 0, 0.35);
  --radius: 14px;
  --font: "Segoe UI", system-ui, -apple-system, sans-serif;
}
* { box-sizing: border-box; }
html { scroll-behavior: smooth; }
body {
  margin: 0;
  font-family: var(--font);
  background: radial-gradient(1200px 600px at 10% -10%, #1a2744 0%, transparent 50%),
              radial-gradient(900px 500px at 100% 0%, #1e1530 0%, transparent 45%),
              var(--bg);
  color: var(--text);
  line-height: 1.5;
  min-height: 100vh;
}
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
.wrap { max-width: 1120px; margin: 0 auto; padding: 1.5rem 1.25rem 3rem; }
header.site {
  display: flex; flex-wrap: wrap; align-items: baseline; gap: 0.75rem 1.25rem;
  margin-bottom: 1.75rem; padding-bottom: 1rem; border-bottom: 1px solid var(--border);
}
header.site h1 { margin: 0; font-size: 1.6rem; letter-spacing: -0.02em; }
header.site .sub { color: var(--muted); font-size: 0.95rem; }
.crumb { color: var(--muted); font-size: 0.9rem; margin-bottom: 0.75rem; }
.crumb a { color: var(--muted); }
.crumb a:hover { color: var(--accent); }
.deck-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
  gap: 1.1rem;
}
.deck-card {
  background: var(--bg-card);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  overflow: hidden;
  box-shadow: var(--shadow);
  transition: transform 0.15s ease, border-color 0.15s ease;
}
.deck-card:hover { transform: translateY(-3px); border-color: #3d4a66; text-decoration: none; }
.deck-card .thumb {
  aspect-ratio: 5 / 7;
  background: #0a0c10;
  display: block;
  overflow: hidden;
}
.deck-card .thumb img,
.img-tile img {
  width: 100%; height: 100%; object-fit: cover; display: block;
}
.deck-card .meta { padding: 0.85rem 0.95rem 1rem; }
.deck-card h2 { margin: 0 0 0.35rem; font-size: 1.05rem; color: var(--text); }
.deck-card p { margin: 0; color: var(--muted); font-size: 0.85rem;
  display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.tags { display: flex; flex-wrap: wrap; gap: 0.35rem; margin-top: 0.55rem; }
.tag {
  font-size: 0.72rem; text-transform: uppercase; letter-spacing: 0.04em;
  background: var(--accent-soft); color: var(--accent);
  padding: 0.15rem 0.45rem; border-radius: 999px;
}
.deck-hero { margin-bottom: 1.5rem; }
.deck-hero h1 { margin: 0 0 0.4rem; font-size: 1.85rem; letter-spacing: -0.02em; }
.deck-hero .desc { color: var(--muted); max-width: 52rem; }
.deck-hero .notes {
  margin-top: 0.85rem; padding: 0.75rem 0.9rem;
  background: var(--bg-elev); border-left: 3px solid var(--accent);
  border-radius: 0 8px 8px 0; color: var(--muted); font-size: 0.92rem;
}
.section { margin: 1.75rem 0; }
.section h2 {
  margin: 0 0 0.85rem; font-size: 1.05rem; color: var(--muted);
  font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em;
}
.img-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(110px, 1fr));
  gap: 0.65rem;
}
.img-tile {
  background: var(--bg-card); border: 1px solid var(--border);
  border-radius: 10px; overflow: hidden; cursor: pointer;
  padding: 0; color: inherit; font: inherit; text-align: left;
}
.img-tile:hover { border-color: var(--accent); }
.img-tile .frame { aspect-ratio: 5 / 7; background: #0a0c10; }
.img-tile .caption {
  padding: 0.35rem 0.45rem; font-size: 0.75rem; color: var(--muted);
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}
.empty { color: var(--muted); padding: 2rem 0; }
footer.site {
  margin-top: 2.5rem; padding-top: 1rem; border-top: 1px solid var(--border);
  color: var(--muted); font-size: 0.85rem;
}
/* Lightbox */
.lightbox[hidden] { display: none !important; }
.lightbox {
  position: fixed; inset: 0; z-index: 1000;
  background: rgba(5, 7, 12, 0.92);
  display: flex; flex-direction: column; align-items: center; justify-content: center;
  padding: 1rem;
}
.lightbox img {
  max-width: min(92vw, 900px); max-height: min(78vh, 1200px);
  object-fit: contain; border-radius: 8px; box-shadow: var(--shadow);
}
.lightbox .bar {
  display: flex; align-items: center; gap: 0.75rem; margin-top: 0.9rem;
  color: var(--muted); font-size: 0.9rem;
}
.lightbox button {
  background: var(--bg-elev); color: var(--text); border: 1px solid var(--border);
  border-radius: 8px; padding: 0.45rem 0.85rem; cursor: pointer; font: inherit;
}
.lightbox button:hover { border-color: var(--accent); color: var(--accent); }
.lightbox .lb-close { position: absolute; top: 1rem; right: 1rem; }
@media (max-width: 520px) {
  .img-grid { grid-template-columns: repeat(auto-fill, minmax(90px, 1fr)); }
  header.site h1 { font-size: 1.35rem; }
}
"""


def render_js() -> str:
    return r"""(function () {
  const lb = document.getElementById("lightbox");
  if (!lb) return;
  const img = document.getElementById("lb-img");
  const label = document.getElementById("lb-label");
  const counter = document.getElementById("lb-counter");
  const items = Array.from(document.querySelectorAll("[data-lb-index]"));
  let index = 0;

  function show(i) {
    if (!items.length) return;
    index = (i + items.length) % items.length;
    const el = items[index];
    img.src = el.getAttribute("data-full") || el.querySelector("img").src;
    img.alt = el.getAttribute("data-label") || "";
    label.textContent = el.getAttribute("data-label") || "";
    counter.textContent = (index + 1) + " / " + items.length;
    lb.hidden = false;
    document.body.style.overflow = "hidden";
  }
  function hide() {
    lb.hidden = true;
    document.body.style.overflow = "";
    img.removeAttribute("src");
  }
  items.forEach(function (el) {
    el.addEventListener("click", function () {
      show(parseInt(el.getAttribute("data-lb-index"), 10));
    });
  });
  document.getElementById("lb-close").addEventListener("click", hide);
  document.getElementById("lb-prev").addEventListener("click", function () { show(index - 1); });
  document.getElementById("lb-next").addEventListener("click", function () { show(index + 1); });
  lb.addEventListener("click", function (e) { if (e.target === lb) hide(); });
  document.addEventListener("keydown", function (e) {
    if (lb.hidden) return;
    if (e.key === "Escape") hide();
    if (e.key === "ArrowLeft") show(index - 1);
    if (e.key === "ArrowRight") show(index + 1);
  });
})();
"""


def page_shell(title: str, body: str, root_prefix: str, extra_head: str = "") -> str:
    css_href = f"{root_prefix}assets/style.css"
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<link rel="stylesheet" href="{esc(css_href)}">
{extra_head}
</head>
<body>
{body}
</body>
</html>
"""


def render_index(decks: list[Deck], site_title: str) -> str:
    cards = []
    for d in decks:
        cover_src = ""
        if d.cover:
            cover_src = f"decks/{esc(d.slug)}/{esc(d.cover)}"
        tags_html = "".join(f'<span class="tag">{esc(t)}</span>' for t in d.tags)
        desc = d.description or f"{len(d.images)} images"
        thumb = (
            f'<div class="thumb"><img src="{cover_src}" alt="" loading="lazy"></div>'
            if cover_src
            else '<div class="thumb"></div>'
        )
        cards.append(
            f'<a class="deck-card" href="decks/{esc(d.slug)}/index.html">'
            f"{thumb}"
            f'<div class="meta"><h2>{esc(d.title)}</h2>'
            f"<p>{esc(desc)}</p>"
            f'<div class="tags">{tags_html}</div></div></a>'
        )
    grid = "\n".join(cards) if cards else '<p class="empty">No decks found in this archive.</p>'
    body = f"""<div class="wrap">
<header class="site">
  <h1>{esc(site_title)}</h1>
  <span class="sub">{len(decks)} deck{"s" if len(decks) != 1 else ""}</span>
</header>
<div class="deck-grid">
{grid}
</div>
<footer class="site">Generated by Card Scan catalog · static site</footer>
</div>
"""
    return page_shell(site_title, body, "")


def group_images(images: list[ImageItem]) -> list[tuple[str, list[ImageItem]]]:
    order = [("box", "Box"), ("back", "Back"), ("card", "Cards"), ("extra", "Extras"), ("other", "Other")]
    by_cat: dict[str, list[ImageItem]] = {k: [] for k, _ in order}
    for img in images:
        by_cat.setdefault(img.category, []).append(img)
    sections = []
    for key, title in order:
        if by_cat.get(key):
            sections.append((title, by_cat[key]))
    return sections


def render_deck_page(deck: Deck, site_title: str) -> str:
    # global lightbox index across all sections
    tiles = []
    lb_index = 0
    sections_html = []
    for section_title, items in group_images(deck.images):
        section_tiles = []
        for item in items:
            src = esc(item.rel_path)
            label = esc(item.label)
            section_tiles.append(
                f'<button type="button" class="img-tile" data-lb-index="{lb_index}" '
                f'data-full="{src}" data-label="{label}">'
                f'<div class="frame"><img src="{src}" alt="{label}" loading="lazy"></div>'
                f'<div class="caption">{label}</div></button>'
            )
            lb_index += 1
        sections_html.append(
            f'<section class="section"><h2>{esc(section_title)}</h2>'
            f'<div class="img-grid">\n' + "\n".join(section_tiles) + "\n</div></section>"
        )

    tags_html = "".join(f'<span class="tag">{esc(t)}</span>' for t in deck.tags)
    notes_html = f'<div class="notes">{esc(deck.notes)}</div>' if deck.notes else ""
    desc_html = f'<p class="desc">{esc(deck.description)}</p>' if deck.description else ""

    body = f"""<div class="wrap">
<p class="crumb"><a href="../../index.html">{esc(site_title)}</a> / {esc(deck.title)}</p>
<header class="deck-hero">
  <h1>{esc(deck.title)}</h1>
  {desc_html}
  <div class="tags">{tags_html}</div>
  {notes_html}
</header>
{"".join(sections_html)}
<footer class="site">{len(deck.images)} images · folder <code>{esc(deck.folder_name)}</code></footer>
</div>
<div id="lightbox" class="lightbox" hidden>
  <button type="button" class="lb-close" id="lb-close" aria-label="Close">Close</button>
  <img id="lb-img" alt="">
  <div class="bar">
    <button type="button" id="lb-prev" aria-label="Previous">Prev</button>
    <span id="lb-label"></span>
    <span id="lb-counter"></span>
    <button type="button" id="lb-next" aria-label="Next">Next</button>
  </div>
</div>
<script src="../../assets/catalog.js"></script>
"""
    return page_shell(f"{deck.title} · {site_title}", body, "../../")


def copy_deck_images(deck: Deck, dest_deck_dir: Path) -> None:
    assert deck.source_dir is not None
    dest_deck_dir.mkdir(parents=True, exist_ok=True)
    for item in deck.images:
        src = deck.source_dir / item.rel_path
        dst = dest_deck_dir / item.rel_path
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)


def generate(
    archive_root: Path,
    output_dir: Path,
    site_title: str = "Card Scan Catalog",
    clean: bool = True,
) -> list[Deck]:
    archive_root = archive_root.resolve()
    output_dir = output_dir.resolve()
    decks = discover_decks(archive_root)

    if clean and output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    assets = output_dir / "assets"
    assets.mkdir(parents=True, exist_ok=True)
    (assets / "style.css").write_text(render_css(), encoding="utf-8")
    (assets / "catalog.js").write_text(render_js(), encoding="utf-8")

    (output_dir / "index.html").write_text(render_index(decks, site_title), encoding="utf-8")

    for deck in decks:
        dest = output_dir / "decks" / deck.slug
        copy_deck_images(deck, dest)
        (dest / "index.html").write_text(render_deck_page(deck, site_title), encoding="utf-8")

    return decks


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Generate a static deck catalog site from a Card Scan archive.",
        epilog=DECK_JSON_SCHEMA,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "archive",
        type=Path,
        help="Archive root containing deck folders",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=Path("site"),
        help="Output directory for the static site (default: site)",
    )
    parser.add_argument(
        "--title",
        default="Card Scan Catalog",
        help="Site title shown on the home page",
    )
    parser.add_argument(
        "--no-clean",
        action="store_true",
        help="Do not delete the output directory before writing",
    )
    args = parser.parse_args(argv)

    if not args.archive.is_dir():
        print(f"error: archive root not found: {args.archive}", file=sys.stderr)
        return 1

    decks = generate(
        args.archive,
        args.output,
        site_title=args.title,
        clean=not args.no_clean,
    )
    print(f"Wrote {len(decks)} deck(s) to {args.output.resolve()}")
    for d in decks:
        print(f"  - {d.folder_name} -> decks/{d.slug}/ ({len(d.images)} images)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
