# pdfview.nvim

Read and annotate PDFs in Neovim with ordinary Vim motions, and hand what you are
looking at to an AI agent as one captioned image.

Opening a `.pdf` gives you two windows:

- a **text buffer** with the PDF's text, one line per PDF text line, where `hjkl`, `/`,
  `w`, visual mode and jump plugins such as [leap.nvim](https://codeberg.org/andyg/leap.nvim)
  work as usual;
- a **page pane** showing the rendered page. It frames the lines the text window shows
  (scrolling the text window scrolls the pane) and greys out the rest of the page, so what
  is bright is exactly what `/` and leap can reach. It tints the cursor line or the visual
  selection and marks the character under the cursor, so you always see where you are on
  the real page. When the text window shows more than fits, the pane follows the cursor
  instead. A thin scrollbar on its right edge shows where the visible part sits in the
  whole document, with a tick at each page boundary (ticks are left out when pages are too
  close together to tell apart).

With leap.nvim, its jump labels also appear on the page pane, over the words they point
to. pdfview hooks in through leap's `on_beacons` option (any function you set there keeps
working). Labels on the pane are placed to the nearest terminal cell, so two labels on
neighbouring words can occasionally share a cell.

Annotations (highlight, underline, strikethrough, notes) are standard PDF annotations, so
other PDF viewers show them too.

## Requirements

- Neovim 0.12+
- [uv](https://docs.astral.sh/uv/). The PDF work is done by a small Python script run with
  `uv run --script`; on first use uv installs Python and
  [PyMuPDF](https://pymupdf.readthedocs.io/) into an isolated, cached environment (this
  can take a few seconds, once).
- For the page pane: [kitty](https://sw.kovidgoyal.net/kitty/) or
  [Ghostty](https://ghostty.org/), with `'termguicolors'` on. Elsewhere (including inside
  tmux) the text buffer, annotations and snapshots still work, just without the pane.
- For copying snapshots to the clipboard: macOS. On other systems the snapshot is saved and
  its path is shown.

## Installation

With `vim.pack`:

```lua
vim.pack.add { 'https://github.com/james-yap/pdfview.nvim' }
require('pdfview').setup()
```

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ 'james-yap/pdfview.nvim', opts = {} }
```

`setup()` is required: it registers the handler that opens `*.pdf` files.

## Configuration

Defaults:

```lua
require('pdfview').setup {
  -- Buffer-local keys in PDF buffers; set any of them to false to skip it.
  keys = { prefix = '<leader>p', next_annotation = ']a', prev_annotation = '[a' },
  -- Page pane width: a fraction (< 1) of the columns it shares with the text window, or a
  -- number of columns. Reapplied when the terminal is resized (including font zoom);
  -- resizing by hand (<C-w><, :vertical resize, dragging the separator) sticks otherwise.
  pane_width = 0.6,
  -- Where snapshots are written. nil: $TMPDIR/pdfview.
  snapshot_dir = nil,
}
```

## Keys

Keys are only mapped in PDF buffers (`x` is visual mode).

| Key | Mode | Action |
| --- | --- | --- |
| `<leader>py` | n, x | Snapshot for an agent (see below) |
| `<leader>ph` | x | Highlight the selection |
| `<leader>pu` | x | Underline the selection |
| `<leader>ps` | x | Strike out the selection |
| `<leader>pn` | x | Highlight the selection and write a note on it |
| `<leader>pn` | n | Edit the note of the annotation under the cursor |
| `<leader>pd` | n | Delete the annotation under the cursor |
| `<leader>pl` | n | List all annotations in the quickfix list |
| `]a` / `[a` | n | Next / previous annotation (takes a count) |

Notes open in a small floating window: `:w` saves, `q` saves and closes.

## Annotations and saving

The PDF buffer behaves like a file you edit:

- Annotation changes are kept in memory and mark the buffer as modified.
- `:w` writes them into the PDF (an incremental save, so the rest of the file is untouched).
  `:w other.pdf` writes a copy.
- `:e!` reloads the PDF from disk and discards unsaved annotations; `:e` refuses while there
  are unsaved changes.

Highlights, underlines, strikethroughs, squiggly underlines and text notes made by other
programs are shown, listed, and can be edited or deleted as well.

When the PDF changes on disk (for example, LaTeX recompiling it), the buffer reloads by
itself. If you have unsaved annotations it warns instead, and `:w` refuses to overwrite the
newer file; `:e!` picks up the new version.

## Snapshots for agents

`<leader>py` renders exactly what the page pane shows (or the cursor's whole page when there
is no pane), with the visual selection tinted, and adds a caption strip below it:

- the PDF's absolute path,
- page number and the visible area in PDF points,
- the selection's bounding box,
- the text of every note visible on that part of the page.

The result is one PNG, so it works both in a local agent harness (via its path) and in a
web chat (paste the image). Vision models read the page text from the image; the caption
carries what the image cannot show, such as where the page lives on disk and the note text.

## How it works

- `python/helper.py` (PyMuPDF) extracts the text with each character's position, renders
  page regions, edits annotations and builds snapshots. Neovim talks to one helper process
  per session over JSON lines.
- The page pane uses the kitty graphics protocol with Unicode placeholders
  (`lua/pdfview/kitty.lua`): the image is drawn through placeholder characters in the pane
  buffer, so splits and floating windows cover it correctly. Rendered pages are handed to
  the terminal as temporary files, which the terminal deletes after reading.

Filetypes: `pdfview` (text buffer), `pdfview_page` (pane). Highlight groups, all overridable:
`PdfViewHighlight`, `PdfViewUnderline`, `PdfViewStrikeOut`, `PdfViewSquiggly`,
`PdfViewNote`.

## Limitations

- The text order is the PDF's content order. Multi-column layouts and math can come out in
  an awkward order; the page pane and snapshots show the real layout.
- Scanned PDFs (no text layer), encrypted PDFs and rotated pages are not supported.
- A selection (for annotations or snapshots) must stay on one page.
- No tmux support for the page pane.

## License

[AGPL-3.0](LICENSE). pdfview.nvim depends on PyMuPDF, which is also AGPL-3.0.
