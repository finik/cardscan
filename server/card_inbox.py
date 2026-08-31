#!/usr/bin/env python3
"""Local LAN HTTP inbox for designer playing-card photos."""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer
from pathlib import Path
from urllib.parse import unquote

MAX_UPLOAD_BYTES = 15 * 1024 * 1024
CARD_RE = re.compile(
    r"^(A|[2-9]|10|J|Q|K)[SHDC](_[0-9]+)?$",
    re.IGNORECASE,
)
BACK_RE = re.compile(r"^back(_[0-9]+)?$", re.IGNORECASE)
BOX_RE = re.compile(r"^box_(\d+)\.jpg$", re.IGNORECASE)
EXTRA_RE = re.compile(r"^(\d+)\.jpg$", re.IGNORECASE)
CATEGORIES = frozenset({"card", "box", "back", "extra", "debug"})
DEBUG_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")


def sanitize_deck(raw: str) -> str | None:
    if raw is None:
        return None
    s = raw.strip()
    if not s:
        return None
    out = []
    for ch in s:
        if ch.isalnum() or ch in " -_":
            out.append(ch)
        else:
            out.append("_")
    s = "".join(out)
    s = re.sub(r"_+", "_", s)
    s = re.sub(r" +", " ", s).strip(" ._")
    if not s or s in {".", ".."}:
        return None
    if len(s) > 80:
        s = s[:80].rstrip(" ._")
    if not s or s in {".", ".."}:
        return None
    return s


def normalize_card_stem(filename: str) -> str | None:
    if not filename or "/" in filename or "\\" in filename:
        return None
    stem = filename.strip()
    if stem.lower().endswith(".jpg"):
        stem = stem[:-4]
    if not CARD_RE.match(stem):
        return None
    stem = stem.upper()
    # keep suffix digits as-is after uppercasing the code; CARD_RE digits stay
    m = re.match(r"^((?:A|[2-9]|10|J|Q|K)[SHDC])(_[0-9]+)?$", stem, re.IGNORECASE)
    if not m:
        return None
    code = m.group(1).upper()
    suffix = m.group(2) or ""
    return f"{code}{suffix}.jpg"


def normalize_back_stem(filename: str | None) -> str | None:
    if not filename:
        return "back.jpg"
    if "/" in filename or "\\" in filename:
        return None
    stem = filename.strip()
    if stem.lower().endswith(".jpg"):
        stem = stem[:-4]
    if not BACK_RE.match(stem):
        return None
    m = re.match(r"^back(_[0-9]+)?$", stem, re.IGNORECASE)
    suffix = m.group(1) or ""
    return f"back{suffix}.jpg"


def assert_under_root(root: Path, path: Path) -> Path:
    root_r = root.resolve()
    path_r = path.resolve()
    try:
        path_r.relative_to(root_r)
    except ValueError as exc:
        raise ValueError("path escapes archive root") from exc
    return path_r


def next_index_name(existing: list[str], pattern: re.Pattern[str], fmt: str) -> str:
    n = 0
    for name in existing:
        m = pattern.match(name)
        if m:
            n = max(n, int(m.group(1)))
    return fmt.format(n + 1)


def next_box_name(deck_dir: Path) -> str:
    names = [p.name for p in deck_dir.glob("box_*.jpg")]
    return next_index_name(names, BOX_RE, "box_{:02d}.jpg")


def next_extra_name(extras_dir: Path) -> str:
    names = [p.name for p in extras_dir.glob("*.jpg")]
    return next_index_name(names, EXTRA_RE, "{:02d}.jpg")


def next_card_keep_both(stem_jpg: str, deck_dir: Path) -> str:
    base = stem_jpg[:-4]
    m = re.match(r"^((?:A|[2-9]|10|J|Q|K)[SHDC])(?:_([0-9]+))?$", base)
    code = m.group(1) if m else base
    n = 1
    while True:
        n += 1
        candidate = f"{code}_{n}.jpg"
        if not (deck_dir / candidate).exists():
            return candidate


def next_back_keep_both(deck_dir: Path) -> str:
    n = 1
    while True:
        n += 1
        candidate = f"back_{n}.jpg"
        if not (deck_dir / candidate).exists():
            return candidate


def local_ips() -> list[str]:
    ips = ["127.0.0.1"]
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(0.3)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        if ip not in ips:
            ips.append(ip)
    except OSError:
        pass
    return ips


