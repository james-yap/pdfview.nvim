# /// script
# requires-python = ">=3.11"
# dependencies = ["playwright>=1.55,<2", "pymupdf>=1.26,<1.27"]
# ///
"""The optional Chromium process, using the same line protocol as helper.py."""

import asyncio
from base64 import b64decode, b64encode
from collections import OrderedDict
from html import escape
import json
from math import ceil, sqrt
import os
from pathlib import Path
import sys
import traceback

import pymupdf
from playwright.async_api import Error, async_playwright

from scrollbar import Scrollbar

RASTER_CACHE_BYTES = 128 * 1024**2


async def set_viewport(cdp, width, height, scale):
    # Keep CSS pixels logical but render at the terminal's backing resolution.
    # Do not resize Chrome's native window: its minimum size can race emulation.
    css_width, css_height = ceil(width / scale), ceil(height / scale)
    await cdp.send("Emulation.setDeviceMetricsOverride", {
        "width": css_width, "height": css_height, "deviceScaleFactor": scale, "mobile": False,
    })
    return css_width, css_height


def paint_marks(pix, clip, layers, scale):
    if not layers:
        return
    with pymupdf.open() as doc:
        page = doc.new_page(width=clip.width, height=clip.height)
        shape = page.new_shape()
        for mark, boxes in layers:
            rgb = mark["color"]
            color = tuple((rgb >> shift & 255) / 255 for shift in (16, 8, 0))
            outline = mark.get("outline")
            for box in boxes:
                rect = pymupdf.Rect(box) & clip
                if not rect.is_empty:
                    shape.draw_rect(rect - (clip.x0, clip.y0, clip.x0, clip.y0))
            if shape.draw_cont:
                shape.finish(color=color if outline else None, fill=None if outline else color,
                             fill_opacity=0.45, width=scale)
        shape.commit()
        mupdf = pymupdf.mupdf
        device = mupdf.fz_new_draw_device(mupdf.FzMatrix(), pix.this)
        mupdf.fz_run_page(pymupdf._as_fz_page(page), device, mupdf.FzMatrix(), mupdf.FzCookie())
        mupdf.fz_close_device(device)


def snapshot_marker(box, selection, width, height):
    """Match the PDF snapshot: a padded selection box or a short diagonal X."""
    if box is None:
        return ""
    x0, y0, x1, y1 = box
    stroke = max(2, width / 800)
    pad = (3 if selection else 2) * stroke
    arm = 4 * (y1 - y0) / sqrt(2)
    x0, y0, x1, y1 = x0 - pad, y0 - pad, x1 + pad, y1 + pad
    if selection:
        x0, y0, x1, y1 = max(0, x0), max(0, y0), min(width, x1), min(height, y1)
    shapes = [f'<rect x="{x0}" y="{y0}" width="{x1 - x0}" height="{y1 - y0}"/>']
    if not selection:
        for x, y, sx, sy in ((x0, y0, -1, -1), (x1, y0, 1, -1), (x0, y1, -1, 1), (x1, y1, 1, 1)):
            reach = min(arm, width - x if sx > 0 else x, height - y if sy > 0 else y)
            if reach > 0:
                shapes.append(f'<line x1="{x}" y1="{y}" x2="{x + sx * reach}" y2="{y + sy * reach}"/>')
    return (f'<svg viewBox="0 0 {width} {height}" fill="none" stroke="#e60000" stroke-width="{stroke}">'
            f'{"".join(shapes)}</svg>')


