#!/usr/bin/env python3
"""Static-site generator for the card archive.

Scans an archive root (the same layout the inbox server writes) and emits a
self-contained static site under an output directory. No server, no database:
every page is plain HTML with the deck list baked in for client-side search.

    python3 site/build.py /path/to/cards -o site/dist

Stdlib only. The output directory is safe to upload to S3 or GitHub Pages as-is.
"""

from __future__ import annotations

import argparse
import html
import json
import re
import shutil
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent

RANKS = ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]
SUITS = [
    ("S", "♠", "Spades", "black"),
    ("H", "♥", "Hearts", "red"),
    ("D", "♦", "Diamonds", "red"),
    ("C", "♣", "Clubs", "black"),
]
SUIT_SYMBOL = {code: sym for code, sym, _, _ in SUITS}
SUIT_COLOR = {code: color for code, _, _, color in SUITS}

CARD_RE = re.compile(r"^(A|10|[2-9]|J|Q|K)([SHDC])(?:_(\d+))?$", re.IGNORECASE)
BACK_RE = re.compile(r"^back(?:_\d+)?$", re.IGNORECASE)
BOX_RE = re.compile(r"^box_(\d+)$", re.IGNORECASE)
EXTRA_RE = re.compile(r"^(\d+)$", re.IGNORECASE)



@dataclass
class Slide:
    """One image in a deck's carousel."""
    src: str      # path relative to the deck page
    label: str


@dataclass
class Deck:
    slug: str
    name: str
    dir: Path
    meta: dict = field(default_factory=dict)
    # code ("AS") -> primary source Path
    cards: dict = field(default_factory=dict)
    # code -> list of extra-variant source Paths (5H_2.jpg ...)
    variants: dict = field(default_factory=dict)
    backs: list = field(default_factory=list)
    boxes: list = field(default_factory=list)
    extras: list = field(default_factory=list)

    @property
    def card_count(self) -> int:
        return len(self.cards)

    def cover(self) -> Path | None:
        featured = self.meta.get("featured")
        if featured:
            stem = featured[:-4] if featured.lower().endswith(".jpg") else featured
            code = stem.upper()
            if code in self.cards:
                return self.cards[code]
            direct = self.dir / (featured if featured.lower().endswith(".jpg") else featured + ".jpg")
            if direct.exists():
                return direct
        if self.boxes:
            return self.boxes[0]
        if self.backs:
            return self.backs[0]
        if "AS" in self.cards:
            return self.cards["AS"]
        for suit_code, _, _, _ in SUITS:
            for rank in RANKS:
                code = f"{rank}{suit_code}"
                if code in self.cards:
                    return self.cards[code]
        return None


def slugify(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return s or "deck"


def load_meta(deck_dir: Path) -> dict:
    f = deck_dir / "deck.json"
    if not f.is_file():
        return {}
    try:
        data = json.loads(f.read_text("utf-8"))
        return data if isinstance(data, dict) else {}
    except (ValueError, OSError):
        print(f"  ! bad deck.json in {deck_dir.name}, ignoring", file=sys.stderr)
        return {}


def scan_deck(deck_dir: Path, used_slugs: set[str]) -> Deck:
    meta = load_meta(deck_dir)
    name = str(meta.get("name") or deck_dir.name).strip() or deck_dir.name
    slug = slugify(name)
    base = slug
    n = 2
    while slug in used_slugs:
        slug = f"{base}-{n}"
        n += 1
    used_slugs.add(slug)

    deck = Deck(slug=slug, name=name, dir=deck_dir, meta=meta)

    for p in sorted(deck_dir.iterdir()):
        if not p.is_file() or p.suffix.lower() != ".jpg":
            continue
        stem = p.stem
        m = CARD_RE.match(stem)
        if m:
            code = (m.group(1) + m.group(2)).upper()
            if m.group(3) is None and code not in deck.cards:
                deck.cards[code] = p
            else:
                deck.variants.setdefault(code, []).append(p)
            continue
        if BACK_RE.match(stem):
            deck.backs.append(p)
        elif BOX_RE.match(stem):
            deck.boxes.append(p)

    extras_dir = deck_dir / "extras"
    if extras_dir.is_dir():
        for p in sorted(extras_dir.iterdir()):
            if p.is_file() and p.suffix.lower() == ".jpg" and EXTRA_RE.match(p.stem):
                deck.extras.append(p)

    return deck


# ---------------------------------------------------------------------------
# Image output
# ---------------------------------------------------------------------------

class DeckWriter:
    """Copies a deck's images into dist once and hands back relative URLs.

    The originals are ~1000x1400 JPEGs; the grid displays them small with
    lazy loading, so there are no separate thumbnails to generate or store.
    """

    def __init__(self, deck: Deck, out_dir: Path):
        self.deck = deck
        self.out_dir = out_dir
        self._rel: dict[Path, str] = {}

    def add(self, src: Path, sub: str = "") -> str:
        if src in self._rel:
            return self._rel[src]
        rel = f"{sub}{src.name}" if sub else src.name
        dest = self.out_dir / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest)
        self._rel[src] = rel
        return rel