def parse_multipart(body: bytes, content_type: str) -> dict[str, tuple[str | None, bytes]]:
    """Return {name: (filename or None, value bytes)}."""
    m = re.search(r"boundary=([^;]+)", content_type, re.IGNORECASE)
    if not m:
        raise ValueError("multipart boundary missing")
    boundary = m.group(1).strip().strip('"')
    sep = b"--" + boundary.encode("ascii", "strict")
    if sep not in body:
        raise ValueError("multipart body missing boundary")
    parts = body.split(sep)
    fields: dict[str, tuple[str | None, bytes]] = {}
    for part in parts:
        if not part or part in (b"--", b"--\r\n", b"--\n"):
            continue
        if part.startswith(b"--"):
            continue
        if part.startswith(b"\r\n"):
            part = part[2:]
        elif part.startswith(b"\n"):
            part = part[1:]
        header_blob, _, data = part.partition(b"\r\n\r\n")
        if not _:
            header_blob, _, data = part.partition(b"\n\n")
        if data.endswith(b"\r\n"):
            data = data[:-2]
        elif data.endswith(b"\n"):
            data = data[:-1]
        headers = header_blob.decode("utf-8", "replace")
        disp = ""
        for line in headers.splitlines():
            if line.lower().startswith("content-disposition:"):
                disp = line.split(":", 1)[1].strip()
        name_m = re.search(r'name="([^"]+)"', disp)
        if not name_m:
            continue
        name = name_m.group(1)
        fn_m = re.search(r'filename="([^"]*)"', disp)
        filename = fn_m.group(1) if fn_m else None
        fields[name] = (filename, data)
    return fields


class InboxServer(ThreadingHTTPServer):
    # HTTPServer.server_bind() calls getfqdn(), which can hang for minutes on macOS.
    def server_bind(self) -> None:
        TCPServer.server_bind(self)
        host, port = self.socket.getsockname()[:2]
        self.server_name = host or "localhost"
        self.server_port = port


