# Benchmarking

- [What a frame costs](#what-a-frame-costs)
- [Running the benchmark](#running-the-benchmark)
- [Profiling a live session](#profiling-a-live-session)
- [Reference numbers](#reference-numbers)

## What a frame costs

Every scroll step, cursor move or search change draws a new frame: a picture of the
pages that exactly covers the PDF window. With profiling on, each frame is timed in
these stages:

| Stage | Where | What it covers |
|---|---|---|
| `prepare` | Lua | Working out the view, the tints and scrollbar marks, and the request |
| `pages` | helper | Copying the visible pages from the page cache, then tinting search matches, the cursor and the selection |
| `scrollbar` | helper | Copying the cached scrollbar, then drawing the thumb and the cursor line over it |
| `write` | helper | Writing the frame to a temporary file as raw RGB |
| `ipc` | both | The JSON request and reply, and waiting for the Lua event loop |
| `show` | Lua | Telling the terminal to read the file in place of the previous frame |
| `total` | | From the start of `prepare` to the end of `show` |

The terminal's own work, which is reading the file and drawing it, is not measured.

Three things keep the cost of a frame low. Measure them again if you change them:

- **Raw frames.** Frames are uncompressed RGB (`f=24` in the kitty graphics protocol),
  not PNG. A 3200×1700 frame takes about 1 ms to write. A PNG of the same frame took
  80–100 ms to encode, and the terminal then had to decode it.
- **Page cache.** The helper rasterizes each page once at the view's width
  (`Doc.raster`). Each frame then only copies pixels from those pages. The cache holds
  up to `RASTER_CACHE_BYTES` (256 MB), dropping the least recently used page first. A
  page larger than that on its own is rendered just for the visible part of each frame.
  An annotation edit drops the edited page (`Doc.changed`); undo and redo drop every
  page.
- **One image per pane.** Each frame replaces the pane's terminal image under the same
  id, so Nvim has no cells to redraw. A resized pane gets a new image, because Ghostty
  shows nothing for an image that is replaced at a different size.

The `rasterized` count shows how many frames had to render a page first. Those frames
are the slow ones when you scroll into new pages.

## Running the benchmark

`tests/bench.lua` opens a PDF in headless Neovim with the real helper. Only the terminal
is replaced: frames are written and then deleted. It times four scenarios, each step
waiting for its frame to finish:

1. The first frame after opening the file.
2. Scrolling three rows at a time (`3<C-e>`).
3. Paging down a screen at a time (`<C-f>`), which reaches pages not drawn yet.
4. Scrolling with a search for `e` highlighted, so many matches are tinted.

```sh
nvim --headless -u NONE -i NONE -l tests/bench.lua docs/demo/notes.pdf
nvim --headless -u NONE -i NONE -l tests/bench.lua big.pdf --frames=60 --grid=200x50 --cell=16x34
```

| Option | Default | Meaning |
|---|---|---|
| `--frames` | 40 | Steps per scenario |
| `--grid` | `200x50` | The pane in cells |
| `--cell` | `16x34` | Cell size in pixels: a 2× (Retina) display; `--grid` × `--cell` sets the frame size |

The output is Markdown: one table per scenario with the median, 95th percentile and
maximum of each stage in ms.

## Profiling a live session

Set `PDFVIEW_PROFILE` to any non-empty value. You can do this before starting Nvim:

```sh
PDFVIEW_PROFILE=1 nvim paper.pdf
```

or at any time from inside it:

```vim
:let $PDFVIEW_PROFILE = 1
```

The next frames are recorded, up to the last 1000. Scroll around, then read the
summary:

```vim
:lua =require('pdfview').profile()
:lua =require('pdfview').profile({ reset = true }) " read it, then start over
```

`profile()` returns `{ frames, rasterized, stages = { <stage> = { median, p95, max } } }`
with times in ms. The stages are the ones in the table above.

## Reference numbers

Measured with `tests/bench.lua docs/demo/notes.pdf --frames=30` (3200×1700 px frames)
on an Apple Silicon Mac:

| Scenario | median ms | p95 ms | max ms |
|---|---:|---:|---:|
| First frame (renders a page) | 23.3 | 23.3 | 23.3 |
| Scroll `3<C-e>` | 1.8 | 4.8 | 9.6 |
| Page down `<C-f>` | 1.8 | 2.0 | 2.0 |
| Scroll with a search for `e` | 4.5 | 6.1 | 25.7 |

Before raw frames and the caches, every frame rendered its pages from scratch and
encoded a PNG: about 100 ms a frame on the same file.
