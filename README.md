# pdfview.nvim

Read and annotate PDFs in Neovim with ordinary Vim motions, and hand what you are
looking at to an AI agent as one captioned image.

Opening a `.pdf` fills its window with the rendered pages, stacked vertically for
continuous scrolling. The text layer stays hidden: `hjkl`, `w`, `/`, `n`, marks,
visual mode and yanking still operate on real buffer text. The view follows the
cursor, tints its line or visual selection, and marks the character under the cursor.
The cursor becomes hollow when you leave the PDF window or the terminal loses focus.
A document-wide scrollbar at the right edge marks page boundaries, and a badge beside
its bottom end shows the cursor's page and the page count (highlight `PdfViewPage`,
linked to `StatusLine`).

`<leader>pt` toggles the extracted text alongside the pages, useful for inspecting
reading order or checking what a yank copies. Neither layout greys out page content.

With [leap.nvim](https://codeberg.org/andyg/leap.nvim), pdfview supplies targets for
everything visible on the rendered pages, including text outside the hidden text
window's viewport and in other columns. Your keys mapped to `<Plug>(leap)` are
automatically overridden in PDF buffers (or set `keys.leap` explicitly). Type two
characters, then use Leap's usual labels, autojump and traversal. Matching is
case-insensitive and respects Leap's equivalence classes. Labels appear after the
second character: Leap's first-character preview is not used, and repeating a
custom-target jump asks for its characters again.

Labels are mirrored through Leap's `on_beacons` hook (any existing hook is preserved).
They snap to terminal cells, so very close matches can share a label cell.

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
  -- A list maps several keys to the same action.
  keys = {
    prefix = '<leader>p', next_annotation = ']a', prev_annotation = '[a', leap = nil,
    next_page = { ']p', '<PageDown>' }, prev_page = { '[p', '<PageUp>' },
    hover = 'K', undo = 'u', redo = '<C-r>',
  },
  -- leap = nil: use keys mapped to <Plug>(leap); a string sets a key; false disables it.
  -- 'page': full-window rendered pages with hidden text. 'split': text + page pane.
  view = 'page',
  -- Split mode pane width: a fraction (< 1) of the columns it shares with the text window, or a
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
| `<leader>pt` | n | Toggle full-window pages / text with page pane |
| `<leader>pp` | n | Pager mode, in the full-window page view (see below) |
| `<leader>ph` | x | Highlight the selection |
| `<leader>pu` | x | Underline the selection |
| `<leader>ps` | x | Strike out the selection |
| `<leader>pn` | x | Highlight the selection and write a note on it |
| `<leader>pn` | n | Edit the note of the annotation under the cursor |
| `<leader>pd` | n | Delete the annotation under the cursor |
| `<leader>pl` | n | List all annotations in the quickfix list |
| `K` | n | Preview the note under the cursor; press again to focus the preview |
| `u` / `<C-r>` | n | Undo / redo annotation changes (takes a count) |
| `]a` / `[a` | n | Next / previous annotation (takes a count) |
| `]p` / `[p`, `<PageDown>` / `<PageUp>` | n, x | Next / previous page: the page from its top, cursor on its first line (takes a count) |

`K` uses Neovim's hover-style Markdown preview, without requiring an LSP server.
Moving the PDF cursor dismisses it; after focusing it with a second `K`, use `q` or
`<Esc>` to close. Viewing a note never marks the PDF modified.

`<leader>pn` opens the editable note window: `:w` saves the note into the in-memory
PDF, and `q` saves and closes. Text editing inside this window uses its own normal
Neovim undo history.

In full-window page mode these keys operate on the rendered view (in normal and visual
mode); in split mode they retain their native text-window behaviour:

| Key | Action |
| --- | --- |
| `<C-e>` / `<C-y>` | Scroll down / up a terminal row (takes a count) |
| `<C-d>` / `<C-u>` | Scroll half a view; an explicit count scrolls that many rows |
| `<C-f>` / `<C-b>` | Scroll down / up a view with two rows of overlap (takes a count) |
| Mouse wheel | Scroll the pages |
| `zt` / `zz` / `zb` | Put the cursor line near the top / middle / bottom |
| `H` / `M` / `L` | Move to a line near the top / middle / bottom |
| Left click | Move to the character you clicked |

Scrolling keeps the cursor in view where there is text. Search still covers the whole
document; incremental and last-search matches are tinted on the rendered pages.
Selections and yanks use the extracted text's reading order, not a two-dimensional
screen rectangle. Use `v` or `V` for selection; mouse dragging is not used in page mode.

### Pager mode

`<leader>pp` turns the page view into a pager (switching from split mode first), like `less` or Vimium: keys pan the
pages, the cursor is not drawn, and the badge reads `PAGER` with the page in the middle
of the view. The cursor still follows the view, so leaving resumes where you stopped.

| Key | Action |
| --- | --- |
| `j` / `k`, `<Down>` / `<Up>`, `<CR>` | Pan down / up three rows (takes a count) |
| `d` / `u`, `<C-d>` / `<C-u>` | Pan half a view; an explicit count pans that many rows |
| `f` / `b`, `<Space>`, `<C-f>` / `<C-b>` | Pan down / up a view with two rows of overlap (takes a count) |
| `gg` / `G` | Pan to the start / end |
| `q` / `<Esc>` | Leave pager mode |

Other keys keep working (`]p`, `/`, the mouse wheel, ...). The pager keys stand in
for the buffer's own mappings of the same keys (such as `u` for annotation undo) until
you leave; toggling to split mode also leaves.

## Annotations and saving

The PDF buffer behaves like a file you edit:

- Annotation changes are kept in memory and mark the buffer as modified.
- `:w` writes them into the PDF (an incremental save, so the rest of the file is untouched).
  `:w other.pdf` writes a copy.
- `:e!` reloads the PDF from disk and discards unsaved annotations; `:e` refuses while there
  are unsaved changes.
- `u` / `<C-r>` undo and redo annotation creation, deletion and note saves. History
  uses Neovim's native undo tree in a separate hidden annotation-state buffer, so the
  extracted text and ordinary PDF navigation remain unchanged.
- `:w` preserves that history. Undoing away from the saved state marks the PDF
  modified again; returning to it clears the modified flag. Reloading starts fresh.
- History is session-only: there is no on-disk annotation autosave or crash recovery.

Statuslines must include `%m` to show the usual `[+]` for unsaved changes. In page
mode the visible PDF window is technically inactive because a hidden float holds
keyboard focus. If using `mini.statusline`, include `%m` in its inactive content:

```lua
require('mini.statusline').setup {
  content = {
    inactive = function() return '%#MiniStatuslineInactive#%F%m%=' end,
  },
}
```

Highlights, underlines, strikethroughs, squiggly underlines and text notes made by other
programs are shown, listed, and can be edited or deleted as well.

When the PDF changes on disk (for example, LaTeX recompiling it), the buffer reloads by
itself. If you have unsaved annotations it warns instead, and `:w` refuses to overwrite the
newer file; `:e!` picks up the new version.

## Snapshots for agents

`<leader>py` captures the visible regions of the stacked pages (or the cursor's whole
page when there is no rendered view), with the visual selection tinted, and adds a
caption strip below it:

- the PDF's absolute path,
- each visible page number and its visible area in PDF points,
- the selection's bounding box and page,
- the text of every note visible on those parts of the pages.

The result is one PNG, so it works both in a local agent harness (via its path) and in a
web chat (paste the image). Vision models read the page text from the image; the caption
carries what the image cannot show, such as where the page lives on disk and the note text.

## How it works

- `python/helper.py` (PyMuPDF) extracts the text with each character's position, renders
  page regions, edits annotations and builds snapshots. Neovim talks to one helper process
  per session over JSON lines. View backgrounds use native bulk fills and the scrollbar
  uses whole scanline writes, avoiding Python per-pixel loops on navigation updates.
- In page mode a non-focusable image float covers the normal PDF window. A second,
  hidden float on the text buffer holds focus and inherits the window's jumplist and
  alternate file. Vim handles ordinary text motions and operators; pdfview only maps
  view-specific controls. Buffer switches from the hidden float are handed back to the
  normal window; closing it closes the PDF window too.
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
- Search highlighting is line-local (multi-line patterns still navigate through native
  search). The text layer must contain the characters you want to search or jump to.
- One rendered view is kept per PDF buffer; additional splits of that buffer can show
  its extracted text.

## Checks

```sh
uv run --with 'pymupdf>=1.26,<1.27' tests/test_helper.py
```

This checks continuous page composition, clipping, hit testing, snapshots, hollow
cursors, visual selection repainting while an earlier mode callback waits for input,
note previews, native annotation undo/redo, modified-state transitions and lossless
annotation restoration through saves (including repaired PDFs).
The headless Neovim checks use the real helper, replacing only terminal graphics.
To include the Leap regression (jumping
to visible page text outside the hidden text viewport), set `PDFVIEW_LEAP_RTP` to
your installed `leap.nvim` directory when running the command.

## License

[AGPL-3.0](LICENSE). pdfview.nvim depends on PyMuPDF, which is also AGPL-3.0.
