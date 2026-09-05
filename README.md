# Card Scan

Photograph designer playing-card decks on a phone and save them to a folder on a Mac over the LAN.

The phone app (Flutter) takes a still, finds the card inside an on-screen guide, perspective-warps it to a rectangle, and POSTs a JPEG to a small Python HTTP inbox. You tap a **rank** to shoot (suit is selected separately). There is no auto-shutter and no rank/suit recognition.

## Archive layout

Root is the path you pass to the server. Each deck is a folder:

```
<root>/<Deck>/
  box_01.jpg
  back.jpg
  5H.jpg
  AS.jpg
  extras/
    01.jpg
```

Ranks: `A 2 3 4 5 6 7 8 9 10 J Q K`  
Suits: `S H D C`  
Jokers and odd cards go in `extras/`.

Warped faces are JPEG, about **1000×1400**, with a thin margin around the card.

### Examples

White card on a darker surface:

![White card after warp](docs/examples/white-card.jpg)

Dark card on a light surface:

![Dark card after warp](docs/examples/dark-card.jpg)

## 1. Inbox (macOS)

Python 3.10+, standard library only.

```bash
python3 server/card_inbox.py /path/to/cards
```

The process prints LAN URLs, for example:

```
http://127.0.0.1:8080
http://192.168.1.12:8080
```

Use the LAN URL in the phone app. `--port` defaults to `8080`. The root folder is created if it does not exist.

Keep the Mac awake while scanning:

```bash
caffeinate -dims python3 server/card_inbox.py /path/to/cards
```

On first launch, macOS may ask to **allow incoming connections** — allow it, or the phone cannot reach the port.

### Endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | `{ "ok": true, "root": "..." }` |
| `GET` | `/deck/<deck>` | Existing `cards` / `back` / `box` / `extras` names |
| `POST` | `/upload` | Multipart: `deck`, `category` (`card` \| `box` \| `back` \| `extra` \| `debug`), `file`; optional `filename`, `replace=true` |

Existing face cards and `back.jpg` are not overwritten unless `replace=true`. The server returns HTTP **409** with a `suggested` keep-both name (`5H_2.jpg`, `back_2.jpg`).

`debug` writes the original still and guide metadata under `<deck>/_debug/` (for crop diagnostics). It is not part of the public archive listing.

### curl

```bash
python3 server/card_inbox.py ./cards-archive

curl -s http://127.0.0.1:8080/health

curl -s -F deck=Vikings -F category=card -F filename=5H.jpg -F file=@./sample.jpg \
  http://127.0.0.1:8080/upload

curl -s http://127.0.0.1:8080/deck/Vikings
```

After a successful card upload, `./cards-archive/Vikings/5H.jpg` exists.

```bash
python3 -m unittest discover -s server -v
```

## 2. Phone app (Flutter)

Primary target is Android; the same project can be built for iOS later.

```bash
cd app
flutter pub get
flutter run
```

Release APK:

```bash
cd app
flutter build apk --release
```

The APK is written to `app/build/app/outputs/flutter-apk/app-release.apk`. Sideload it and allow unknown sources.

### Setup

1. Enter `http://<mac-lan-ip>:8080`
2. Tap **Test connection**
3. Enter a deck name
4. Continue

URL and deck name are remembered.

### Capture

Four modes: **box**, **back**, **cards**, **extras**.

**Cards:** suit toggles (`S H D C`) and ranks `2 3 4 5` / `6 7 8 9` / `10` / `J Q K A` sit on the camera as an overlay inside the white guide. Tapping a rank takes the picture. Completed slots (from `GET /deck`) show a check. The round shutter under the guide is reserved for future auto-detect and is disabled.

Line the card up inside the white rectangle (it does not have to be perfectly square). The app finds the card in that guide, warps it to 1000×1400, and uploads. White cards on a darker surface and dark cards on a light surface are both supported.

If the Mac is unreachable, shots queue locally and retry.

Permissions: camera and internet (cleartext HTTP on the LAN). No broad storage permission.

## Filename rules

| Mode | Path | Policy |
|---|---|---|
| Card | `<deck>/<RANK><SUIT>.jpg` | Uppercase. 409 if it exists unless `replace=true` |
| Back | `<deck>/back.jpg` | Same 409 / keep-both as `back_2.jpg` |
| Box | `<deck>/box_01.jpg`, `box_02.jpg`, … | Always increment |
| Extra | `<deck>/extras/01.jpg`, … | Always increment |

Deck names are sanitized on the server (letters, numbers, space, `-`, `_`; max 80). Path traversal is rejected.


## 3. Static deck catalog

Browse the archive as a self-contained static website (home grid + per-deck pages + lightbox). No database and no running inbox — only deck folders and optional `deck.json` metadata.

### Generate

```bash
python3 server/generate_catalog.py /path/to/cards -o site
```

Open `site/index.html` through any static host. Demo build from the in-repo fixtures (tiny placeholder JPEGs):

```bash
python3 server/generate_catalog.py server/fixtures -o site
python3 -m http.server -d site 8000
```

### `deck.json` (optional, per deck folder)

```json
{
  "title": "Vikings",
  "description": "Nordic-inspired court designs.",
  "tags": ["custom", "linen"],
  "cover": "box_01.jpg",
  "notes": "Missing 8C; re-shoot later."
}
```

| Field | Type | Default |
|---|---|---|
| `title` | string | folder name |
| `description` | string | `""` |
| `tags` | string[] | `[]` |
| `cover` | filename under the deck | first box, else back, else first card |
| `notes` | string | `""` |

Invalid or missing `deck.json` is ignored; the folder name is used as the title. Schema is also printed by `python3 server/generate_catalog.py -h`.

### GitHub Pages

**Option A — Actions (recommended for the public demo):** this repo includes [`.github/workflows/catalog-pages.yml`](.github/workflows/catalog-pages.yml). It builds from `server/fixtures/` on pushes to `main` and deploys to GitHub Pages. Enable under **Settings → Pages → Source: GitHub Actions**. Your private photo archive does not need to be in git.

**Option B — manual / private archive:** generate locally into `docs/` (or `site/`), commit if you want the branch to serve Pages from `/docs`, or rsync the output folder elsewhere:

```bash
python3 server/generate_catalog.py /path/to/cards -o docs
```

Then set Pages to deploy from the `docs/` folder on `main`, or host `site/` on any static CDN.

```bash
python3 -m unittest discover -s server -v
```

## License

Private / unspecified. Add a license file before making the repository public if you need one.
