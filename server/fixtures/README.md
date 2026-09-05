# Catalog fixtures

Tiny placeholder decks for unit tests and a demo static-site build. Each JPEG is a
1×1 pixel stub (not real card photography).

| Folder | Purpose |
|---|---|
| `Sample Deck/` | Full metadata (`deck.json`), box / back / cards / extras |
| `Minimal Deck/` | No `deck.json` — title falls back to the folder name |

Build a demo site:

```bash
python3 server/generate_catalog.py server/fixtures -o site
```

Then open `site/index.html` via any static file server (or GitHub Pages).