class InboxHandler(BaseHTTPRequestHandler):
    root: Path
    server_version = "CardInbox/1.0"
    protocol_version = "HTTP/1.0"

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send_json(self, code: int, payload: dict) -> None:
        raw = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(raw)
        self.wfile.flush()
        self.close_connection = True

    def _read_body(self, limit: int) -> bytes:
        length = self.headers.get("Content-Length")
        if length is None:
            raise ValueError("Content-Length required")
        try:
            n = int(length)
        except ValueError as exc:
            raise ValueError("invalid Content-Length") from exc
        if n < 0 or n > limit:
            raise ValueError("upload too large")
        return self.rfile.read(n)

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        if path == "/":
            msg = f"Card inbox running, root={self.root}".encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(msg)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(msg)
            return
        if path == "/health":
            self._send_json(200, {"ok": True, "root": str(self.root)})
            return
        if path.startswith("/deck/"):
            raw_deck = unquote(path[len("/deck/") :])
            deck = sanitize_deck(raw_deck)
            if not deck:
                self._send_json(400, {"ok": False, "error": "invalid deck name"})
                return
            self._send_json(200, self._list_deck(deck))
            return
        self._send_json(404, {"ok": False, "error": "not found"})

    def _list_deck(self, deck: str) -> dict:
        deck_dir = self.root / deck
        cards, back, box = [], [], []
        extras = []
        if deck_dir.is_dir():
            for p in sorted(deck_dir.iterdir()):
                if not p.is_file() or not p.name.lower().endswith(".jpg"):
                    continue
                stem = p.name[:-4]
                if CARD_RE.match(stem):
                    cards.append(p.name)
                elif BACK_RE.match(stem):
                    back.append(p.name)
                elif BOX_RE.match(p.name):
                    box.append(p.name)
            extras_dir = deck_dir / "extras"
            if extras_dir.is_dir():
                for p in sorted(extras_dir.iterdir()):
                    if p.is_file() and EXTRA_RE.match(p.name):
                        extras.append(p.name)
        return {
            "ok": True,
            "deck": deck,
            "cards": cards,
            "back": back,
            "box": box,
            "extras": extras,
        }

    def do_POST(self) -> None:
        path = self.path.split("?", 1)[0]
        if path != "/upload":
            self._send_json(404, {"ok": False, "error": "not found"})
            return
        try:
            body = self._read_body(MAX_UPLOAD_BYTES)
        except ValueError as exc:
            self._send_json(400, {"ok": False, "error": str(exc)})
            return
        ctype = self.headers.get("Content-Type", "")
        if "multipart/form-data" not in ctype.lower():
            self._send_json(400, {"ok": False, "error": "expected multipart/form-data"})
            return
        try:
            fields = parse_multipart(body, ctype)
        except ValueError as exc:
            self._send_json(400, {"ok": False, "error": str(exc)})
            return
        try:
            self._handle_upload(fields)
        except ValueError as exc:
            self._send_json(400, {"ok": False, "error": str(exc)})
        except FileExistsError as exc:
            extra = exc.args[0] if exc.args else {}
            payload = {"ok": False, "error": "exists"}
            if isinstance(extra, dict):
                payload.update(extra)
            else:
                payload["error"] = str(exc)
            self._send_json(409, payload)
        except OSError as exc:
            self._send_json(500, {"ok": False, "error": f"write failed: {exc}"})

    def _field_text(self, fields: dict, name: str, required: bool = False) -> str | None:
        if name not in fields:
            if required:
                raise ValueError(f"missing field {name}")
            return None
        return fields[name][1].decode("utf-8", "replace")

    def _handle_upload(self, fields: dict) -> None:
        deck_raw = self._field_text(fields, "deck", required=True)
        category = (self._field_text(fields, "category", required=True) or "").strip().lower()
        filename_raw = self._field_text(fields, "filename")
        replace_raw = (self._field_text(fields, "replace") or "").strip().lower()
        replace = replace_raw in {"1", "true", "yes", "on"}
        if "file" not in fields or not fields["file"][1]:
            raise ValueError("missing file")
        data = fields["file"][1]
        if len(data) > MAX_UPLOAD_BYTES:
            raise ValueError("upload too large")

        deck = sanitize_deck(deck_raw or "")
        if not deck:
            raise ValueError("invalid deck name")
        if category not in CATEGORIES:
            raise ValueError("invalid category")

        deck_dir = self.root / deck
        if category == "card":
            if not filename_raw:
                raise ValueError("filename required for card")
            name = normalize_card_stem(filename_raw)
            if not name:
                raise ValueError("invalid card filename")
            dest = deck_dir / name
            suggested = next_card_keep_both(name, deck_dir)
        elif category == "box":
            deck_dir.mkdir(parents=True, exist_ok=True)
            name = next_box_name(deck_dir)
            dest = deck_dir / name
            suggested = None
        elif category == "extra":
            extras_dir = deck_dir / "extras"
            extras_dir.mkdir(parents=True, exist_ok=True)
            name = next_extra_name(extras_dir)
            dest = extras_dir / name
            suggested = None
        elif category == "debug":
            if not filename_raw:
                raise ValueError("filename required for debug")
            name = filename_raw.strip().replace("\\", "_").replace("/", "_")
            if not DEBUG_NAME_RE.match(name) or name in {".", ".."}:
                raise ValueError("invalid debug filename")
            dest = deck_dir / "_debug" / name
            suggested = None
            replace = True
        else:
            name = normalize_back_stem(filename_raw)
            if not name:
                raise ValueError("invalid back filename")
            dest = deck_dir / name
            suggested = next_back_keep_both(deck_dir)

        dest_parent = dest.parent
        dest_parent.mkdir(parents=True, exist_ok=True)
        dest = assert_under_root(self.root, dest)

        if dest.exists() and not replace:
            rel = dest.relative_to(self.root.resolve()).as_posix()
            sug = None
            if suggested:
                sug = (deck_dir / suggested).relative_to(self.root.resolve()).as_posix()
            raise FileExistsError({"path": rel, "suggested": sug})

        rel = dest.relative_to(self.root.resolve()).as_posix()
        self._atomic_write(dest, data)
        print(f"201 {rel} {len(data)} bytes", flush=True)
        self._send_json(200, {"ok": True, "path": rel, "bytes": len(data)})

    def _atomic_write(self, dest: Path, data: bytes) -> None:
        dest.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(prefix=".tmp-", suffix=".jpg", dir=str(dest.parent))
        try:
            with os.fdopen(fd, "wb") as tmp:
                tmp.write(data)
                tmp.flush()
                os.fsync(tmp.fileno())
            os.replace(tmp_name, dest)
        except Exception:
            try:
                os.unlink(tmp_name)
            except OSError:
                pass
            raise


def make_server(root: Path, port: int) -> ThreadingHTTPServer:
    class BoundHandler(InboxHandler):
        pass

    BoundHandler.root = root.resolve()
    httpd = InboxServer(("0.0.0.0", port), BoundHandler)
    httpd.daemon_threads = True
    return httpd


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Card photo HTTP inbox")
    p.add_argument("root", help="archive root directory")
    p.add_argument("--port", type=int, default=8080)
    p.add_argument(
        "--create",
        action="store_true",
        help="create root if missing (also the default)",
    )
    return p.parse_args(argv)


def prepare_root(path: Path, create: bool = True) -> Path:
    if path.exists() and not path.is_dir():
        raise SystemExit(f"not a directory: {path}")
    if not path.exists():
        if not create:
            raise SystemExit(f"missing directory: {path}")
        path.mkdir(parents=True, exist_ok=True)
    return path.resolve()


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)
    root = prepare_root(Path(args.root).expanduser(), create=True)
    httpd = make_server(root, args.port)
    print(f"Card inbox root={root}", flush=True)
    for ip in local_ips():
        print(f"http://{ip}:{args.port}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopping")
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
