# /// script
# requires-python = ">=3.11"
# dependencies = ["playwright>=1.55,<2"]
# ///
"""The optional Chromium process, using the same line protocol as helper.py."""

import asyncio
import json
import os
from pathlib import Path
import sys
import traceback

from playwright.async_api import Error, async_playwright


class Document:
    def __init__(self, page):
        self.page = page
        self.press = None
        self.dragged = False

    async def layout(self, args):
        size = {axis: args[axis] for axis in ("width", "height")}
        if size != self.page.viewport_size:
            await self.page.set_viewport_size(size)
        return await self.page.evaluate("() => __pdfview.layout()")

    async def render(self, args):
        top = await self.page.evaluate("args => __pdfview.frame(args)", {
            "top": args["top"], "marks": args["marks"],
        })
        await self.page.screenshot(path=args["out"], type="png", scale="css")
        return {"top": top}

    async def char_boxes(self, args):
        return await self.page.evaluate("chars => __pdfview.boxes(chars)", args["chars"])

    async def pointer(self, args):
        point = (args["x"], args["y"])
        action = args["action"]
        mouse = self.page.mouse
        await mouse.move(*point)
        if self.press and any(abs(a - b) >= 4 for a, b in zip(self.press, point)):
            self.dragged = True
        if action == "down":
            if self.press is None:
                await mouse.down()
            self.press, self.dragged = point, False
        elif action == "up" and self.press is not None:
            # Compute the hit on the same document that received mouse-down.
            # Mouse-up can run JS, toggle <details>, or start navigation.
            hit = None
            try:
                if not self.dragged:
                    hit = await self.page.evaluate("([x, y]) => __pdfview.hit({x, y})", point)
            finally:
                self.press = None
                await mouse.up()
            return hit
        elif action == "wheel":
            await mouse.wheel(args.get("dx", 0), args.get("dy", 0))
        return None


class Backend:
    def __init__(self, chromium, emit):
        self.chromium, self.emit = chromium, emit
        self.browser = None
        self.docs = {}

    async def launch(self):
        errors = []
        for channel in ("chrome", None):
            try:
                self.browser = await self.chromium.launch(channel=channel, chromium_sandbox=True)
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
            viewport={axis: args[axis] for axis in ("width", "height")},
            accept_downloads=False,
        )
        try:
            await context.add_init_script(path=Path(__file__).with_suffix(".js"))
            page = await context.new_page()
            doc = Document(page)

            def changed(source):
                if self.docs.get(key) is doc and source["frame"] == page.main_frame:
                    self.emit({"event": "change", "key": key})

            await page.expose_binding("__pdfviewChanged", changed)
            # Also catch full navigation and hash links, which can otherwise
            # replace the old DOM without a mutation being observed.
            page.on("framenavigated", lambda frame: changed({"frame": frame}))
            page.on("domcontentloaded", lambda: changed({"frame": page.main_frame}))
            await page.goto(path.as_uri(), wait_until="load")
            await page.evaluate("() => document.fonts.ready.then(() => null)")
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
        if method not in {"layout", "render", "char_boxes", "pointer"}:
            raise ValueError(f"Unknown method: {method}")
        return await getattr(self.docs[args["key"]], method)(args)


async def main():
    out = os.fdopen(os.dup(1), "w", encoding="utf-8", buffering=1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr

    def emit(message):
        out.write(json.dumps(message, separators=(",", ":"), ensure_ascii=False) + "\n")

    async with async_playwright() as playwright:
        backend = Backend(playwright.chromium, emit)
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
