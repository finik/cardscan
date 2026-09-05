#!/usr/bin/env python3
from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from generate_catalog import (
    discover_decks,
    generate,
    load_deck_json,
    pick_cover,
    slugify,
    ImageItem,
)

FIXTURES = Path(__file__).resolve().parent / "fixtures"
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


class MetadataTests(unittest.TestCase):
    def test_load_sample_deck_json(self):
        meta = load_deck_json(FIXTURES / "Sample Deck")
        self.assertEqual(meta["title"], "Sample Deck")
        self.assertIn("fixture", meta["tags"])
        self.assertEqual(meta["cover"], "box_01.jpg")

    def test_missing_deck_json(self):
        self.assertEqual(load_deck_json(FIXTURES / "Minimal Deck"), {})

    def test_invalid_json_degrades(self):
        with TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "deck.json").write_text("{not json", encoding="utf-8")
            self.assertEqual(load_deck_json(d), {})

    def test_pick_cover_prefers_meta_then_box(self):
        images = [
            ImageItem("AS.jpg", "AS", "card"),
            ImageItem("box_01.jpg", "Box 01", "box"),
            ImageItem("back.jpg", "Back", "back"),
        ]
        self.assertEqual(pick_cover({"cover": "back.jpg"}, images), "back.jpg")
        self.assertEqual(pick_cover({}, images), "box_01.jpg")


class DiscoveryTests(unittest.TestCase):
    def test_discover_fixtures(self):
        decks = discover_decks(FIXTURES)
        names = {d.folder_name for d in decks}
        self.assertEqual(names, {"Sample Deck", "Minimal Deck"})

        sample = next(d for d in decks if d.folder_name == "Sample Deck")
        self.assertEqual(sample.title, "Sample Deck")
        self.assertEqual(sample.cover, "box_01.jpg")
        self.assertTrue(any(i.category == "extra" for i in sample.images))
        cats = {i.rel_path: i.category for i in sample.images}
        self.assertEqual(cats["AS.jpg"], "card")
        self.assertEqual(cats["back.jpg"], "back")
        self.assertEqual(cats["extras/01.jpg"], "extra")

        minimal = next(d for d in decks if d.folder_name == "Minimal Deck")
        self.assertEqual(minimal.title, "Minimal Deck")  # folder name fallback
        self.assertEqual(minimal.description, "")
        self.assertIn(minimal.cover, {"AS.jpg", "back.jpg"})

    def test_empty_folder_skipped(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Empty").mkdir()
            (root / "HasCard").mkdir()
            (root / "HasCard" / "AS.jpg").write_bytes(TINY_JPEG)
            decks = discover_decks(root)
            self.assertEqual([d.folder_name for d in decks], ["HasCard"])

    def test_slugify(self):
        self.assertEqual(slugify("Sample Deck"), "sample-deck")
        self.assertEqual(slugify("  Ace!!! "), "ace")


class GenerateTests(unittest.TestCase):
    def test_generate_produces_expected_html(self):
        with TemporaryDirectory() as tmp:
            out = Path(tmp) / "site"
            decks = generate(FIXTURES, out, site_title="Test Catalog")
            self.assertEqual(len(decks), 2)

            index = out / "index.html"
            self.assertTrue(index.is_file())
            index_html = index.read_text(encoding="utf-8")
            self.assertIn("Test Catalog", index_html)
            self.assertIn("Sample Deck", index_html)
            self.assertIn("Minimal Deck", index_html)
            self.assertIn('href="decks/sample-deck/index.html"', index_html)
            self.assertIn('href="decks/minimal-deck/index.html"', index_html)

            sample_page = out / "decks" / "sample-deck" / "index.html"
            self.assertTrue(sample_page.is_file())
            page = sample_page.read_text(encoding="utf-8")
            self.assertIn("lightbox", page)
            self.assertIn("Box", page)
            self.assertIn("Cards", page)
            self.assertIn("Extras", page)
            self.assertIn('data-lb-index="0"', page)

            # images copied
            self.assertTrue((out / "decks" / "sample-deck" / "AS.jpg").is_file())
            self.assertTrue((out / "decks" / "sample-deck" / "extras" / "01.jpg").is_file())
            self.assertTrue((out / "assets" / "style.css").is_file())
            self.assertTrue((out / "assets" / "catalog.js").is_file())

            # cover referenced on index
            self.assertIn("decks/sample-deck/box_01.jpg", index_html)

    def test_cli_main(self):
        from generate_catalog import main

        with TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            code = main([str(FIXTURES), "-o", str(out), "--title", "CLI"])
            self.assertEqual(code, 0)
            self.assertTrue((out / "index.html").is_file())

    def test_cli_missing_archive(self):
        from generate_catalog import main

        code = main(["/nonexistent/archive/path", "-o", "/tmp/unused-site"])
        self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
