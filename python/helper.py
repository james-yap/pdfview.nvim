# /// script
# requires-python = ">=3.11"
# dependencies = ["pymupdf>=1.26,<1.27"]
# ///
"""pdfview.nvim helper: one process per nvim, JSON lines on stdin/stdout.

Request:  {"id": n, "method": str, "params": {...}}
Response: {"id": n, "result": ...} or {"id": n, "error": str}

Buffer lines are owned here: `open` returns them, and every later request
addresses text by 1-based buffer line number plus 0-based, inclusive
character indices into that line (Lua converts its byte columns).

Annotation edits are undoable by the caller: `open`, `annotate`, `set_contents`,
`delete` and `save` return `state`, an opaque one-line string naming the
annotations the document now holds. `restore` {key, state} puts any state
string of the same `open` back (older, newer or from another branch) and
returns {state, annots} with every annotation of the document.
"""

import base64
import contextlib
import functools
import html
import json
import math
import os
import sys
import tempfile
import traceback
import uuid
import zlib
from typing import NamedTuple

import pymupdf

# Annotation types the plugin shows, lists, edits and deletes.
SUPPORTED = (
    pymupdf.PDF_ANNOT_HIGHLIGHT,
    pymupdf.PDF_ANNOT_UNDERLINE,
    pymupdf.PDF_ANNOT_STRIKE_OUT,
    pymupdf.PDF_ANNOT_SQUIGGLY,
    pymupdf.PDF_ANNOT_TEXT,
    pymupdf.PDF_ANNOT_FREE_TEXT,
)
CREATE = {
    "highlight": ("add_highlight_annot", (1.0, 0.89, 0.25)),
    "underline": ("add_underline_annot", (0.86, 0.15, 0.15)),
    "strikeout": ("add_strikeout_annot", (0.86, 0.15, 0.15)),
}

STATE_PREFIX = "pdfview-annots:1:"
PDF_WS = " \t\r\n\f\0"
PDF_DELIMS = "()<>[]{}/%"


class Cap(NamedTuple):
    """One PDF object as read: its source text and raw (still filtered) stream."""

    src: str
    stream: bytes | None


class ObjInfo(NamedTuple):
    type: str | None
    subtype: str | None
    follow: tuple  # xrefs an annotation state must carry along with this object

    @property
    def opaque(self):
        # Owners of annotations, never state of their own: restoring one
        # would rewind unrelated page, link or form content.
        return self.type in ("Page", "Pages", "Catalog") or self.subtype in ("Link", "Widget")


def pdf_tokens(src):
    """(kind, value) tokens of a PDF object's source: "<<", ">>", "[", "]",
    ("name", text), ("word", text) for numbers and keywords, ("str", raw text)."""
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c in PDF_WS or c in "{})":
            i += 1
        elif c == "%":
            while i < n and src[i] not in "\r\n":
                i += 1
        elif c == "(":
            start, depth, i = i, 1, i + 1
            while i < n and depth:
                if src[i] == "\\":
                    i += 1
                elif src[i] == "(":
                    depth += 1
                elif src[i] == ")":
                    depth -= 1
                i += 1
            yield "str", src[start:i]
        elif src.startswith("<<", i):
            yield "<<", None
            i += 2
        elif src.startswith(">>", i):
            yield ">>", None
            i += 2
        elif c == "<":
            end = src.find(">", i)
            end = n if end < 0 else end + 1
            yield "str", src[i:end]
            i = end
        elif c in "[]":
            yield c, None
            i += 1
        elif c == ">":
            i += 1
        else:
            j = i + 1
            while j < n and src[j] not in PDF_WS and src[j] not in PDF_DELIMS:
                j += 1
            yield ("name", src[i + 1 : j]) if c == "/" else ("word", src[i:j])
            i = j


