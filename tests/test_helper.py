import importlib.util
import tempfile
import os
import shutil
import subprocess
import unittest
from pathlib import Path

import pymupdf

spec = importlib.util.spec_from_file_location("helper", Path(__file__).parents[1] / "python/helper.py")
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class PageViewTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "pages.pdf"
        with pymupdf.open() as pdf:
            for width, height, color in [(200, 300, (1, 0, 0)), (100, 200, (0, 0, 1))]:
                page = pdf.new_page(width=width, height=height)
                page.draw_rect(page.rect, color=None, fill=color)
                page.insert_text((10, 30), "alpha beta")
            pdf.new_page(width=200, height=300)  # no text
            pdf.save(self.path)
        self.d = helper.Doc(str(self.path))

    def tearDown(self):
        self.d.doc.close()
        self.tmp.cleanup()

    def test_cross_page_clip_scales_each_page_and_preserves_gap(self):
        # At 400px wide: first page is 600px tall, second is 800px tall.
        pix = helper.render_view(self.d, 400, 120, 570, 10, [])
        self.assertEqual((pix.width, pix.height), (400, 120))
        self.assertEqual(pix.pixel(200, 29), (255, 0, 0))
        self.assertEqual(pix.pixel(200, 30), helper.GAP_COLOR)
        self.assertEqual(pix.pixel(200, 39), helper.GAP_COLOR)
        self.assertEqual(pix.pixel(200, 40), (0, 0, 255))
        self.assertEqual(pix.pixel(200, 119), (0, 0, 255))

    def test_fractional_page_boundary_does_not_leave_a_dark_seam(self):
        # Page 1 ends halfway through row 21, which may be antialiased,
        # but there must not be a background-coloured seam before it.
        pix = helper.render_view(self.d, 401, 100, 580, 10, [])
        for y in range(21):
            self.assertEqual(pix.pixel(200, y), (255, 0, 0), f"row {y}")
        self.assertEqual(pix.pixel(200, 21)[0], 255)
        for y in range(22, 32):
            self.assertEqual(pix.pixel(200, y), helper.GAP_COLOR, f"row {y}")
        for y in range(32, 100):
            self.assertEqual(pix.pixel(200, y), (0, 0, 255), f"row {y}")

    def test_marks_only_tint_their_own_page(self):
        lnum = self.d.page_lines[1][0]
        box = self.d.range_rect(lnum, 0, 0)
        pix = helper.render_view(self.d, 200, 500, 0, 0, [{"ranges": [[lnum, 0, 0]], "color": 0xFF0000}])
        # Blue multiplied by red is black inside the marked character's box;
        # the same page-relative coordinate on page 1 must remain red.
        x, y = int(box.x0 * 2), int(box.y0 * 2)
        self.assertEqual(pix.pixel(x, 300 + y), (0, 0, 0))
        self.assertEqual(pix.pixel(x, y), (255, 0, 0))

    def test_scrollbar_bulk_fills_preserve_page_and_track_boundaries(self):
        pix = helper.render_view(self.d, 400, 120, 570, 10, [])
        helper.scrollbar(pix, self.d, 570, 10)
        # Page composition is untouched to the left of the 12px scrollbar.
        self.assertEqual(pix.pixel(387, 0), (255, 0, 0))
        self.assertEqual(pix.pixel(387, 119), (0, 0, 255))
        self.assertEqual(pix.pixel(399, 0), helper.SCROLLBAR["track"])
        self.assertEqual(pix.pixel(399, 119), helper.SCROLLBAR["track"])
        # Page 2 starts at 610/2020 of the document; the thumb is inset.
        self.assertEqual(pix.pixel(388, 36), helper.SCROLLBAR["tick"])
        self.assertEqual(pix.pixel(390, 36), helper.SCROLLBAR["thumb"])
        self.assertEqual(pix.pixel(389, 35), helper.SCROLLBAR["track"])

    def test_hit_returns_character_index_and_empty_page_has_no_hit(self):
        helper.docs[1] = self.d
        try:
            lnum = self.d.page_lines[1][0]
            box = self.d.boxes[lnum - 1][6]
            hit = helper.m_hit({"key": 1, "page": 1, "x": (box.x0 + box.x1) / 2, "y": (box.y0 + box.y1) / 2})
            self.assertEqual(hit, [lnum, 6])
            self.assertIsNone(helper.m_hit({"key": 1, "page": 2, "x": 50, "y": 50}))
        finally:
            del helper.docs[1]

    def test_snapshot_includes_visible_parts_of_both_pages(self):
        helper.docs[1] = self.d
        out = str(Path(self.tmp.name) / "snapshot.png")
        try:
            helper.m_snapshot({"key": 1, "top": 570, "height": 120, "gap": 10, "width": 400, "ranges": [], "out": out})
            pix = pymupdf.Pixmap(out)
            self.assertEqual(pix.pixel(200, 29), (255, 0, 0))
            self.assertEqual(pix.pixel(200, 40), (0, 0, 255))
            self.assertGreater(pix.height, 120)  # caption below the actual view
        finally:
            del helper.docs[1]

    def test_hollow_cursor_preserves_interior_and_only_tints_border(self):
        pix = pymupdf.Pixmap(pymupdf.csRGB, pymupdf.IRect(0, 0, 30, 20), False)
        pix.clear_with(255)
        rect, matrix = pymupdf.Rect(2, 2, 28, 18), pymupdf.Matrix(1, 1)
        helper.tint(pix, rect, matrix, 0x0000FF, outline=True)
        self.assertEqual(pix.pixel(2, 2), (0, 0, 255))
        self.assertEqual(pix.pixel(27, 17), (0, 0, 255))
        self.assertEqual(pix.pixel(15, 10), (255, 255, 255))
        self.assertEqual(pix.pixel(1, 10), (255, 255, 255))
        helper.tint(pix, rect, matrix, 0x0000FF)
        self.assertEqual(pix.pixel(15, 10), (0, 0, 255))

    @unittest.skipUnless(shutil.which("nvim"), "Neovim is not installed")
    def test_page_view_interactions(self):
        path = Path(self.tmp.name) / "columns.pdf"
        with pymupdf.open() as pdf:
            page = pdf.new_page(width=600, height=800)
            # Reading order goes down the left column before the right column:
            # right-column text is visible on the page, but outside w0..w$.
            for i in range(45):
                page.insert_text((30, 60 + i * 15), f"left {i:02d} words")
            page.insert_text((350, 90), "right xy beacon")
            page.insert_text((350, 130), "right xy second")
            page = pdf.new_page(width=400, height=500)
            page.insert_text((30, 60), "second page")
            pdf.save(path)
        env = {**os.environ, "PDFVIEW_TEST_PDF": str(path)}
        root = Path(__file__).parents[1]
        result = subprocess.run(
            ["nvim", "--headless", "-u", "NONE", "-i", "NONE", "-c", "luafile tests/test_nvim.lua"],
            cwd=root, env=env, text=True, capture_output=True, timeout=90,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
