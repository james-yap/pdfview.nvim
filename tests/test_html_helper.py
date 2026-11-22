"""Run with the HTML helper's Playwright and PyMuPDF dependencies."""

from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))
import html_helper as html


class StaticHtmlTest(unittest.IsolatedAsyncioTestCase):
    async def test_inert_pixels_and_text_reflow_across_strip_edges(self):
        async with html.async_playwright() as playwright:
            backend = html.Backend(playwright.chromium)
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "read only.html"
                path.write_text('''<!doctype html><meta charset="utf-8">
                    <meta http-equiv="refresh" content="0;url=about:blank">
                    <script>document.title = 'script ran'</script>
                    <style>
                    body { margin: 0 }
                    section { height: 100vh }
                    #first { background: red }
                    #second { background: blue }
                    #last { background: green; height: 50px }
                    #pinned { position: fixed; top: 0; height: 40px; background: gold }
                    #reflow { width: 100px; font: 14px monospace }
                    @media (min-width: 250px) { #pinned { position: static } #reflow { width: 300px } }
                    </style>
                    <section id="first"><details><summary>Answer</summary>hidden answer</details></section>
                    <div id="pinned">Pinned text</div>
                    <section id="second"><div id="reflow">one two three four five six seven eight nine ten</div></section>
                    <section id="last">Ending</section>''', encoding="utf-8")
                try:
                    layout = await backend.open(dict(key=1, path=str(path), width=220, height=120))
                    doc = backend.docs[1]
                    self.assertEqual(await doc.page.title(), "")
                    await doc.page.mouse.click(20, 9)
                    self.assertEqual(layout["lines"][:2], ["Answer", "Pinned text"])
                    self.assertFalse(await doc.page.locator("details").evaluate("element => element.open"))

                    bare, _ = await doc.frame(dict(top=110, left=0), [])
                    self.assertEqual([bare.pixel(200, y) for y in (9, 10, 49, 50, 119)], [
                        (255, 0, 0), (255, 215, 0), (255, 215, 0), (0, 0, 255), (0, 0, 255),
                    ])
                    line = layout["lines"].index("one two three four five six seven eight nine ten") + 1
                    wrapped = (await doc.geometry({}))[line - 1]
                    box = (await doc.char_boxes(dict(chars=[[line, 0]])))[0]
                    x, y = int((box[0] + box[2]) / 2), int((box[1] + box[3]) / 2) - 110
                    marked, _ = await doc.frame(dict(top=110, left=0), [dict(ranges=[[line, 0, 0]], color=0xFFFF00)])
                    self.assertNotEqual(marked.pixel(x, y), bare.pixel(x, y))
                    restored, _ = await doc.frame(dict(top=110, left=0), [])
                    self.assertEqual(restored.samples, bare.samples)

                    await doc.layout(dict(width=340, height=150))
                    reflowed = (await doc.geometry({}))[line - 1]
                    self.assertLess(len(reflowed), len(wrapped))
                    self.assertAlmostEqual(reflowed[0][2] - wrapped[0][2], 30)
                    resized, _ = await doc.frame(dict(top=140, left=0), [])
                    self.assertEqual(resized.pixel(200, 50), (0, 0, 255))
                    end, _ = await doc.frame(dict(top=9999, left=0), [])
                    self.assertEqual(end.pixel(200, end.height - 1), (0, 128, 0))

                    snapshot = path.with_suffix(".png")
                    await doc.snapshot(dict(top=140, left=0, ranges=[[line, 0, 2]], color=0xFFFF00,
                                            caption="Selection context", out=str(snapshot)))
                    self.assertGreater(html.pymupdf.Pixmap(snapshot).height, resized.height)
                finally:
                    if backend.browser:
                        await backend.browser.close()


if __name__ == "__main__":
    unittest.main()