@functools.lru_cache(maxsize=4096)
def parse_object(src):
    """Type, Subtype and referenced xrefs. Owner objects are excluded by their
    types during capture, not by dictionary keys: font glyphs can be named /P."""
    toks = list(pdf_tokens(src))
    stack, refs = [], []
    type_ = subtype = None
    for i, (kind, value) in enumerate(toks):
        if kind in ("<<", "["):
            stack.append(kind)
        elif kind in (">>", "]"):
            if stack:
                stack.pop()
        elif kind == "name" and stack == ["<<"] and i and toks[i - 1][0] == "name":
            if toks[i - 1][1] == "Type":
                type_ = value
            elif toks[i - 1][1] == "Subtype":
                subtype = value
        elif kind == "word" and value == "R" and i >= 2 and toks[i - 1][0] == toks[i - 2][0] == "word":
            if toks[i - 2][1].isdigit():
                refs.append(int(toks[i - 2][1]))
    follow = []
    for xref in refs:
        if xref in follow:
            continue
        follow.append(xref)
    return ObjInfo(type_, subtype, tuple(follow))


def same_source(a, b):
    """Whether two sources of one object differ at most in whitespace. For
    /Annots arrays None (no key) equals an empty array."""
    a, b = a or "[]", b or "[]"
    return a == b or list(pdf_tokens(a)) == list(pdf_tokens(b))


def array_refs(src):
    return parse_object(src or "[]").follow


docs = {}


