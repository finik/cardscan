# The Deck Vault — static gallery

A static site generator for the scanned-card archive. No server, no database:
it scans the deck folders the inbox server writes, reads optional per-deck
`deck.json` metadata, and emits plain HTML you can drop on S3 or GitHub Pages.

```bash
# build from an archive root into site/dist
python3 site/build.py /path/to/cards -o site/dist
```

`build.py` is stdlib-only, no dependencies. The card images (~1000×1400
JPEGs) are copied as-is and shown directly — the grid displays them small with
lazy loading, so there are no separate thumbnails to generate or store.

## How it loads / scales

Folders are scanned and `deck.json` files read **once, at build time**;
everything is baked into static HTML. The browser never scans folders, hits a
server, or fetches JSON at runtime — it just loads `index.html`. Images are
`loading="lazy"`, so a grid doesn't download every card up front, and
the typeahead data (name / tags per deck) is a few hundred bytes each. No
pagination is needed until you reach the thousands of decks; at that point the
answer is a virtualized grid, not paging. Rebuild whenever the archive changes.

## What it produces

```
dist/
  index.html              deck list + client-side search (data baked inline)
  assets/style.css
  assets/app.js
  decks/<slug>/index.html  grid (suits as columns) · metadata · carousel
  decks/<slug>/*.jpg        copied card / box / back / extras images
```

- **Index:** responsive deck grid with a **typeahead** search — a dropdown of
  matching deck names (jump straight to the deck) and tags (filter the grid).
  Keyboard-navigable, works from `file://`. Deep links: `?tag=foil`, `?q=vik`.
- **Deck page:** box-front hero + metadata panel, a grid with **suits as
  columns** (♠♥♦♣) and ranks A–K down the rows (missing cards shown as dim
  slots), a packaging strip (box / card back / extras), and any related decks.
  Tap a card to open a macOS-style **Cover Flow** carousel through the whole
  deck: click a side card to bring it front, swipe (distance = how far it
  jumps), scroll wheel / trackpad, or ← →; Esc or a backdrop click closes.

## Deck metadata

Drop a `deck.json` in any deck folder. Every field is optional; `name`
defaults to the folder name.

```json
{
  "name": "Vikings",
  "designer": "Erik Halvorsen",
  "publisher": "Northlore Cards",
  "year": 2021,
  "edition": "Fenrir Edition",
  "description": "Norse-mythology courts on ivory stock.",
  "tags": ["custom courts", "kickstarter", "foil"],
  "links": { "Kickstarter": "https://…", "Store": "https://…" },
  "related": ["Midnight Tarot", "Botanica"],
  "added": "2026-08-30"
}
```

- `added` is the date the deck joined the collection (`YYYY-MM-DD`, `YYYY-MM`,
  or `YYYY`). If omitted it falls back to the folder's creation time. The index
  sorts by it (newest first) by default; the Sort control also offers oldest
  and name A–Z / Z–A, and remembers the choice.
- `related` lists other decks (by name or slug) to link at the bottom of the
  page; unknown names are skipped.
- The cover / hero is the **box front** by default, falling back to the card
  back, then the Ace of Spades, then any card. Set `"featured": "AS"` (a card
  code or filename) to override it.

## Deploy

The `dist/` directory is fully self-contained and relative-linked.

```bash
# GitHub Pages (docs branch, or a gh-pages worktree)
python3 site/build.py /path/to/cards -o docs

# S3
aws s3 sync site/dist s3://your-bucket --delete
```

## Preview locally

```bash
python3 -m http.server -d site/dist 9000   # then open http://localhost:9000
```

## Demo data

`make_demo.py` writes a throwaway archive with placeholder card art (needs
Pillow) so you can see the site without a real scan:

```bash
python3 site/make_demo.py site/sample
python3 site/build.py site/sample -o site/dist
```
