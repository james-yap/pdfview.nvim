# /// script
# requires-python = ">=3.11"
# dependencies = ["pymupdf>=1.26,<1.27"]
# ///
"""Build docs/demo/social.pdf: notes.pdf with more colour around the equations on
page 1, for the social-media clip.

    uv run --script docs/demo/social_pdf.py
"""
from pathlib import Path

import pymupdf

HERE = Path(__file__).parent
BLUE, PINK, LAVENDER, ORANGE, YELLOW = (0.62, 0.8, 1), (1, 0.72, 0.85), (0.8, 0.72, 1), (1, 0.55, 0.15), (1, 0.85, 0.3)

doc = pymupdf.open(HERE / "notes.pdf")
page = doc[0]
for text, kind, color, note in [
    ("along the arc", "highlight", PINK, ""),
    ("bottom of its swing", "underline", ORANGE, ""),
    ("For small swings", "highlight", LAVENDER, "Valid to about 15 degrees."),
    ("pendulums made such", "squiggly", BLUE, ""),
    ("size of the swing", "highlight", YELLOW, ""),
]:
    quads = page.search_for(text, quads=True)
    assert quads, text
    add = {"highlight": page.add_highlight_annot, "underline": page.add_underline_annot,
           "squiggly": page.add_squiggly_annot}[kind]
    annot = add(quads[0])
    annot.set_colors(stroke=color)
    if note:
        annot.set_info(content=note)
    annot.update()
doc.save(HERE / "social.pdf", garbage=3, deflate=True)
print(f"wrote {HERE / 'social.pdf'}")
