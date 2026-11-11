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


def tint(pix, rect, matrix, color):
    """Multiply-blend `color` over `rect` (page coords): white turns `color`, ink stays dark."""
    irect = (rect * matrix).irect & pix.irect
    if irect.is_empty:
        return
    sub = pymupdf.Pixmap(pix.colorspace, irect, False)
    sub.copy(pix, irect)
    sub.tint_with(0x000000, color)
    pix.copy(sub, irect)


def render_clip(d, pno, clip, width, marks):
    clip = pymupdf.Rect(clip)
    zoom = width / clip.width
    matrix = pymupdf.Matrix(zoom, zoom)
    pix = d.doc[pno].get_pixmap(matrix=matrix, clip=clip, annots=True, alpha=False)
    for mark in marks or []:
        for lnum, cs, ce in mark["ranges"]:
            tint(pix, d.range_rect(lnum, cs, ce), matrix, mark["color"])
    return pix


SCROLLBAR = {"track": (232, 232, 232), "tick": (176, 176, 176), "thumb": (110, 110, 110)}


def scrollbar(pix, d, pno, clip):
    """Document-wide scrollbar on the right edge of `pix`: the thumb is the visible
    part of the whole PDF (pages stacked), with ticks at page boundaries."""
    clip = pymupdf.Rect(clip)
    heights = [page.rect.height for page in d.doc]
    total = sum(heights)
    h = pix.height
    width = max(6, pix.width // 160)
    # A clipped pixmap keeps the clip's pixel origin; set_rect takes those coordinates.
    ox, oy = pix.x + pix.width - width, pix.y

    def bar(y0, y1, color, inset=0):
        pix.set_rect(pymupdf.IRect(ox + inset, oy + y0, ox + width - inset, oy + y1), color)

    bar(0, h, SCROLLBAR["track"])
    # Ticks closer than 3px would merge into a solid band; skip them.
    if h * min(heights) / total >= 3:
        top = 0
        for height in heights[:-1]:
            top += height
            y = round(h * top / total)
            bar(y, y + 1, SCROLLBAR["tick"])
    start = sum(heights[:pno]) + clip.y0
    y0 = min(round(h * start / total), h - 4)
    y1 = min(max(y0 + 4, round(h * (start + clip.height) / total)), h)
    bar(y0, y1, SCROLLBAR["thumb"], inset=1)


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
    pix = render_clip(d, p["page"], p["clip"], p["width"], p.get("marks"))
    if p.get("scrollbar"):
        scrollbar(pix, d, p["page"], p["clip"])
    pix.save(p["out"])
    return {"width": pix.width, "height": pix.height}


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
    pno, clip, ranges = p["page"], pymupdf.Rect(p["clip"]), p.get("ranges") or []
    marks = [{"ranges": ranges, "color": p["color"]}] if ranges else []
    pix = render_clip(d, pno, clip, p["width"], marks)

    rows = [
        "<b>%s</b>" % html.escape(d.path),
        "page %d of %d · view %s pt" % (pno + 1, len(d.doc), fmt_rect(clip)),
    ]
    if ranges:
        sel = d.range_rect(*ranges[0])
        for r in ranges[1:]:
            sel |= d.range_rect(*r)
        rows.append("selection %s pt" % fmt_rect(sel))
    for annot in d.doc[pno].annots(types=SUPPORTED):
        text = annot.info.get("content", "").strip()
        if text and annot.rect.intersects(clip):
            rows.append("<b>%s note:</b> %s" % (annot.type[1], html.escape(text)))

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
