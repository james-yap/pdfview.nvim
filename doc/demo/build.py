# /// script
# requires-python = ">=3.11"
# dependencies = ["pymupdf>=1.26,<1.27", "typst>=0.15,<0.16"]
# ///
"""Build doc/demo/notes.pdf: compile notes.typ, then add annotations in assorted
colours, as if made in another PDF reader, so the page and scrollbar look lived-in.

    uv run --script doc/demo/build.py
"""
from pathlib import Path

import pymupdf
import typst

HERE = Path(__file__).parent
BLUE, GREEN, PINK, PURPLE, ORANGE = (0.62, 0.8, 1), (0.62, 0.93, 0.58), (1, 0.72, 0.85), (0.6, 0.45, 0.95), (1, 0.55, 0.15)

# (page, text, kind, colour, note). Keep clear of the phrases the clips annotate
# themselves: "light string", "simple harmonic", "vertical".
PLAN = [
    (0, "Newton’s second law", "highlight", BLUE, ""),
    (0, "good clocks", "highlight", GREEN, "Huygens built the first pendulum clock in 1656."),
    (0, "does not depend on the mass", "underline", PURPLE, ""),
    (0, "inertial force", "squiggly", ORANGE, ""),
    (1, "roughly a tenth of", "highlight", PINK, ""),
    (1, "film the pendulum", "highlight", BLUE, "Try a slow-motion video at 240 fps."),
    (1, "timed ten swings", "underline", GREEN, ""),
    (1, "Ten-swing times", "highlight", GREEN, ""),
    (1, "cannot tell a steadily moving lift", "highlight", PURPLE, "Equivalence principle, in miniature."),
    (2, "cable breaks", "highlight", PINK, ""),
]

doc = pymupdf.open(stream=typst.compile(str(HERE / "notes.typ")), filetype="pdf")
for pno, text, kind, color, note in PLAN:
    page = doc[pno]
    quads = page.search_for(text, quads=True)
    assert quads, f"not found on page {pno + 1}: {text}"
    add = {"highlight": page.add_highlight_annot, "underline": page.add_underline_annot,
           "squiggly": page.add_squiggly_annot}[kind]
    annot = add(quads[0])
    annot.set_colors(stroke=color)
    if note:
        annot.set_info(content=note)
    annot.update()
doc.save(HERE / "notes.pdf", garbage=3, deflate=True)
print(f"wrote {HERE / 'notes.pdf'}: {doc.page_count} pages")