class Doc:
    def __init__(self, path):
        self.path = path
        self.doc = pymupdf.open(path)
        if self.doc.needs_pass:
            raise ValueError("encrypted PDFs are not supported")
        self.lines = []  # buffer text, index = lnum - 1
        self.info = []  # [page, y0, y1, is_header] per buffer line
        self.boxes = []  # per buffer line: list of char Rects, None for headers
        self.page_lines = []  # per page: lnums of its text lines
        for pno, page in enumerate(self.doc):
            self.lines.append("── page %d ──" % (pno + 1))
            self.info.append([pno, 0, 0, True])
            self.boxes.append(None)
            lnums = []
            for block in page.get_text("rawdict")["blocks"]:
                for line in block.get("lines", ()):
                    chars = [c for span in line["spans"] for c in span["chars"]]
                    text = "".join(c["c"] if c["c"].isprintable() else " " for c in chars)
                    if not text.strip():
                        continue
                    bbox = line["bbox"]
                    self.lines.append(text)
                    self.info.append([pno, bbox[1], bbox[3], False])
                    self.boxes.append([pymupdf.Rect(c["bbox"]) for c in chars])
                    lnums.append(len(self.lines))
            self.page_lines.append(lnums)
        self.nonce = uuid.uuid4().hex  # states only restore into the document session that made them
        self.open_len = self.doc.xref_length()  # object numbers from here on are ours
        self.base = {}  # xref -> Cap | None: content when first seen (None: did not exist)
        self.live = {}  # xref -> Cap | None: content now
        self.encodings = {}  # xref -> (saved encoding, logical Cap before save)
        self.opaque = set()  # xrefs never captured: pages and other owners of annotations
        self.base_pages = {}  # pno -> /Annots source when the page was first edited
        self.live_pages = {}

    def header(self, pno):
        return next(i + 1 for i, info in enumerate(self.info) if info[0] == pno and info[3])

    def range_rect(self, lnum, cs, ce):
        boxes = self.boxes[lnum - 1]
        if not boxes:
            raise ValueError("line %d has no text" % lnum)
        cs, ce = max(cs, 0), min(ce, len(boxes) - 1)
        rect = pymupdf.Rect(boxes[cs])
        for box in boxes[cs + 1 : ce + 1]:
            rect |= box
        return rect

    def ranges_page(self, ranges):
        pages = {self.info[r[0] - 1][0] for r in ranges}
        if len(pages) != 1:
            raise ValueError("selection must stay on one page")
        return pages.pop()

    def nearest_line(self, pno, rect):
        lnums = self.page_lines[pno]
        if not lnums:
            return [self.header(pno), 0]
        cy = (rect.y0 + rect.y1) / 2
        lnum = min(lnums, key=lambda n: abs((self.info[n - 1][1] + self.info[n - 1][2]) / 2 - cy))
        return [lnum, 0]

    def annot_ranges(self, pno, annot):
        verts = annot.vertices or []
        rects = [pymupdf.Quad(verts[i : i + 4]).rect for i in range(0, len(verts) - 3, 4)]
        ranges = []
        for lnum in self.page_lines[pno]:
            hits = [
                i
                for i, b in enumerate(self.boxes[lnum - 1])
                if any(r.contains(pymupdf.Point((b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2)) for r in rects)
            ]
            if hits:
                ranges.append([lnum, hits[0], hits[-1]])
        return ranges

    def annots(self, pno):
        result = []
        for annot in self.doc[pno].annots(types=SUPPORTED):
            ranges = self.annot_ranges(pno, annot) if annot.vertices else []
            result.append(
                {
                    "page": pno,
                    "xref": annot.xref,
                    "type": annot.type[1],
                    "contents": annot.info.get("content", ""),
                    "ranges": ranges,
                    "anchor": [ranges[0][0], ranges[0][1]] if ranges else self.nearest_line(pno, annot.rect),
                }
            )
        return result

    def load_annot(self, pno, xref):
        # Annots only hold a weak page reference: callers must keep `page` alive.
        page = self.doc[pno]
        annot = page.load_annot(xref)
        if annot is None:
            raise ValueError("annotation %d not found on page %d" % (xref, pno + 1))
        return page, annot

    # ---- Annotation state -------------------------------------------------
    # Every annotation edit is also a set of raw PDF object changes. The
    # document keeps, per object it has seen, the original content (`base`) and
    # the content currently in `self.doc` (`live`), plus the /Annots array of
    # every page it touched. A state string is the delta of `live` against
    # `base` restricted to what the page arrays still reach: self-contained,
    # canonical (the same logical state always encodes identically) and
    # proportional to the annotations changed since open, not to the PDF.
    # `restore` rewrites only the objects where live and target differ.
    # Objects are never freed: MuPDF's own annotation delete only unlinks, so
    # an undone deletion brings back the very same objects, appearance
    # streams, popups and replies included.

    def read_object(self, xref):
        """Current Cap (source and raw stream) of `xref`, None if absent or freed."""
        doc = self.doc
        if not 1 <= xref < doc.xref_length():
            return None
        try:
            src = doc.xref_object(xref)
        except ValueError:
            return None
        if src.strip() == "null":
            return None
        cap = Cap(src, doc.xref_stream_raw(xref) if doc.xref_is_stream(xref) else None)
        encoded = self.encodings.get(xref)
        return encoded[1] if encoded and cap == encoded[0] else cap

    def read_annots(self, pno):
        """Source of the page's /Annots array, None when it has no such key."""
        kind, value = self.doc.xref_get_key(self.doc.page_xref(pno), "Annots")
        if kind == "xref":
            return self.doc.xref_object(int(value.split()[0]))
        return value if kind == "array" else None

    def write_annots(self, pno, source):
        page_xref = self.doc.page_xref(pno)
        kind, value = self.doc.xref_get_key(page_xref, "Annots")
        if source is None:
            # xref_set_key(..., "null") would leave /Annots null behind.
            pdf = pymupdf._as_pdf_document(self.doc)
            pymupdf.mupdf.pdf_dict_dels(pymupdf.mupdf.pdf_load_object(pdf, page_xref), "Annots")
        elif kind == "xref":
            self.doc.update_object(int(value.split()[0]), source)
        else:
            self.doc.xref_set_key(page_xref, "Annots", source)

    def write_object(self, xref, cap):
        doc = self.doc
        self.encodings.pop(xref, None)
        while doc.xref_length() <= xref:  # slot lost to a full rewrite
            doc.get_new_xref()
        doc.update_object(xref, cap.src)
        if cap.stream is not None:
            # update_stream() would drop /Filter; this keeps the raw bytes as stored.
            pdf = pymupdf._as_pdf_document(doc)
            buf = pymupdf.JM_BufferFromBytes(cap.stream)
            pymupdf.mupdf.pdf_update_stream(pdf, pymupdf.mupdf.pdf_new_indirect(pdf, xref, 0), buf, 1)

    def capture(self, roots):
        """Record what `roots` and everything they own or reference now hold."""
        todo, seen = list(roots), set()
        while todo:
            xref = todo.pop()
            if xref in seen or xref in self.opaque:
                continue
            seen.add(xref)
            cap = self.read_object(xref)
            info = parse_object(cap.src) if cap else None
            if info and info.opaque:
                self.opaque.add(xref)
                continue
            # Objects that predate the edit and were never seen are assumed
            # untouched by it; objects past the original table are new.
            self.base.setdefault(xref, None if xref >= self.open_len else cap)
            self.live[xref] = cap
            if info:
                todo.extend(info.follow)

    def ensure_page(self, pno):
        """Baseline a page before its first edit."""
        if pno not in self.base_pages:
            source = self.read_annots(pno)
            self.base_pages[pno] = self.live_pages[pno] = source
            self.capture(array_refs(source))

    @contextlib.contextmanager
    def edit(self, pno, targets=()):
        """Run a mutation of page `pno`, then record every object it changed:
        `targets` plus whatever entered or left the page's /Annots array."""
        self.ensure_page(pno)
        before = set(array_refs(self.live_pages[pno]))
        try:
            yield
        finally:
            self.live_pages[pno] = source = self.read_annots(pno)
            after = set(array_refs(source))
            self.capture(set(targets) | before ^ after)

    def refresh(self, after_save=False):
        """Track dropped objects after reopening. A save can re-encode surviving
        streams without an annotation edit; remember their previous identity so
        later captures do not turn that compression into an undo entry."""
        if after_save:
            self.encodings.clear()
        for xref, previous in self.live.items():
            current = self.read_object(xref)
            if after_save and previous is not None and current is not None:
                if current != previous:
                    self.encodings[xref] = (current, previous)
            else:
                self.live[xref] = current
        if not after_save:
            for pno in self.live_pages:
                self.live_pages[pno] = self.read_annots(pno)

    def state(self):
        pages = {
            str(pno): src for pno, src in self.live_pages.items() if not same_source(src, self.base_pages[pno])
        }
        objs = {}
        todo, seen = [x for src in self.live_pages.values() for x in array_refs(src)], set()
        while todo:
            xref = todo.pop()
            cap = self.live.get(xref)
            if xref in seen or cap is None:
                continue
            seen.add(xref)
            if cap != self.base.get(xref):
                stream = None if cap.stream is None else base64.b64encode(cap.stream).decode("ascii")
                objs[str(xref)] = [cap.src, stream]
            todo.extend(parse_object(cap.src).follow)
        payload = {"doc": self.nonce, "pages": pages, "objs": objs}
        raw = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        return STATE_PREFIX + base64.b64encode(zlib.compress(raw, 9)).decode("ascii")

    def decode_state(self, state):
        """(pages {pno: array source}, objs {xref: Cap}) of a state string."""
        try:
            if not state.startswith(STATE_PREFIX):
                raise ValueError
            payload = json.loads(zlib.decompress(base64.b64decode(state[len(STATE_PREFIX) :], validate=True)))
            pages = {int(pno): src for pno, src in payload["pages"].items()}
            objs = {
                int(xref): Cap(src, None if stream is None else base64.b64decode(stream))
                for xref, (src, stream) in payload["objs"].items()
            }
            nonce = payload["doc"]
        except (ValueError, KeyError, TypeError, AttributeError, zlib.error):
            raise ValueError("not an annotation state") from None
        if nonce != self.nonce:
            raise ValueError("annotation state belongs to another document session")
        if any(not 0 <= pno < len(self.doc) for pno in pages):
            raise ValueError("annotation state names a page this document lacks")
        return pages, objs

    def restore(self, state):
        """Make `self.doc` hold exactly the annotations of `state`."""
        pages, objs = self.decode_state(state)
        for pno in pages:
            self.ensure_page(pno)
        try:
            # An object the target does not list is back at its original content.
            for xref in set(self.live) | set(objs):
                cap = objs[xref] if xref in objs else self.base.get(xref)
                if cap is not None and self.live.get(xref) != cap:
                    self.write_object(xref, cap)
                    self.live[xref] = cap
            for pno in list(self.live_pages):
                source = pages.get(pno, self.base_pages[pno])
                if not same_source(self.live_pages[pno], source):
                    self.write_annots(pno, source)
                    self.live_pages[pno] = source
        except BaseException:
            self.refresh()
            raise

    def all_annots(self):
        return [a for pno in range(len(self.doc)) for a in self.annots(pno)]


def tint(pix, rect, matrix, color, outline=False):
    """Multiply-blend `color` over `rect` (page coords), optionally only its border."""
    outer = (rect * matrix).irect
    irect = outer & pix.irect
    if irect.is_empty:
        return
    sub = pymupdf.Pixmap(pix.colorspace, irect, False)
    sub.copy(pix, irect)
    sub.tint_with(0x000000, color)
    if outline:
        stroke = max(1, round(matrix.a * 0.7))
        inner = pymupdf.IRect(outer.x0 + stroke, outer.y0 + stroke, outer.x1 - stroke, outer.y1 - stroke) & irect
        if not inner.is_empty:
            sub.copy(pix, inner)
    pix.copy(sub, irect)


def render_clip(d, pno, clip, width, marks):
    clip = pymupdf.Rect(clip)
    zoom = width / clip.width
    matrix = pymupdf.Matrix(zoom, zoom)
    pix = d.doc[pno].get_pixmap(matrix=matrix, clip=clip, annots=True, alpha=False)
    for mark in marks or []:
        for lnum, cs, ce in mark["ranges"]:
            tint(pix, d.range_rect(lnum, cs, ce), matrix, mark["color"], mark.get("outline", False))
    return pix


GAP_COLOR = (48, 48, 48)
SCROLLBAR = {"track": (224, 224, 224), "tick": (96, 96, 96), "thumb": (80, 80, 80), "thumb_tick": (240, 240, 240)}


def page_heights(d, width):
    """Page heights in pixels when each page is scaled to `width` pixels."""
    return [page.rect.height * width / page.rect.width for page in d.doc]


def render_view(d, width, height, top, gap, marks):
    """The pages stacked at `width` px wide with `gap` px between them, cut
    from `top` px down `height` px. Marks tint only the page their lines are on."""
    out = pymupdf.Pixmap(pymupdf.csRGB, pymupdf.IRect(0, 0, width, height), False)
    # set_rect() loops over pixels in Python in PyMuPDF 1.26. The uniform gray
    # background can instead use clear_with() without a rectangle: a C bulk fill.
    out.clear_with(GAP_COLOR[0])
    y = 0.0
    for pno, h in enumerate(page_heights(d, width)):
        if y >= top + height:
            break
        if y + h > top:
            pw = d.doc[pno].rect.width
            scale = width / pw
            a, b = max(top, y), min(top + height, y + h)
            page_marks = []
            for mark in marks or []:
                ranges = [r for r in mark["ranges"] if d.info[r[0] - 1][0] == pno]
                if ranges:
                    page_marks.append({**mark, "ranges": ranges})
            pix = render_clip(d, pno, (0, (a - y) / scale, pw, (b - y) / scale), width, page_marks)
            pix.set_origin(0, round(a - top))
            out.copy(pix, pymupdf.IRect(pix.irect) & out.irect)
        y += h + gap
    return out


def scrollbar(pix, d, top, gap, width):
    """Document-wide scrollbar `width` px wide on the right edge of `pix`: the thumb
    is the visible part of the stacked pages, with ticks at page boundaries."""
    heights = page_heights(d, pix.width)
    total = sum(heights) + gap * (len(heights) - 1)
    h = pix.height
    ox = pix.width - width
    samples, stride = pix.samples_mv, pix.stride

    def bar(y0, y1, color, inset=0):
        # Both set_rect() and clear_with(bbox) loop over individual samples in
        # Python in PyMuPDF 1.26. Write whole RGB scanlines instead.
        rect = pymupdf.IRect(ox + inset, y0, ox + width - inset, y1) & pix.irect
        if rect.is_empty:
            return
        row = bytes(color) * rect.width
        offset = rect.y0 * stride + rect.x0 * 3
        for _ in range(rect.height):
            samples[offset : offset + len(row)] = row
            offset += stride

    bar(0, h, SCROLLBAR["track"])
    y0 = min(round(h * top / total), h - 6)
    y1 = min(max(y0 + 6, round(h * (top + h) / total)), h)
    bar(y0, y1, SCROLLBAR["thumb"], inset=2)
    # Ticks go over the thumb too, in a light colour there, so the boundaries of
    # the pages in view stay visible. Ticks closer than 3 thicknesses would merge
    # into a band; skip them.
    thick = max(2, round(width / 12))
    if h * min(heights) / total >= 3 * thick:
        y = 0
        for height in heights[:-1]:
            y += height + gap
            mid = round(h * y / total)
            on_thumb = y0 <= mid < y1
            bar(mid - thick // 2, mid - thick // 2 + thick, SCROLLBAR["thumb_tick" if on_thumb else "tick"], inset=2 if on_thumb else 0)


def m_open(p):
    d = Doc(p["path"])
    old = docs.pop(p["key"], None)
    if old:
        old.doc.close()
    docs[p["key"]] = d
    return {
        "lines": d.lines,
        "info": d.info,
        "pages": [[page.rect.width, page.rect.height] for page in d.doc],
        "annots": d.all_annots(),
        "state": d.state(),
    }


def m_close(p):
    d = docs.pop(p["key"], None)
    if d:
        d.doc.close()


def m_render(p):
    d = docs[p["key"]]
    pix = render_view(d, p["width"], p["height"], p["top"], p["gap"], p.get("marks"))
    if p.get("scrollbar"):
        scrollbar(pix, d, p["top"], p["gap"], p["scrollbar"])
    pix.save(p["out"])
    return {}


def m_annotate(p):
    d = docs[p["key"]]
    pno = d.ranges_page(p["ranges"])
    method, color = CREATE[p["kind"]]
    quads = [d.range_rect(*r).quad for r in p["ranges"]]
    with d.edit(pno):
        page = d.doc[pno]
        annot = getattr(page, method)(quads=quads)
        annot.set_colors(stroke=color)
        if p.get("contents"):
            annot.set_info(content=p["contents"])
        annot.update()
        xref = annot.xref
    return {"page": pno, "xref": xref, "annots": d.annots(pno), "state": d.state()}


def m_set_contents(p):
    d = docs[p["key"]]
    _page, annot = d.load_annot(p["page"], p["xref"])
    if annot.info.get("content", "") != p["contents"]:  # no change, no new state
        with d.edit(p["page"], [p["xref"]]):
            annot.set_info(content=p["contents"])
            annot.update()
    return {"page": p["page"], "annots": d.annots(p["page"]), "state": d.state()}


def m_delete(p):
    d = docs[p["key"]]
    page, annot = d.load_annot(p["page"], p["xref"])
    with d.edit(p["page"], [p["xref"]]):
        page.delete_annot(annot)
    return {"page": p["page"], "annots": d.annots(p["page"]), "state": d.state()}


def m_restore(p):
    """Put the document back into an annotation state returned earlier by this session."""
    d = docs[p["key"]]
    d.restore(p["state"])
    return {"state": p["state"], "annots": d.all_annots()}


def m_save(p):
    d = docs[p["key"]]
    target = p.get("path") or d.path
    if target != d.path:
        d.doc.save(target, garbage=1, deflate=True)
        return {"state": d.state()}
    if d.doc.can_save_incrementally():
        d.doc.save(d.path, incremental=True, encryption=pymupdf.PDF_ENCRYPT_KEEP)
    else:
        # Repaired or otherwise non-incremental documents: full rewrite.
        fd, tmp = tempfile.mkstemp(suffix=".pdf", dir=os.path.dirname(d.path))
        os.close(fd)
        try:
            d.doc.save(tmp, garbage=1, deflate=True)
            os.replace(tmp, d.path)
        except BaseException:
            os.unlink(tmp)
            raise
    # Reopen either way: later lazy object reads must hit the new file, and
    # MuPDF chains a second incremental update from the same open document
    # into a corrupt file. The rewrite also dropped unreferenced objects, so
    # re-read what the states track; `restore` revives what is gone.
    d.doc.close()
    d.doc = pymupdf.open(d.path)
    d.refresh(after_save=True)
    return {"state": d.state()}


def excerpt(text, limit=300):
    return text if len(text) <= limit else text[: limit - 1] + "…"


def m_snapshot(p):
    """PNG of the view plus a caption for agents: file, visible pages, notes on
    them, the selected text, and the cursor (p["cursor"]: [lnum, char index]).
    The image boxes the selection, or marks the cursor's character with a box
    and a small "x"."""
    d = docs[p["key"]]
    top, height, gap, width = p["top"], p["height"], p["gap"], p["width"]
    ranges = p.get("ranges") or []
    marks = [{"ranges": ranges, "color": p["color"]}] if ranges else []
    pix = render_view(d, width, height, top, gap, marks)

    shown, notes = {}, []  # page number -> its top in the image
    y = 0.0
    for pno, h in enumerate(page_heights(d, width)):
        if y >= top + height:
            break
        if y + h > top:
            shown[pno] = y - top
            pw = d.doc[pno].rect.width
            scale = width / pw
            clip = pymupdf.Rect(0, max(0, (top - y) / scale), pw, min(h, top + height - y) / scale)
            for annot in d.doc[pno].annots(types=SUPPORTED):
                text = annot.info.get("content", "").strip()
                if text and annot.rect.intersects(clip):
                    notes.append("<b>page %d %s note:</b> %s" % (pno + 1, annot.type[1], html.escape(text)))
        y += h + gap
    first, last = min(shown) + 1, max(shown) + 1
    pages = "page %d" % first if first == last else "pages %d–%d" % (first, last)
    rows = ["<b>%s</b>" % html.escape(d.path), "%s of %d" % (pages, len(d.doc))] + notes
    if ranges:
        text = " ".join(d.lines[lnum - 1][cs : ce + 1] for lnum, cs, ce in ranges)
        rows.append('selected on page %d: "%s"' % (d.info[ranges[0][0] - 1][0] + 1, html.escape(excerpt(text))))
    cursor = p.get("cursor")
    if cursor:
        lnum, ci = cursor
        line = d.lines[lnum - 1]
        ci = min(ci, len(line) - 1)
        before, after = line[max(0, ci - 30) : ci], line[ci + 1 : ci + 31]
        snippet = ("…" if ci > 30 else "") + before + "[" + line[ci] + "]" + after + ("…" if ci + 31 < len(line) else "")
        rows.append('cursor on page %d: "%s"' % (d.info[lnum - 1][0] + 1, html.escape(snippet)))

    w, h = pix.width, pix.height
    font = max(14, round(w / 80))
    out = pymupdf.open()
    page = out.new_page(width=w, height=h + 100 * font)
    page.insert_image(pymupdf.Rect(0, 0, w, h), pixmap=pix)

    def image_rect(lnum, chars):
        """Bounds in the image of characters `chars` of line `lnum`, None off view."""
        pno, boxes = d.info[lnum - 1][0], d.boxes[lnum - 1]
        chars = [ci for ci in chars if ci < len(boxes)]
        if pno not in shown or not chars:
            return None
        r = pymupdf.Rect(boxes[chars[0]])
        for ci in chars[1:]:
            r |= boxes[ci]
        return r * (width / d.doc[pno].rect.width) + (0, shown[pno], 0, shown[pno])

    lw = max(2, w / 800)
    if ranges:
        rects = [image_rect(lnum, range(cs, ce + 1)) for lnum, cs, ce in ranges]
        rects = [r for r in rects if r]
        if rects:
            r = rects[0]
            for other in rects[1:]:
                r |= other
            page.draw_rect((r + (-3 * lw, -3 * lw, 3 * lw, 3 * lw)) & pymupdf.Rect(0, 0, w, h), color=RED, width=lw)
    elif cursor:
        r = image_rect(cursor[0], [ci])
        if r:
            cursor_marker(page, r, lw, w, h)
    pad = font
    box = pymupdf.Rect(pad, h + pad, w - pad, page.rect.y1)
    spare, _ = page.insert_htmlbox(
        box,
        "<br>".join(rows),
        css="* {font-family: sans-serif; font-size: %dpx; white-space: pre-wrap; color: #222;}" % font,
        scale_low=1,
    )
    if spare < 0:
        raise ValueError("caption too long for the snapshot")
    page.set_cropbox(pymupdf.Rect(0, 0, w, box.y1 - spare + pad))
    page.draw_line((0, h), (w, h), color=(0.6, 0.6, 0.6), width=1)
    page.get_pixmap(alpha=False).save(p["out"])
    return {}


RED = (0.9, 0, 0)


def cursor_marker(page, char, lw, w, h):
    """Red box around `char` (image pixels) with diagonal arms about two line
    heights long from its corners, kept inside the w x h image."""
    r = char + (-2 * lw, -2 * lw, 2 * lw, 2 * lw)
    page.draw_rect(r, color=RED, width=lw)
    arm = 2 * char.height / math.sqrt(2)  # along each axis
    for x, y, sx, sy in ((r.x0, r.y0, -1, -1), (r.x1, r.y0, 1, -1), (r.x0, r.y1, -1, 1), (r.x1, r.y1, 1, 1)):
        reach = min(arm, w - x if sx > 0 else x, h - y if sy > 0 else y)
        if reach > 0:
            page.draw_line((x, y), (x + sx * reach, y + sy * reach), color=RED, width=lw)


def m_char_boxes(p):
    """[x0, y0, x1, y1] (page points) of each [lnum, char index] in p["chars"]."""
    d = docs[p["key"]]
    result = []
    for lnum, ci in p["chars"]:
        boxes = d.boxes[lnum - 1]
        result.append(list(boxes[min(ci, len(boxes) - 1)]))
    return result


def m_hit(p):
    """[lnum, char index] of the character nearest page point (x, y) on page
    p["page"], or None on a page without text. Vertical distance counts double,
    so a click between two lines picks the nearer line, not a far character."""
    d = docs[p["key"]]
    x, y = p["x"], p["y"]
    best = None
    for lnum in d.page_lines[p["page"]]:
        for ci, box in enumerate(d.boxes[lnum - 1]):
            dx = max(box.x0 - x, 0, x - box.x1)
            dy = max(box.y0 - y, 0, y - box.y1)
            dist = dx * dx + 4 * dy * dy
            if best is None or dist < best[0]:
                best = (dist, lnum, ci)
    return best and [best[1], best[2]]


METHODS = {
    "open": m_open,
    "close": m_close,
    "render": m_render,
    "annotate": m_annotate,
    "set_contents": m_set_contents,
    "delete": m_delete,
    "restore": m_restore,
    "save": m_save,
    "snapshot": m_snapshot,
    "char_boxes": m_char_boxes,
    "hit": m_hit,
}


def main():
    # Keep fd 1 for the protocol; anything MuPDF or Python prints goes to stderr.
    out = os.fdopen(os.dup(1), "w", encoding="utf-8")
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    pymupdf.TOOLS.mupdf_display_errors(False)
    for raw in sys.stdin:
        req = json.loads(raw)
        try:
            reply = {"id": req["id"], "result": METHODS[req["method"]](req.get("params") or {})}
        except Exception as e:
            traceback.print_exc()
            reply = {"id": req["id"], "error": "%s: %s" % (type(e).__name__, e)}
        out.write(json.dumps(reply) + "\n")
        out.flush()


if __name__ == "__main__":
    main()