# ---------------------------------------------------------------------------
# HTML rendering
# ---------------------------------------------------------------------------

def e(s) -> str:
    return html.escape("" if s is None else str(s))


def page(title: str, body: str, css_href: str, js_href: str, extra_head: str = "") -> str:
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{e(title)}</title>
<link rel="stylesheet" href="{css_href}">
{extra_head}
</head>
<body>
{body}
<script src="{js_href}" defer></script>
</body>
</html>
"""


def _fmt_added(dt: datetime, prec: str) -> str:
    if prec == "y":
        return f"{dt.year}"
    if prec == "m":
        return f"{dt:%b %Y}"
    return f"{dt:%b} {dt.day}, {dt.year}"


def deck_added(deck: Deck) -> tuple[float, str]:
    """When a deck was added: the deck.json `added` date if present, else the
    folder's creation time (birthtime on macOS, mtime elsewhere).

    Returns (sort_timestamp, human display).
    """
    raw = deck.meta.get("added")
    if raw:
        for fmt, prec in (("%Y-%m-%d", "d"), ("%Y/%m/%d", "d"), ("%Y-%m", "m"), ("%Y", "y")):
            try:
                dt = datetime.strptime(str(raw).strip(), fmt)
            except ValueError:
                continue
            return dt.timestamp(), _fmt_added(dt, prec)
    st = deck.dir.stat()
    ts = float(getattr(st, "st_birthtime", None) or st.st_mtime)
    return ts, _fmt_added(datetime.fromtimestamp(ts), "d")


def deck_summary(deck: Deck, cover_url: str | None) -> dict:
    added_ts, added_disp = deck_added(deck)
    return {
        "slug": deck.slug,
        "name": deck.name,
        "designer": deck.meta.get("designer", ""),
        "publisher": deck.meta.get("publisher", ""),
        "year": deck.meta.get("year", ""),
        "tags": deck.meta.get("tags", []) or [],
        "cover": cover_url or "",
        "added_ts": added_ts,
        "added": added_disp,
    }


def render_index(summaries: list[dict]) -> str:
    # Default order: newest added first (JS can re-sort).
    summaries = sorted(summaries, key=lambda s: s["added_ts"], reverse=True)
    cards_html = []
    ac_data = []
    for s in summaries:
        href = f"decks/{s['slug']}/index.html"
        cover_url = f"{href.rsplit('/', 1)[0]}/{s['cover']}" if s["cover"] else ""
        meta_bits = [b for b in (s["year"], s["designer"] or s["publisher"]) if b]
        sub_html = f'<p class="sub">{e(" · ".join(str(b) for b in meta_bits))}</p>' if meta_bits else ""
        cover = (
            f'<img class="cover" loading="lazy" src="{e(cover_url)}" alt="">'
            if cover_url
            else '<div class="cover cover--empty">no image</div>'
        )
        tags = "".join(f'<span class="tag">{e(t)}</span>' for t in s["tags"][:4])
        cards_html.append(f"""
        <a class="deck-card" href="{e(href)}"
           data-name="{e(s['name'].lower())}" data-added="{s['added_ts']:.0f}"
           data-tags="{e(' '.join(str(t).lower() for t in s['tags']))}">
          <div class="cover-wrap">{cover}</div>
          <div class="deck-card__body">
            <h2>{e(s['name'])}</h2>
            {sub_html}
            <p class="added">Added {e(s['added'])}</p>
            <div class="tags">{tags}</div>
          </div>
        </a>""")
        ac_data.append({
            "name": s["name"],
            "href": href,
            "cover": cover_url,
            "tags": [str(t) for t in s["tags"]],
            "sub": " · ".join(str(b) for b in meta_bits),
        })

    body = f"""
