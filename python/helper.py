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
"""

import html
import json
import os
import sys
import tempfile
import traceback

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
SCROLLBAR = {"track": (224, 224, 224), "tick": (160, 160, 160), "thumb": (80, 80, 80)}


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


def scrollbar(pix, d, top, gap):
    """Document-wide scrollbar on the right edge of `pix`: the thumb is the visible
    part of the stacked pages, with ticks at page boundaries."""
    heights = page_heights(d, pix.width)
    total = sum(heights) + gap * (len(heights) - 1)
    h = pix.height
    width = max(12, pix.width // 60)
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
    # Ticks closer than 3px would merge into a solid band; skip them.
    if h * min(heights) / total >= 3:
        y = 0
        for height in heights[:-1]:
            y += height + gap
            tick = round(h * y / total)
            bar(tick, tick + 1, SCROLLBAR["tick"])
    y0 = min(round(h * top / total), h - 6)
    y1 = min(max(y0 + 6, round(h * (top + h) / total)), h)
    bar(y0, y1, SCROLLBAR["thumb"], inset=2)


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
        "annots": [a for pno in range(len(d.doc)) for a in d.annots(pno)],
    }


def m_close(p):
    d = docs.pop(p["key"], None)
    if d:
        d.doc.close()


def m_render(p):
    d = docs[p["key"]]
    pix = render_view(d, p["width"], p["height"], p["top"], p["gap"], p.get("marks"))
    if p.get("scrollbar"):
        scrollbar(pix, d, p["top"], p["gap"])
    pix.save(p["out"])
    return {}


def m_annotate(p):
    d = docs[p["key"]]
    pno = d.ranges_page(p["ranges"])
    method, color = CREATE[p["kind"]]
    quads = [d.range_rect(*r).quad for r in p["ranges"]]
    page = d.doc[pno]
    annot = getattr(page, method)(quads=quads)
    annot.set_colors(stroke=color)
    if p.get("contents"):
        annot.set_info(content=p["contents"])
    annot.update()
    return {"page": pno, "xref": annot.xref, "annots": d.annots(pno)}


def m_set_contents(p):
    d = docs[p["key"]]
    _page, annot = d.load_annot(p["page"], p["xref"])
    annot.set_info(content=p["contents"])
    annot.update()
    return {"page": p["page"], "annots": d.annots(p["page"])}


def m_delete(p):
    d = docs[p["key"]]
    page, annot = d.load_annot(p["page"], p["xref"])
    page.delete_annot(annot)
    return {"page": p["page"], "annots": d.annots(p["page"])}


def m_save(p):
    d = docs[p["key"]]
    target = p.get("path") or d.path
    if target != d.path:
        d.doc.save(target, garbage=1, deflate=True)
        return {}
    if d.doc.can_save_incrementally():
        d.doc.save(d.path, incremental=True, encryption=pymupdf.PDF_ENCRYPT_KEEP)
        return {}
    # Repaired or otherwise non-incremental documents: full rewrite, then
    # reopen so later lazy object reads hit the new file.
    fd, tmp = tempfile.mkstemp(suffix=".pdf", dir=os.path.dirname(d.path))
    os.close(fd)
    try:
        d.doc.save(tmp, garbage=1, deflate=True)
        os.replace(tmp, d.path)
    except BaseException:
        os.unlink(tmp)
        raise
    d.doc.close()
    d.doc = pymupdf.open(d.path)
    return {}


def m_snapshot(p):
    d = docs[p["key"]]
    top, height, gap, width = p["top"], p["height"], p["gap"], p["width"]
    ranges = p.get("ranges") or []
    marks = [{"ranges": ranges, "color": p["color"]}] if ranges else []
    pix = render_view(d, width, height, top, gap, marks)

    rows = ["<b>%s</b>" % html.escape(d.path)]
    y = 0.0
    for pno, h in enumerate(page_heights(d, width)):
        if y >= top + height:
            break
        if y + h > top:
            pw = d.doc[pno].rect.width
            scale = width / pw
            clip = pymupdf.Rect(0, max(0, (top - y) / scale), pw, min(h, top + height - y) / scale)
            rows.append("page %d of %d · view %s pt" % (pno + 1, len(d.doc), fmt_rect(clip)))
            for annot in d.doc[pno].annots(types=SUPPORTED):
                text = annot.info.get("content", "").strip()
                if text and annot.rect.intersects(clip):
                    rows.append("<b>page %d %s note:</b> %s" % (pno + 1, annot.type[1], html.escape(text)))
        y += h + gap
    if ranges:
        sel = d.range_rect(*ranges[0])
        for r in ranges[1:]:
            sel |= d.range_rect(*r)
        rows.append("selection on page %d: %s pt" % (d.info[ranges[0][0] - 1][0] + 1, fmt_rect(sel)))

    w, h = pix.width, pix.height
    font = max(14, round(w / 80))
    out = pymupdf.open()
    page = out.new_page(width=w, height=h + 100 * font)
    page.insert_image(pymupdf.Rect(0, 0, w, h), pixmap=pix)
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


def fmt_rect(r):
    return "(%.0f, %.0f)–(%.0f, %.0f)" % (r.x0, r.y0, r.x1, r.y1)


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
