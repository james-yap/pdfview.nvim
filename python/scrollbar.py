"""Rasterize the document scrollbar shared by the PDF and HTML viewers."""

import pymupdf


GAP_COLOR = (48, 48, 48)
SCROLLBAR = {
    "track": tuple(c / 255 for c in GAP_COLOR),
    "page": (0.36, 0.36, 0.36),
    "thumb": (1, 1, 1),
    "search": (1, 0.62, 0.26),
    "cursor": (0.54, 0.72, 1),
    "mark": (0.9, 0.9, 0.9),
    "mark_text": (0.1, 0.1, 0.12),
}


def rect(shape, x0, x1, ys, color, r=0):
    y0, y1 = round(ys[0]), max(round(ys[1]), round(ys[0]) + 1)  # crisp whole pixels
    shape.draw_rect(pymupdf.Rect(x0, y0, x1, y1), radius=(r / (x1 - x0), r / (y1 - y0)) if r else None)
    shape.finish(fill=color, color=None)


class Scrollbar:
    def __init__(self):
        self.cache = None  # Track and markers, without the moving thumb and cursor.

    def draw(self, pix, top, total, bar, line_y, *, version=None, extra=None):
        """Overlay the bar on `pix`. `line_y` maps buffer lines to document pixels.

        `extra` paints format-specific track markers and runs only on a cache miss.
        Change `version` when the mapping or those markers change.
        """
        bw, h = bar["width"], pix.height
        scale = h / max(1, total)

        def span(y0, y1, least):
            grow = max(0, min(h, least) - (y1 - y0)) / 2
            y0, y1 = y0 - grow, y1 + grow
            shift = max(0, -y0) - max(0, y1 - h)
            return y0 + shift, y1 + shift

        def line(lnum, size):
            y = line_y(lnum)
            return None if y is None else span(y * scale, y * scale, size)

        mid, pill = bw / 2, max(10, bw * 0.9)
        search, marks = bar.get("search", []), bar.get("marks", [])
        key = (bw, h, total, version, search, marks)
        if self.cache is None or self.cache[0] != key:
            with pymupdf.open() as doc:
                page = doc.new_page(width=bw, height=h)
                shape = page.new_shape()
                rect(shape, 0, bw, (0, h), SCROLLBAR["track"])
                if extra:
                    extra(shape, scale, span)
                tick = max(2, bw / 10)
                for lnum in search:
                    if (ys := line(lnum, tick)) is not None:
                        rect(shape, mid + 1, bw - 2, ys, SCROLLBAR["search"])
                labels = []
                for name, lnum in marks:
                    if (ys := line(lnum, pill)) is not None:
                        rect(shape, 1, bw - 1, ys, SCROLLBAR["mark"], r=pill / 2.5)
                        labels.append((name, sum(ys) / 2))
                shape.commit()
                size = pill * 0.68
                for name, y in labels:
                    x = (bw - pymupdf.get_text_length(name, "hebo", size)) / 2
                    page.insert_text((x, y + size * 0.36), name, fontsize=size, fontname="hebo", color=SCROLLBAR["mark_text"])
                self.cache = (key, page.get_pixmap(alpha=False))

        strip = pymupdf.Pixmap(self.cache[1], 0)
        # Paint the thumb and cursor on top of the track with all its markers.
        with pymupdf.open() as doc:
            page = doc.new_page(width=bw, height=h)
            shape = page.new_shape()
            y0, y1 = span(top * scale, min(top + h, total) * scale, pill + 6)
            shape.draw_rect(pymupdf.Rect(1, y0 + 0.5, bw - 1, y1 - 0.5), radius=(4 / (bw - 2), 4 / (y1 - y0)))
            shape.finish(fill=SCROLLBAR["thumb"], fill_opacity=0.2, color=SCROLLBAR["cursor"], width=1.5)
            if bar.get("cursor") and (ys := line(bar["cursor"], max(3, bw / 6) + 2)) is not None:
                y0, y1 = ys
                rect(shape, 0, bw, ys, SCROLLBAR["track"])
                rect(shape, 0, bw, (y0 + 1, y1 - 1), SCROLLBAR["cursor"])
            shape.commit()
            # Rasterize over the existing pixels: only painted vectors cover them.
            mupdf = pymupdf.mupdf
            dev = mupdf.fz_new_draw_device(mupdf.FzMatrix(), strip.this)
            mupdf.fz_run_page(pymupdf._as_fz_page(page), dev, mupdf.FzMatrix(), mupdf.FzCookie())
            mupdf.fz_close_device(dev)
        strip.set_origin(pix.width - bw, 0)
        pix.copy(strip, strip.irect)