<header class="site-head">
  <div class="wrap">
    <h1>The Deck Vault</h1>
    <p class="tagline">{len(summaries)} deck{'s' if len(summaries) != 1 else ''} in the collection.</p>
    <div class="search">
      <input id="q" type="search" placeholder="Search decks by name or tag…"
             role="combobox" aria-expanded="false" aria-controls="ac"
             aria-autocomplete="list" aria-label="Search decks"
             autocomplete="off" autocapitalize="off" spellcheck="false">
      <ul id="ac" class="ac" role="listbox" hidden></ul>
    </div>
    <div class="active-filter" id="filter" hidden>
      Filtered by <span class="chip" id="filter-chip"></span>
      <button type="button" id="filter-clear" aria-label="Clear filter">clear ✕</button>
    </div>
  </div>
</header>
<main class="wrap">
  <div class="toolbar">
    <label class="sort-field">Sort
      <select id="sort" aria-label="Sort decks">
        <option value="added-desc">Newest added</option>
        <option value="added-asc">Oldest added</option>
        <option value="name-asc">Name A–Z</option>
        <option value="name-desc">Name Z–A</option>
      </select>
    </label>
  </div>
  <div class="deck-grid" id="grid">{''.join(cards_html)}</div>
  <p class="empty" id="empty" hidden>No decks tagged “<span id="empty-q"></span>”.</p>
