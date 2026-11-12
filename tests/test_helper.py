import hashlib
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
        helper.scrollbar(pix, self.d, 570, 10, 12)
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


def build_annotated_pdf(path, rich=False):
    """Page 1: 'alpha beta gamma' under a Highlight (custom colour, opacity,
    flags, author, content). `rich` adds a popup, a reply and a second text line.
    Page 2: 'second page'."""
    with pymupdf.open() as pdf:
        page = pdf.new_page(width=300, height=400)
        page.insert_text((20, 50), "alpha beta gamma")
        if rich:
            page.insert_text((20, 90), "delta epsilon")
        hl = page.add_highlight_annot(page.search_for("alpha")[0])
        hl.set_colors(stroke=(0.1, 0.7, 0.3))
        hl.set_opacity(0.35)
        hl.set_flags(4)  # print
        hl.set_info(content="existing note", title="Ann", subject="Subj")
        hl.update()
        if rich:
            hl.set_popup(pymupdf.Rect(150, 40, 250, 100))
            hl.set_open(True)
            reply = page.add_text_annot((200, 200), "a reply")
            pdf.xref_set_key(reply.xref, "IRT", "%d 0 R" % hl.xref)
            pdf.xref_set_key(reply.xref, "RT", "/R")
            reply.update()
        pdf.new_page(width=200, height=200).insert_text((10, 30), "second page")
        pdf.save(path)


def objects(doc, count=None):
    """{xref: (source, raw stream)} of the first `count` objects of `doc`."""
    return {
        x: (doc.xref_object(x), doc.xref_stream_raw(x) if doc.xref_is_stream(x) else None)
        for x in range(1, count or doc.xref_length())
    }