class Document:
    def __init__(self, page, cdp):
        self.page = page
        self.cdp = cdp
        self.size = None
        self.strips = OrderedDict()

    async def resize(self, args):
        size = (args["width"], args["height"], args["scale"])
        if size != self.size:
            self.css_size = await set_viewport(self.cdp, *size)
            self.size = size

    async def layout(self, args):
        await self.resize(args)
        layout = await self.page.evaluate("() => __pdfview.layout()")
        width, height, scale = self.size
        css_width, css_height = self.css_size
        # Ceil the CSS viewport to cover odd backing dimensions, but do not
        # make the excess backing pixels reachable unless the document overflows.
        layout["total"] = self.total = height if layout["total"] <= css_height else layout["total"] * scale
        layout["wide"] = self.wide = width if layout["wide"] <= css_width else layout["wide"] * scale
        self.strips.clear()
        self.cache_bytes = 0
        self.spans = None
        self.bar = Scrollbar()
        return layout

    async def geometry(self, args):
        if self.spans is None:
            self.spans = await self.page.evaluate("() => __pdfview.geometry()")
            scale = self.size[2]
            if scale != 1:
                for line in self.spans:
                    for span in line:
                        span[2] *= scale
                        span[3] *= scale
        return self.spans

    async def strip(self, left, y, width, height):
        key = (left, y, width)
        if key in self.strips:
            self.strips.move_to_end(key)
            return self.strips[key]
        frame = await self.cdp.send("Page.captureScreenshot", {
            "format": "png",
            "optimizeForSpeed": True,
            "captureBeyondViewport": True,
            "clip": {"x": left, "y": y, "width": width, "height": height, "scale": 1},
        })
        pix = pymupdf.Pixmap(b64decode(frame["data"]))
        if pix.alpha:
            pix = pymupdf.Pixmap(pix, 0)
        size = pix.stride * pix.height
        while self.cache_bytes + size > RASTER_CACHE_BYTES and self.strips:
            _, old = self.strips.popitem(last=False)
            self.cache_bytes -= old.stride * old.height
        self.strips[key] = pix
        self.cache_bytes += size
        return pix

    def pixel_boxes(self, boxes):
        scale = self.size[2]
        if scale == 1:
            return boxes
        return [[n * scale for n in box] if box is not None else None for box in boxes]

    async def rectangles(self, ranges):
        return self.pixel_boxes(await self.page.evaluate("ranges => __pdfview.rectangles(ranges)", ranges))

    async def frame(self, args, marks, bar=None):
        width, height, scale = self.size
        top = min(max(0, args["top"]), max(0, self.total - height))
        left = min(max(0, args["left"]), max(0, self.wide - width))
        clip = pymupdf.Rect(left, top, left + width, top + height)
        pix = pymupdf.Pixmap(pymupdf.csRGB, (0, 0, width + (bar["width"] if bar else 0), height), False)
        # Chromium captures whole CSS pixels. Align the strips to that grid
        # and crop the backing pixels when panning or sizing the terminal.
        strip_height = min(self.css_size[1], max(1, RASTER_CACHE_BYTES // (4 * width * scale * 3)))
        start_x, inset = divmod(left, scale)
        strip_width = ceil((width + inset) / scale)
        bottom = ceil(self.total / scale)
        for y in range(top // (strip_height * scale) * strip_height, ceil((top + height) / scale), strip_height):
            strip = await self.strip(start_x, y, strip_width, min(strip_height, bottom - y))
            offset = y * scale - top
            strip.set_origin(-inset, offset)
            pix.copy(strip, (0, max(0, offset), width, min(height, offset + strip.height)))
        paint_marks(pix, clip, await self.layers(marks), scale)
        if bar:
            self.bar.draw(pix, top, self.total, bar, self.line_y, version=self.spans is not None)
        return pix, clip

    async def layers(self, marks):
        if not marks:
            return []
        boxes = await self.page.evaluate(
            "groups => groups.map(ranges => __pdfview.rectangles(ranges))",
            [mark["ranges"] for mark in marks],
        )
        return ((mark, self.pixel_boxes(group)) for mark, group in zip(marks, boxes))

    def line_y(self, lnum):
        if self.spans is not None and 1 <= lnum <= len(self.spans) and self.spans[lnum - 1]:
            _, _, y0, y1 = self.spans[lnum - 1][0]
            return (y0 + y1) / 2

    async def render(self, args):
        pix, _ = await self.frame(args, args["marks"], args.get("scrollbar"))
        with open(args["out"], "wb") as f:
            f.write(pix.samples_mv)
        return {}

    async def snapshot(self, args):
        ranges = args.get("ranges")
        marks = [{"ranges": ranges, "color": args["color"]}] if ranges else []
        pix, clip = await self.frame(args, marks)
        box = pymupdf.Rect()
        if not ranges and (cursor := args.get("cursor")):
            ranges = [[cursor[0], cursor[1], cursor[1]]]
        if ranges:
            for rect in await self.rectangles(ranges):
                visible = pymupdf.Rect(rect) & clip
                if not visible.is_empty:
                    box |= visible
        width, height, scale = self.size
        marker = snapshot_marker(None if box.is_empty else box - (clip.x0, clip.y0, clip.x0, clip.y0),
                                 bool(marks), width, height)
        png = b64encode(pix.tobytes()).decode("ascii")
        # Compose the caption away from the document to preserve its viewport
        # and prevent the document's styles/scripts from changing the caption.
        caption = await self.page.context.new_page()
        try:
            # Compose in backing pixels so the captured frame is not resampled.
            await set_viewport(await caption.context.new_cdp_session(caption), width, height, 1)
            await caption.set_content(f"""
                <!doctype html><meta charset="utf-8">
                <style>
                    body {{margin:0; color:#222; background:white;
                           font:clamp({14 * scale}px,1.25vw,{24 * scale}px) sans-serif}}
                    .frame {{position:relative; overflow:hidden}}
                    img {{display:block; width:100%}}
                    svg {{position:absolute; inset:0; width:100%; height:100%}}
                    footer {{border-top:1px solid #999; padding:1em; overflow-wrap:anywhere; white-space:pre-wrap}}
                </style>
                <div class="frame"><img src="data:image/png;base64,{png}">{marker}</div>
                <footer><b>{escape(self.page.url)}</b>{escape(args.get("caption", ""))}</footer>
            """)
            await caption.screenshot(path=args["out"], full_page=True)
        finally:
            await caption.close()
        return {}

    async def char_boxes(self, args):
        return self.pixel_boxes(await self.page.evaluate("chars => __pdfview.boxes(chars)", args["chars"]))


class Backend:
    def __init__(self, chromium):
        self.chromium = chromium
        self.browser = None
        self.docs = {}

    async def launch(self):
        errors = []
        for channel in ("chrome", None):
            try:
                self.browser = await self.chromium.launch(
                    channel=channel, chromium_sandbox=True,
                    args=["--blink-settings=imageAnimationPolicy=2"],
                )
                return
            except Error as exc:
                errors.append(str(exc))
        print("\n".join(errors), file=sys.stderr)
        script = Path(__file__).resolve()
        raise RuntimeError(f'Chromium could not start. Install Google Chrome or run uv run --script "{script}" --install-chromium')

    async def open(self, args):
        path = Path(args["path"]).resolve(strict=True)
        if not path.is_file():
            raise ValueError(f"Not a file: {path}")
        if self.browser is None or not self.browser.is_connected():
            await self.launch()
        key = args["key"]
        await self.close(key)
        context = await self.browser.new_context(
            no_viewport=True,
            java_script_enabled=False,
            accept_downloads=False,
        )
        try:
            await context.add_init_script(path=Path(__file__).with_suffix(".js"))
            page = await context.new_page()
            doc = Document(page, await context.new_cdp_session(page))
            await doc.resize(args)

            initial = True
            url = path.as_uri()

            async def route_request(route):
                nonlocal initial
                if route.request.is_navigation_request():
                    if initial and route.request.url == url:
                        initial = False
                        # A response sandbox also blocks automatic navigation to
                        # about:blank and other URLs that never reach the router.
                        await route.fulfill(path=path, headers={
                            "content-type": "text/html",
                            "content-security-policy": "sandbox allow-same-origin; frame-src 'none'; object-src 'none'",
                        })
                    else:
                        await route.abort()
                    return
                await route.continue_()

            await page.route("**/*", route_request)
            await page.goto(url, wait_until="load")
            await doc.cdp.send("Emulation.setScrollbarsHidden", {"hidden": True})
            await page.evaluate("() => __pdfview.freeze()")
            result = await doc.layout(args)
            self.docs[key] = doc
            return result
        except BaseException:
            await context.close()
            raise

    async def close(self, key):
        doc = self.docs.pop(key, None)
        if doc and self.browser.is_connected():
            await doc.page.context.close()

    async def dispatch(self, method, args):
        if method == "open":
            return await self.open(args)
        if method == "close":
            return await self.close(args["key"])
        if method not in {"layout", "geometry", "render", "snapshot", "char_boxes"}:
            raise ValueError(f"Unknown method: {method}")
        return await getattr(self.docs[args["key"]], method)(args)


async def main():
    out = os.fdopen(os.dup(1), "w", encoding="utf-8", buffering=1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr

    def emit(message):
        out.write(json.dumps(message, separators=(",", ":"), ensure_ascii=False) + "\n")

    async with async_playwright() as playwright:
        backend = Backend(playwright.chromium)
        try:
            while raw := await asyncio.to_thread(sys.stdin.readline):
                request = json.loads(raw)
                reply = {"id": request["id"]}
                try:
                    reply["result"] = await backend.dispatch(request["method"], request.get("params", {}))
                except Exception as exc:
                    traceback.print_exc()
                    reply["error"] = f"{type(exc).__name__}: {exc}"
                emit(reply)
        finally:
            if backend.browser:
                await backend.browser.close()


if __name__ == "__main__":
    if sys.argv[1:] == ["--install-chromium"]:
        os.execv(sys.executable, [sys.executable, "-m", "playwright", "install", "chromium"])
    asyncio.run(main())