</main>
<footer class="wrap foot">Static gallery · no server, no tracking.</footer>
<script>window.__DECKS__ = {json.dumps(ac_data)};</script>
"""
    return page("The Deck Vault", body, "assets/style.css", "assets/app.js")


def render_deck(deck: Deck, writer: DeckWriter, related: list[tuple[str, str, str]]) -> str:
    slides: list[Slide] = []
    slide_idx: dict[Path, int] = {}

    def slide_for(src: Path, label: str, sub: str = "") -> int:
        if src in slide_idx:
            return slide_idx[src]
        url = writer.add(src, sub)
        slide_idx[src] = len(slides)
        slides.append(Slide(url, label))
        return slide_idx[src]

    # Register present cards suit-major so the carousel reads in deck order.
    code_idx: dict[str, int] = {}
    for suit_code, sym, _name, _color in SUITS:
        for rank in RANKS:
            code = f"{rank}{suit_code}"
            src = deck.cards.get(code)
            if src:
                code_idx[code] = slide_for(src, f"{rank}{sym}")

    # Grid: suits as columns (header row), ranks as rows. No rank legend.
    cells = []
    for suit_code, sym, _name, color in SUITS:
        cells.append(f'<span class="suit-h suit--{color}">{sym}</span>')
    for rank in RANKS:
        for suit_code, sym, _name, color in SUITS:
            code = f"{rank}{suit_code}"
            if code in code_idx:
                tsrc = writer.add(deck.cards[code])
                cells.append(
                    f'<button class="cell" data-idx="{code_idx[code]}" title="{e(code)}">'
                    f'<img loading="lazy" src="{e(tsrc)}" alt="{e(code)}"></button>'
                )
            else:
                cells.append(
                    f'<span class="cell cell--empty suit--{color}" title="{e(code)} missing">'
                    f'<i>{e(rank)}{sym}</i></span>'
                )
    grid_html = f'<div class="card-grid">{"".join(cells)}</div>'

    # Packaging: tuck front / back, card back, jokers, then any other extras.
    pack_items = []
    for i, src in enumerate(deck.boxes):
        label = "Tuck" if i == 0 else ("Tuck back" if i == 1 else f"Tuck {i + 1}")
        pack_items.append((slide_for(src, label), writer.add(src), label))
    for i, src in enumerate(deck.backs):
        label = "Back" if i == 0 else f"Back {i + 1}"
        pack_items.append((slide_for(src, label), writer.add(src), label))
    for i, src in enumerate(deck.extras):
        label = "Joker 1" if i == 0 else ("Joker 2" if i == 1 else f"Extra {i - 1}")
        pack_items.append((slide_for(src, label), writer.add(src), label))

    pack_html = ""
    if pack_items:
        tiles = "".join(
            f'<button class="pack-tile" data-idx="{idx}"><img loading="lazy" src="{e(tsrc)}" alt="{e(label)}"><span>{e(label)}</span></button>'
            for idx, tsrc, label in pack_items
        )
        pack_html = f'<section class="pack"><h2>Packaging &amp; extras</h2><div class="pack-row">{tiles}</div></section>'

    # Metadata panel.
    m = deck.meta
    facts = []
    for key in ("designer", "publisher", "year", "edition"):
        if m.get(key):
            facts.append(f'<div class="fact"><dt>{key.title()}</dt><dd>{e(m[key])}</dd></div>')
    facts.append(f'<div class="fact"><dt>Added</dt><dd>{e(deck_added(deck)[1])}</dd></div>')
    facts_html = f'<dl class="facts">{"".join(facts)}</dl>'

    desc_html = f'<p class="desc">{e(m["description"])}</p>' if m.get("description") else ""
    tags_html = ""
    if m.get("tags"):
        tags_html = '<div class="tags">' + "".join(f'<span class="tag">{e(t)}</span>' for t in m["tags"]) + "</div>"
    links_html = ""
    links = m.get("links") or {}
    if isinstance(links, dict) and links:
        links_html = '<div class="links">' + "".join(
            f'<a href="{e(url)}" target="_blank" rel="noopener">{e(label)} ↗</a>'
            for label, url in links.items()
        ) + "</div>"

    related_html = ""
    if related:
        def rel_tile(slug: str, name: str, cover: str) -> str:
            img = f'<img loading="lazy" src="{e(cover)}" alt="">' if cover else ""
            return (
                f'<a class="rel-card" href="../{e(slug)}/index.html">'
                f'<span class="rel-cover">{img}</span>'
                f'<span class="rel-name">{e(name)}</span></a>'
            )
        rel_tiles = "".join(rel_tile(*r) for r in related)
        related_html = f'<section class="related"><h2>Related decks</h2><div class="rel-row">{rel_tiles}</div></section>'

    cover_src = deck.cover()
    hero = ""
    if cover_src:
        hero_idx = slide_idx.get(cover_src)
        hero_url = writer.add(cover_src) if cover_src in slide_idx else writer.add(cover_src)
        attr = f' data-idx="{hero_idx}"' if hero_idx is not None else ""
        hero = f'<button class="hero-img"{attr}><img src="{e(hero_url)}" alt=""></button>'

    # Ambient background: a zoomed-in (1000%) patch of the card back.
    bg_layer = ""
    if deck.backs:
        bg_layer = f'<div class="deck-bg" style="background-image:url(\'{e(writer.add(deck.backs[0]))}\')"></div>'

    body = f"""
{bg_layer}
<header class="deck-head">
  <div class="wrap deck-head__inner">
    <a class="back" href="../../index.html">← All decks</a>
    <div class="deck-head__grid">
      {hero}
      <div class="deck-meta">
        <h1>{e(deck.name)}</h1>
        {tags_html}
        {facts_html}
        {desc_html}
        {links_html}
      </div>
    </div>
  </div>
