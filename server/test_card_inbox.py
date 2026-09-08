#!/usr/bin/env python3
from __future__ import annotations

import io
import json
import os
import threading
import unittest
from http.client import HTTPConnection
from pathlib import Path
from tempfile import TemporaryDirectory

from card_inbox import (
    assert_under_root,
    make_server,
    normalize_card_stem,
    prepare_root,
    sanitize_deck,
)

TINY_JPEG = bytes(
    [
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
        0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
        0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09,
        0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
        0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20,
        0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29,
        0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32,
        0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
        0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x14, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x09, 0xFF, 0xC4, 0x00, 0x14, 0x10, 0x01, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
        0x7F, 0xFF, 0xD9,
    ]
)


def encode_multipart(fields: dict[str, str], file_bytes: bytes) -> tuple[bytes, str]:
    boundary = "----CardInboxTestBoundary"
    buf = io.BytesIO()
    for name, value in fields.items():
        buf.write(f"--{boundary}\r\n".encode())
        buf.write(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        buf.write(value.encode())
        buf.write(b"\r\n")
    buf.write(f"--{boundary}\r\n".encode())
    buf.write(b'Content-Disposition: form-data; name="file"; filename="shot.jpg"\r\n')
    buf.write(b"Content-Type: image/jpeg\r\n\r\n")
    buf.write(file_bytes)
    buf.write(b"\r\n")
    buf.write(f"--{boundary}--\r\n".encode())
    return buf.getvalue(), f"multipart/form-data; boundary={boundary}"


class SanitizeTests(unittest.TestCase):
    def test_trim_and_allow(self):
        self.assertEqual(sanitize_deck("  Vikings  "), "Vikings")
        self.assertEqual(sanitize_deck("Red-Blue_1"), "Red-Blue_1")
        self.assertEqual(sanitize_deck("Ace of Spades"), "Ace of Spades")

    def test_replace_and_collapse(self):
        self.assertEqual(sanitize_deck("foo/bar"), "foo_bar")
        self.assertEqual(sanitize_deck("a...b"), "a_b")
        self.assertEqual(sanitize_deck("hi!!!there"), "hi_there")

    def test_reject_empty_and_dots(self):
        self.assertIsNone(sanitize_deck(""))
        self.assertIsNone(sanitize_deck("   "))
        self.assertIsNone(sanitize_deck(".."))
        self.assertIsNone(sanitize_deck("."))
        self.assertIsNone(sanitize_deck("///"))

    def test_max_length(self):
        s = sanitize_deck("A" * 100)
        self.assertEqual(len(s), 80)

    def test_card_filename(self):
        self.assertEqual(normalize_card_stem("5h.jpg"), "5H.jpg")
        self.assertEqual(normalize_card_stem("as"), "AS.jpg")
        self.assertEqual(normalize_card_stem("10d.JPG"), "10D.jpg")
        self.assertEqual(normalize_card_stem("QC"), "QC.jpg")
        self.assertEqual(normalize_card_stem("5H_2.jpg"), "5H_2.jpg")
        self.assertIsNone(normalize_card_stem("../5H.jpg"))
        self.assertIsNone(normalize_card_stem("joker.jpg"))
        self.assertIsNone(normalize_card_stem("5X.jpg"))
        self.assertIsNone(normalize_card_stem("11H.jpg"))

    def test_path_containment(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            inside = assert_under_root(root, root / "Vikings" / "5H.jpg")
            self.assertTrue(str(inside).startswith(str(root)))
            with self.assertRaises(ValueError):
                evil = root / "Vikings" / ".." / ".." / "etc" / "passwd"
                # resolve may escape; assert must reject if outside
                if evil.resolve().is_relative_to(root):
                    self.skipTest("sandbox cannot escape tmp")
                assert_under_root(root, evil)


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.root = prepare_root(Path(self.tmp.name) / "cards")
        self.httpd = make_server(self.root, 0)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.tmp.cleanup()

    def _conn(self) -> HTTPConnection:
        return HTTPConnection("127.0.0.1", self.port, timeout=5)

    def _json(self, method: str, path: str, body=None, headers=None):
        c = self._conn()
        c.request(method, path, body=body, headers=headers or {})
        resp = c.getresponse()
        raw = resp.read()
        c.close()
        return resp.status, json.loads(raw.decode())

    def _upload(self, fields: dict[str, str], data: bytes = TINY_JPEG):
        body, ctype = encode_multipart(fields, data)
        return self._json(
            "POST",
            "/upload",
            body=body,
            headers={"Content-Type": ctype, "Content-Length": str(len(body))},
        )

    def test_deck_dir_inherits_root_mode(self):
        # A group/world-writable share must not sprout 0755 deck folders:
        # deleting a file needs write on its directory, not on the file.
        os.chmod(self.root, 0o777)
        self._upload({"deck": "Vikings", "category": "card", "filename": "5H.jpg"})
        mode = (self.root / "Vikings").stat().st_mode & 0o777
        self.assertEqual(mode, 0o777, f"deck dir is {mode:o}")

    def test_uploads_are_group_and_other_readable(self):
        self._upload({"deck": "Vikings", "category": "card", "filename": "5H.jpg"})
        mode = (self.root / "Vikings" / "5H.jpg").stat().st_mode & 0o777
        # mkstemp's 0600 would make the archive unreadable over a NAS share.
        self.assertTrue(mode & 0o044, f"mode {mode:o} is not readable by others")

    def _delete(self, deck: str, filename: str):
        body = json.dumps({"deck": deck, "filename": filename}).encode()
        return self._json(
            "POST",
            "/delete",
            body=body,
            headers={"Content-Type": "application/json", "Content-Length": str(len(body))},
        )

    def test_delete_moves_card_to_trash(self):
        self._upload({"deck": "Vikings", "category": "card", "filename": "2S.jpg"})
        status, payload = self._delete("Vikings", "2S.jpg")
        self.assertEqual(status, 200, payload)
        self.assertFalse((self.root / "Vikings" / "2S.jpg").exists())
        trashed = list((self.root / "Vikings" / "_trash").iterdir())
        self.assertEqual(len(trashed), 1)
        self.assertTrue(trashed[0].name.endswith("2S.jpg"))
        self.assertEqual(trashed[0].read_bytes(), TINY_JPEG)

        _, listing = self._json("GET", "/deck/Vikings")
        self.assertEqual(listing["cards"], [])

        # Re-shooting the deleted card is a plain upload again, no 409.
        status, payload = self._upload(
            {"deck": "Vikings", "category": "card", "filename": "2S.jpg"}
        )
        self.assertEqual(status, 200, payload)

    def test_delete_extra(self):
        self._upload({"deck": "Vikings", "category": "extra"})
        status, payload = self._delete("Vikings", "01.jpg")
        self.assertEqual(status, 200, payload)
        self.assertFalse((self.root / "Vikings" / "extras" / "01.jpg").exists())

    def test_delete_missing_and_traversal(self):
        status, _ = self._delete("Vikings", "AS.jpg")
        self.assertEqual(status, 404)
        status, _ = self._delete("Vikings", "../../etc/passwd")
        self.assertEqual(status, 400)
        status, _ = self._delete("", "AS.jpg")
        self.assertEqual(status, 400)

    def test_health(self):
        status, payload = self._json("GET", "/health")
        self.assertEqual(status, 200)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["root"], str(self.root))

    def test_card_upload_and_list(self):
        status, payload = self._upload(
            {"deck": "Vikings", "category": "card", "filename": "5h.jpg"}
        )
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["path"], "Vikings/5H.jpg")
        dest = self.root / "Vikings" / "5H.jpg"
        self.assertTrue(dest.is_file())
        self.assertEqual(dest.read_bytes(), TINY_JPEG)

        status, listing = self._json("GET", "/deck/Vikings")
        self.assertEqual(status, 200)
        self.assertIn("5H.jpg", listing["cards"])

    def test_card_409_then_replace(self):
        self._upload({"deck": "Vikings", "category": "card", "filename": "5H.jpg"})
        status, payload = self._upload(
            {"deck": "Vikings", "category": "card", "filename": "5H.jpg"}
        )
        self.assertEqual(status, 409)
        self.assertEqual(payload["path"], "Vikings/5H.jpg")
        self.assertEqual(payload["suggested"], "Vikings/5H_2.jpg")
        self.assertTrue((self.root / "Vikings" / "5H.jpg").exists())

        status, payload = self._upload(
            {
                "deck": "Vikings",
                "category": "card",
                "filename": "5H.jpg",
                "replace": "true",
            }
        )
        self.assertEqual(status, 200, payload)

        status, payload = self._upload(
            {"deck": "Vikings", "category": "card", "filename": "5H_2.jpg"}
        )
        self.assertEqual(status, 200, payload)
        self.assertTrue((self.root / "Vikings" / "5H_2.jpg").is_file())

    def test_box_and_extra_increment(self):
        s1, p1 = self._upload({"deck": "Vikings", "category": "box"})
        s2, p2 = self._upload({"deck": "Vikings", "category": "box"})
        self.assertEqual(s1, 200)
        self.assertEqual(s2, 200)
        self.assertEqual(p1["path"], "Vikings/box_01.jpg")
        self.assertEqual(p2["path"], "Vikings/box_02.jpg")

        s3, p3 = self._upload({"deck": "Vikings", "category": "extra"})
        s4, p4 = self._upload({"deck": "Vikings", "category": "extra"})
        self.assertEqual(p3["path"], "Vikings/extras/01.jpg")
        self.assertEqual(p4["path"], "Vikings/extras/02.jpg")

    def test_back_409(self):
        s1, p1 = self._upload({"deck": "Vikings", "category": "back"})
        self.assertEqual(p1["path"], "Vikings/back.jpg")
        s2, p2 = self._upload({"deck": "Vikings", "category": "back"})
        self.assertEqual(s2, 409)
        self.assertEqual(p2["suggested"], "Vikings/back_2.jpg")
        s3, p3 = self._upload(
            {"deck": "Vikings", "category": "back", "filename": "back_2.jpg"}
        )
        self.assertEqual(s3, 200, p3)
        self.assertEqual(p3["path"], "Vikings/back_2.jpg")

    def test_missing_deck_lists_empty(self):
        status, payload = self._json("GET", "/deck/Vikings")
        self.assertEqual(status, 200)
        self.assertEqual(payload["cards"], [])
        self.assertEqual(payload["back"], [])

    def test_path_traversal_filename(self):
        status, payload = self._upload(
            {"deck": "Vikings", "category": "card", "filename": "../AS.jpg"}
        )
        self.assertEqual(status, 400)
        self.assertFalse((self.root.parent / "AS.jpg").exists())

    def test_path_traversal_deck(self):
        status, payload = self._upload(
            {"deck": "../outside", "category": "card", "filename": "AS.jpg"}
        )
        self.assertEqual(status, 200, payload)
        self.assertTrue((self.root / "outside" / "AS.jpg").is_file())
        self.assertFalse((self.root.parent / "outside" / "AS.jpg").exists())


if __name__ == "__main__":
    unittest.main()