def file_annots(path):
    with pymupdf.open(path) as pdf:
        return [(a.xref, a.type[1], a.info["content"]) for a in pdf[0].annots(types=helper.SUPPORTED)]


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class AnnotationCase(unittest.TestCase):
    """Protocol-level harness: documents are driven through helper.METHODS."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.close_all)
        self.path = str(Path(self.tmp.name) / "doc.pdf")
        build_annotated_pdf(self.path, rich=True)
        self.open_doc(self.path)

    def close_all(self):
        for key in list(helper.docs):
            helper.m_close({"key": key})
        self.tmp.cleanup()

    def call(self, method, key=None, **params):
        return helper.METHODS[method]({"key": key or self.key, **params})

    def open_doc(self, path, key=1):
        self.key = key
        with pymupdf.open(path) as pdf:
            self.original = objects(pdf)
            self.original_pixels = pdf[0].get_pixmap().samples
        self.checked = set(self.original)
        self.digest = digest(path)
        self.opened = self.call("open", path=path)
        self.d = helper.docs[key]
        self.s0 = self.opened["state"]
        self.hl = next(a["xref"] for a in self.opened["annots"] if a["type"] == "Highlight")
        self.reply = next((a["xref"] for a in self.opened["annots"] if a["type"] == "Text"), None)

    def assert_original(self):
        """Every checked object the PDF had at open is byte-identical again, and it renders the same."""
        current = objects(self.d.doc)
        self.assertEqual({x: current[x] for x in self.checked}, {x: self.original[x] for x in self.checked})
        self.assertEqual(self.d.doc[0].get_pixmap().samples, self.original_pixels)

    def line(self, pno, index=0):
        return self.d.page_lines[pno][index]

    def annotate(self, kind="highlight", pno=0, index=0, cs=6, ce=9, **extra):
        return self.call("annotate", kind=kind, ranges=[[self.line(pno, index), cs, ce]], **extra)


class AnnotationStateTest(AnnotationCase):
    def test_edits_that_change_nothing_leave_the_state_and_document_alone(self):
        same = self.call("set_contents", page=0, xref=self.hl, contents="existing note")
        self.assertEqual(same["state"], self.s0)
        self.assertFalse(self.d.doc.is_dirty)
        # A highlight made and deleted again is not a change either.
        made = self.annotate()
        self.assertNotEqual(made["state"], self.s0)
        gone = self.call("delete", page=0, xref=made["xref"])
        self.assertEqual(gone["state"], self.s0)

    def test_undoing_the_delete_of_an_imported_annotation_brings_back_every_object(self):
        self.assertEqual(self.d.doc.xref_get_key(self.hl, "Popup")[0], "xref")
        self.assertEqual(self.d.doc.xref_get_key(self.reply, "IRT"), ("xref", "%d 0 R" % self.hl))
        deleted = self.call("delete", page=0, xref=self.hl)
        self.assertEqual(deleted["annots"], [])  # its reply and popup went with it
        self.assertNotEqual(self.d.doc[0].get_pixmap().samples, self.original_pixels)
        restored = self.call("restore", state=self.s0)
        self.assertEqual(restored["state"], self.s0)
        self.assertEqual(restored["annots"], self.opened["annots"])
        self.assert_original()
        self.assertEqual(self.d.doc.xref_get_key(self.reply, "IRT"), ("xref", "%d 0 R" % self.hl))
        self.assertEqual(self.d.state(), self.s0)
        # Text, boxes and line numbers of the buffer do not depend on annotations.
        fresh = helper.Doc(self.path)
        self.assertEqual((fresh.lines, fresh.info), (self.d.lines, self.d.info))
        fresh.doc.close()

    def test_undoing_an_edit_of_an_imported_annotation_restores_the_original(self):
        edited = self.call("set_contents", page=0, xref=self.hl, contents="rewritten")
        self.assertEqual([a["contents"] for a in edited["annots"]][0], "rewritten")
        self.assertNotEqual(edited["state"], self.s0)
        self.call("restore", state=self.s0)
        self.assertEqual(self.d.all_annots(), self.opened["annots"])
        self.assert_original()
        redone = self.call("restore", state=edited["state"])
        self.assertEqual(redone["state"], edited["state"])
        self.assertEqual(redone["annots"][0]["contents"], "rewritten")
        self.assertEqual(self.d.state(), edited["state"])

    def test_restoring_moves_between_divergent_branches(self):
        a = self.annotate("highlight", contents="branch a")
        self.call("restore", state=self.s0)
        b = self.annotate("strikeout", index=1, cs=0, ce=4)
        self.assertNotEqual(a["state"], b["state"])

        def kinds(res):
            return [(x["type"], x["contents"]) for x in res["annots"]]

        base = [("Highlight", "existing note"), ("Text", "a reply")]
        self.assertEqual(kinds(b), base + [("StrikeOut", "")])
        self.assertEqual(kinds(self.call("restore", state=a["state"])), base + [("Highlight", "branch a")])
        # Editing on a restored branch forks a third one.
        c = self.call("set_contents", page=0, xref=a["xref"], contents="branch c")
        self.assertEqual(kinds(self.call("restore", state=b["state"])), base + [("StrikeOut", "")])
        self.assertEqual(kinds(self.call("restore", state=c["state"])), base + [("Highlight", "branch c")])
        self.assertEqual(kinds(self.call("restore", state=a["state"])), base + [("Highlight", "branch a")])
        self.assertEqual(self.d.state(), a["state"])
        self.call("restore", state=self.s0)
        self.assert_original()

    def test_states_span_pages(self):
        first = self.annotate(pno=0)
        second = self.annotate(pno=1, index=0, cs=0, ce=5)
        self.assertEqual([a["page"] for a in second["annots"]], [1])
        both = self.call("restore", state=second["state"])
        self.assertEqual(sorted(a["page"] for a in both["annots"]), [0, 0, 0, 1])
        only_first = self.call("restore", state=first["state"])
        self.assertEqual(sorted(a["page"] for a in only_first["annots"]), [0, 0, 0])
        self.call("restore", state=self.s0)
        self.assert_original()
        self.assertEqual(len(self.call("restore", state=second["state"])["annots"]), 4)

    def test_a_state_carries_only_what_changed_since_open(self):
        path = str(Path(self.tmp.name) / "many.pdf")
        with pymupdf.open() as pdf:
            page = pdf.new_page(width=300, height=800)
            for i in range(40):
                page.insert_text((20, 20 + i * 18), "word%02d" % i)
                annot = page.add_highlight_annot(page.search_for("word%02d" % i)[0])
                annot.set_info(content="note %d" % i)
                annot.update()
            pdf.save(path)
        self.open_doc(path, key=2)
        self.assertLess(len(self.s0), 300)
        target = self.opened["annots"][7]["xref"]
        edited = self.call("set_contents", key=2, page=0, xref=target, contents="edited")
        _pages, objs = self.d.decode_state(edited["state"])
        self.assertLessEqual(len(objs), 3)
        self.assertTrue(all(x == target or x >= self.d.open_len for x in objs), sorted(objs))
        self.assertLess(len(edited["state"]), 3000)
        self.assertEqual(len(self.call("restore", key=2, state=self.s0)["annots"]), 40)

    def test_nothing_is_written_before_save(self):
        stat = os.stat(self.path)
        made = self.annotate()
        self.call("set_contents", page=0, xref=self.hl, contents="changed")
        self.call("delete", page=0, xref=self.reply)
        self.call("restore", state=made["state"])
        self.call("restore", state=self.s0)
        self.assertEqual(digest(self.path), self.digest)
        self.assertEqual(os.stat(self.path).st_mtime_ns, stat.st_mtime_ns)

    def test_save_keeps_old_states_restorable_and_persists_only_the_current_one(self):
        original_annots = file_annots(self.path)
        a = self.annotate(contents="kept")
        saved = self.call("save")
        self.assertEqual(saved["state"], a["state"])  # saving changes no state
        on_disk = file_annots(self.path)
        self.assertEqual(on_disk[-1][1:], ("Highlight", "kept"))
        # Undo after the save: only the next save writes it.
        self.call("restore", state=self.s0)
        self.assertEqual(file_annots(self.path), on_disk)
        self.call("save")
        self.assertEqual(file_annots(self.path), original_annots)
        with pymupdf.open(self.path) as pdf:
            current = objects(pdf)
            self.assertEqual({x: current[x] for x in self.original}, self.original)
        # Redo the saved state, and branch from the undone one.
        self.assertEqual(self.call("restore", state=a["state"])["state"], a["state"])
        self.call("save")
        self.assertEqual(file_annots(self.path), on_disk)
        self.call("restore", state=self.s0)
        b = self.annotate("underline", index=1, cs=0, ce=4)
        self.call("save")
        self.assertEqual([x[1] for x in file_annots(self.path)], ["Highlight", "Text", "Underline"])
        self.assertEqual(self.call("restore", state=a["state"])["state"], a["state"])
        self.assertEqual(self.call("restore", state=b["state"])["state"], b["state"])

    def test_repeated_saves_in_one_session_write_valid_files(self):
        self.annotate(contents="one")
        self.call("save")
        self.call("set_contents", page=0, xref=self.hl, contents="two")
        self.call("save")
        self.annotate("underline", index=1, cs=0, ce=4)
        self.call("save")
        with pymupdf.open(self.path) as pdf:
            self.assertFalse(pdf.is_repaired)
        self.assertEqual(
            [x[1:] for x in file_annots(self.path)],
            [("Highlight", "two"), ("Text", "a reply"), ("Highlight", "one"), ("Underline", "")],
        )

    def test_save_as_leaves_the_state_and_the_source_alone(self):
        a = self.annotate(contents="copy")
        copy = str(Path(self.tmp.name) / "copy.pdf")
        self.assertEqual(self.call("save", path=copy)["state"], a["state"])
        self.assertEqual(digest(self.path), self.digest)
        self.assertEqual(file_annots(copy)[-1][1:], ("Highlight", "copy"))

    def test_malformed_foreign_and_stale_states_are_rejected_without_side_effects(self):
        a = self.annotate()
        for bad in ("", "nope", helper.STATE_PREFIX + "!!!", helper.STATE_PREFIX + "eJwDAAAAAAE="):
            with self.assertRaises(ValueError):
                self.call("restore", state=bad)
        self.open_doc(self.path, key=2)
        with self.assertRaises(ValueError):
            self.call("restore", key=2, state=a["state"])
        self.assertEqual(self.d.state(), self.s0)
        self.assertEqual(self.call("restore", key=1, state=a["state"])["state"], a["state"])

    def test_annotations_array_stored_as_an_indirect_object(self):
        path = str(Path(self.tmp.name) / "indirect.pdf")
        with pymupdf.open(self.path) as pdf:
            array = pdf.get_new_xref()
            pdf.update_object(array, pdf.xref_get_key(pdf[0].xref, "Annots")[1])
            pdf.xref_set_key(pdf[0].xref, "Annots", "%d 0 R" % array)
            pdf.save(path)
        self.open_doc(path, key=2)
        # MuPDF turns the indirect array into a direct one when it appends, so
        # the page object itself is compared by what its /Annots lists.
        page_xref = self.d.doc.page_xref(0)
        self.checked.discard(page_xref)
        refs = [a[0] for a in self.d.doc[0].annot_xrefs()]
        made = self.annotate(contents="new")
        self.assertEqual(len(made["annots"]), 3)
        self.assertEqual(len(self.call("restore", key=2, state=self.s0)["annots"]), 2)
        self.assert_original()
        self.assertEqual([a[0] for a in self.d.doc[0].annot_xrefs()], refs)
        self.assertEqual(len(self.call("restore", key=2, state=made["state"])["annots"]), 3)
        self.call("restore", key=2, state=self.s0)
        again = self.annotate(contents="new")
        self.assertEqual(again["annots"][-1]["contents"], "new")
        self.assertEqual(self.call("delete", key=2, page=0, xref=again["xref"])["state"], self.s0)


class FullRewriteSaveTest(AnnotationCase):
    """Documents MuPDF repaired on load cannot be saved incrementally: save
    rewrites them whole and drops every object nothing references any more."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.close_all)
        good = Path(self.tmp.name) / "good.pdf"
        build_annotated_pdf(good, rich=True)
        data = good.read_bytes()
        self.path = str(Path(self.tmp.name) / "repaired.pdf")
        Path(self.path).write_bytes(data[: data.rindex(b"startxref")] + b"startxref\n99999\n%%EOF\n")
        pymupdf.TOOLS.mupdf_display_errors(False)
        self.open_doc(self.path)
        if self.d.doc.can_save_incrementally():
            self.skipTest("MuPDF did not treat the damaged file as needing a rewrite")
        # The rewrite also deflates page content; only annotation objects must come back unchanged.
        self.checked = {x for x, (src, _) in self.original.items() if "/Type /Annot" in src or "/Subtype /Form" in src}

    def test_full_save_and_unchanged_note_preserve_saved_state_identity(self):
        changed = self.call("set_contents", page=0, xref=self.hl, contents="edited note")
        saved = self.call("save")
        self.assertEqual(saved["state"], changed["state"])
        self.assertFalse(self.d.doc.is_dirty)
        unchanged = self.call("set_contents", page=0, xref=self.hl, contents="edited note")
        self.assertEqual(unchanged["state"], saved["state"])
        self.assertFalse(self.d.doc.is_dirty)
        later = self.call("set_contents", page=0, xref=self.hl, contents="later edit")
        self.call("restore", state=saved["state"])
        page = self.d.doc[0]
        self.assertEqual(page.load_annot(self.hl).info["content"], "edited note")
        self.call("restore", state=later["state"])
        self.assertEqual(page.load_annot(self.hl).info["content"], "later edit")
        self.assertEqual(self.call("save")["state"], later["state"])

    def test_states_survive_rewrites_that_dropped_their_objects(self):
        made = self.annotate(contents="short lived")
        gone = self.call("delete", page=0, xref=made["xref"])
        self.assertEqual(gone["state"], self.s0)
        deleted = self.call("delete", page=0, xref=self.hl)
        self.call("save")
        self.assertEqual(file_annots(self.path), [])
        with pymupdf.open(self.path) as pdf:  # the unreferenced objects are really gone
            self.assertEqual(pdf.xref_object(self.hl), "null")
            self.assertEqual(pdf.xref_object(made["xref"]), "null")
        self.assertEqual(self.call("restore", state=self.s0)["annots"], self.opened["annots"])
        self.assert_original()
        self.call("save")
        self.assertEqual(file_annots(self.path), [(x["xref"], x["type"], x["contents"]) for x in self.opened["annots"]])
        self.assertEqual(self.call("restore", state=made["state"])["annots"][-1]["contents"], "short lived")
        self.call("save")
        self.assertEqual(file_annots(self.path)[-1][1:], ("Highlight", "short lived"))
        self.assertEqual(self.call("restore", state=deleted["state"])["annots"], [])
        self.call("save")
        self.assertEqual(file_annots(self.path), [])
        self.call("restore", state=self.s0)
        self.assert_original()

    def test_custom_font_glyph_survives_delete_full_save_and_undo(self):
        self.call("close")
        with pymupdf.open() as pdf:
            page = pdf.new_page(width=300, height=400)
            page.insert_text((20, 50), "alpha beta gamma")
            annot = page.add_highlight_annot(page.search_for("alpha")[0])
            annot.set_info(content="existing note")

            def obj(source, stream=None):
                xref = pdf.get_new_xref()
                pdf.update_object(xref, source)
                if stream is not None:
                    pdf.update_stream(xref, stream)
                return xref

            # /P is a glyph name, not an annotation's backlink to its page.
            glyph = obj("<< >>", b"1000 0 0 0 1000 1000 d1 0 0 1000 1000 re f")
            procs = obj(f"<< /P {glyph} 0 R >>")
            font = obj(
                f"<< /Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] "
                f"/FontMatrix [.001 0 0 .001 0 0] /CharProcs {procs} 0 R "
                f"/Encoding << /Type /Encoding /Differences [80 /P] >> "
                f"/FirstChar 80 /LastChar 80 /Widths [1000] /Resources << >> >>"
            )
            appearance = obj(
                f"<< /Type /XObject /Subtype /Form /BBox [0 0 120 60] "
                f"/Resources << /Font << /F1 {font} 0 R >> >> >>",
                b"0 0 0 rg BT /F1 40 Tf 5 5 Td (P) Tj ET",
            )
            pdf.xref_set_key(annot.xref, "AP", f"<< /N {appearance} 0 R >>")
            pdf.save(self.path)
        path = Path(self.path)
        data = path.read_bytes()
        path.write_bytes(data[: data.rindex(b"startxref")] + b"startxref\n99999\n%%EOF\n")
        self.open_doc(self.path)
        self.assertFalse(self.d.doc.can_save_incrementally())
        self.call("delete", page=0, xref=self.hl)
        self.call("save")
        self.call("restore", state=self.s0)
        self.assertEqual(self.d.doc[0].get_pixmap().samples, self.original_pixels)
        self.call("save")
        with pymupdf.open(self.path) as pdf:
            self.assertEqual(pdf[0].get_pixmap().samples, self.original_pixels)


class AnnotationInteractionTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which("nvim"), "Neovim is not installed")
    def test_annotation_interactions(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "annotated.pdf"
            build_annotated_pdf(path)
            env = {**os.environ, "PDFVIEW_TEST_PDF": str(path)}
            result = subprocess.run(
                ["nvim", "--headless", "-u", "NONE", "-i", "NONE", "-c", "luafile tests/test_annotations.lua"],
                cwd=Path(__file__).parents[1], env=env, text=True, capture_output=True, timeout=90,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