</header>
<main class="wrap">
  <section class="grid-section">
    <p class="grid-hint">Tap a card to flip through the deck.</p>
    {grid_html}
  </section>
  {pack_html}
  {related_html}
</main>
<div class="lightbox" id="lightbox" hidden>
  <button class="lb-close" aria-label="Close">✕</button>
  <div class="cf-stage"><div class="cf-track" id="cf-track"></div></div>
  <p class="cf-cap" id="cf-cap">
    <span class="cf-label"></span>
    <span class="cf-hint">click a side card · swipe · scroll · ← →</span>
  </p>
</div>
<script>window.__SLIDES__ = {json.dumps([{"src": s.src, "label": s.label} for s in slides])};</script>
"""
    return page(deck.name, body, "../../assets/style.css", "../../assets/app.js")


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def build(root: Path, out: Path) -> int:
    if not root.is_dir():
        raise SystemExit(f"archive root not found: {root}")

    deck_dirs = [
        p for p in sorted(root.iterdir())
        if p.is_dir() and not p.name.startswith((".", "_"))
    ]
    used: set[str] = set()
    decks = [scan_deck(d, used) for d in deck_dirs]
    decks = [d for d in decks if d.card_count or d.backs or d.boxes or d.extras]
    if not decks:
        print("no decks with images found", file=sys.stderr)

    if out.exists():
        shutil.rmtree(out)
    (out / "assets").mkdir(parents=True, exist_ok=True)
    for asset in ("style.css", "app.js"):
        shutil.copy2(HERE / "assets" / asset, out / "assets" / asset)

    # Index decks by slug and by normalized name so `related` can resolve either.
    deck_index: dict[str, tuple[str, str, str | None]] = {}
    for d in decks:
        cov = d.cover()
        entry = (d.slug, d.name, cov.name if cov else None)
        deck_index[d.slug] = entry
        deck_index.setdefault(slugify(d.name), entry)

    def resolve_related(deck: Deck) -> list[tuple[str, str, str]]:
        out_rel: list[tuple[str, str, str]] = []
        seen: set[str] = set()
        for ref in deck.meta.get("related") or []:
            hit = deck_index.get(str(ref)) or deck_index.get(slugify(str(ref)))
            if not hit or hit[0] == deck.slug or hit[0] in seen:
                continue
            slug, name, cover = hit
            seen.add(slug)
            cover_rel = f"../{slug}/{cover}" if cover else ""
            out_rel.append((slug, name, cover_rel))
        return out_rel

    summaries = []
    for deck in decks:
        deck_out = out / "decks" / deck.slug
        deck_out.mkdir(parents=True, exist_ok=True)
        writer = DeckWriter(deck, deck_out)
        page_html = render_deck(deck, writer, resolve_related(deck))
        (deck_out / "index.html").write_text(page_html, "utf-8")
        cover_src = deck.cover()
        cover_url = writer.add(cover_src) if cover_src else None
        summaries.append(deck_summary(deck, cover_url))
        print(f"  {deck.slug}: {deck.card_count}/52 cards"
              f"{', box' if deck.boxes else ''}"
              f"{', back' if deck.backs else ''}"
              f"{f', {len(deck.extras)} extras' if deck.extras else ''}")

    (out / "index.html").write_text(render_index(summaries), "utf-8")
    print(f"built {len(decks)} decks -> {out}")
    return 0


def parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Static gallery generator for the card archive")
    p.add_argument("root", type=Path, help="archive root (deck folders)")
    p.add_argument("-o", "--out", type=Path, default=HERE / "dist", help="output directory")
    return p.parse_args(argv)


def main(argv=None) -> None:
    args = parse_args(argv)
    raise SystemExit(build(args.root.expanduser(), args.out.expanduser()))


if __name__ == "__main__":
    main()
