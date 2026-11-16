# Recording the README demos

How the GIFs and stills in `doc/media/` were made, so they can be re-recorded after a
feature changes. Recorded on macOS in Ghostty; nothing here is needed to use the plugin.

## Files

| File | Purpose |
| --- | --- |
| `notes.typ` | Three pages of single-column lecture notes (A Pendulum in a Moving Lift), written for the demos: narrow pages so text stays large in a GIF, maths for Leap and Typst. |
| `build.py` | `uv run --script doc/demo/build.py` compiles `notes.typ` and adds coloured annotations "from another reader" (blue, green, pink, purple highlights, underlines, a squiggly) so the page and scrollbar look lived-in. Writes `notes.pdf`. |
| `notes.pdf` | The built demo PDF. Record from a copy: the clips modify it in memory. |
| `keycast.lua` | Shows typed keys in the middle of the statusline (via [screenkey.nvim](https://github.com/NStefan002/screenkey.nvim), recorded with commit `740e238`), and turns off which-key popups in PDF buffers. |

## Setup

1. A clone of screenkey.nvim, e.g. `git clone https://github.com/NStefan002/screenkey.nvim /tmp/demo/screenkey`.
2. A launcher, in a scratch directory holding a copy of `notes.pdf`:

   ```sh
   nvim --listen /tmp/demo/nvim.sock --cmd 'set rtp^=~/git/pdfview.nvim' \
     --cmd 'set rtp^=/tmp/demo/screenkey' -c 'luafile ~/git/pdfview.nvim/doc/demo/keycast.lua' \
     -c 'edit notes.pdf'
   ```

   The clips used the author's config (`NVIM_APPNAME=kickstart.nvim`: kickstart.nvim with
   leap on `f`, `<leader>` = Space, which-key, an autopairs plugin). Opening the PDF with
   `-c 'edit …'` after `keycast.lua` matters: which-key's per-filetype disable only
   applies to buffers opened afterwards.
3. Run it in its own Ghostty window: `open -na Ghostty --args --title=pdfview-demo
   --font-size=18 -e <launcher>`. Size it to 1120 × 700 points, fully on one display (a
   Retina display gives crisp 2× frames). macOS has no CLI for this; System Events works:

   ```sh
   osascript -e 'tell application "System Events" to repeat with p in (every process whose name is "ghostty")
     repeat with w in (every window of p)
       if name of w is "pdfview-demo" then
         set position of w to {X, Y}
         set size of w to {1120, 700}
       end if
     end repeat
   end repeat'
   ```

   Match the window by its title: several Ghostty processes share the name `ghostty`, and
   "first window of process" can grab someone else's window.

## Driving and recording

- **Keys** go through Neovim's RPC socket, one key every 100–350 ms so viewers can follow:
  `nvim --server /tmp/demo/nvim.sock --remote-send 'f'` (special keys as `<CR>`, `<Esc>`,
  `<C-r>`, `<Left>`; Space for `<leader>`). This works while someone else uses the
  machine, unlike synthetic GUI input, and keycast still sees the keys.
- **Recording**: `screencapture -x -v -l<CGWindowID> clip.mov`, stopped with SIGINT after
  the last step. It records just that window, even when covered, but crops whatever lies
  off the display. Wait about 3 s after any setup keys before starting: the keycast clears
  after 3 s of no input.
- **Converting** (ffmpeg + gifski, `brew install ffmpeg gifski`). For a 1120 × 700 pt
  window at 2×, the movie is 2464 × 1624: a 112 px shadow at each side, 76 px above with
  a 66 px title bar, and 148 px below plus 32 px of window padding. Crop to the terminal
  and scale to 1000 px wide at 12 fps:

  ```sh
  ffmpeg -ss 1 -i clip.mov -vf "setpts=PTS/1.2,crop=2236:1302:114:142,fps=12,scale=1000:-1:flags=lanczos" f/%04d.png
  gifski --fps 12 --quality 90 -o clip.gif f/*.png
  ```

  At another size or scale, measure the crop on one frame
  (`ffmpeg -sseof -1 -i clip.mov -frames:v 1 frame.png`): the title bar and the shadow
  are the dark bands around the terminal. `setpts=PTS/1.2` speeds a slow clip up.
- **Scrollbar and marks clips** add a copy of the scrollbar, stretched three times
  sideways, to the right, because the real bar is about 17 px wide in a 1000 px GIF.
  The bar is the 34 px to the left of the last 34 px of the cropped frame (dark terminal
  padding):

  ```sh
  ffmpeg -ss 1 -i clip.mov -filter_complex "[0:v]crop=2236:1302:114:142,fps=12,split[a][b];\
  [a]scale=940:548:flags=lanczos[view];\
  [b]crop=34:1210:2168:0,scale=50:509:flags=lanczos,pad=66:548:12:0:color=0x16141e[bar];\
  [view][bar]hstack" f/%04d.png
  ```

- **Stills** (`hero.png`): `screencapture -x -o -l<id> raw.png` (no shadow), then
  `crop=2236:1302:2:66,scale=1600:-1`.

Check each clip with a contact sheet of a few frames before committing; GIFs are 0.3–1.2
MB each.

## Clips

Every clip starts from a fresh copy of `notes.pdf` with marks `b` and `c` set beforehand,
so the scrollbar has pills: `]p dd mb ]p d mc gg`.

| Clip | Before recording | Keys while recording |
| --- | --- | --- |
| `leap.gif` | — | `f` `bo`, wait, label `s` (to "bottom"); `f` `si`, wait, label `n` (the sin in equation 1). Labels depend on where the cursor is, so rehearse once and look at them first. |
| `annotations.gif` | — | `/light s<CR>` `vee` `<leader>ph`; `/simple h<CR>` `vee` `<leader>pu`; `/the vertical<CR>` `wve` `<leader>ps`; `u`, `<C-r>` (still in cursor mode: in pager mode `u` pans); `<Esc>`. Sped up 1.3×. |
| `typst.gif` | `/light s<CR>` | `vee` `<leader>pn` `i`, type `Massless string, so only $l$ sets the period:<CR>`, then `$  $<Left><Left>` before typing `T = 2 pi sqrt(l / g)`. The closed `$ $` lets the preview grow with each key; autopairs adds the `)`. Then `<Esc>` `q` `K`. Sped up 1.2×. |
| `marks.gif` | `]p d` | `ma`, `gg`, `'a`, `''`, `''` |
| `scrollbar.gif` | the three annotations from the annotations clip, then `gg` | `/pendulum` (type slowly: incsearch tints live), `<CR>`, `n` × 3, `ma`, `gg` |
| `hero.png` | the annotations and the Typst note as above, `:noh`, cursor on "light string" (`:call search('light s')`), `c` `zt` `ma` | `K`, then the still. Close any focused preview first (`q`), or `K` focuses it instead of opening one under the cursor. |
| `snapshot.png` | the Typst note, then `/Newton<CR>` `v$` | `<leader>py`; the PNG is the newest file in `$TMPDIR/pdfview/`. |

## Gotchas

- screenkey's `win_opts.anchor` must be `NW`/`NE`/`SW`/`SE`; anything else fails without
  showing a window.
- With which-key active, `<leader>` sequences show twice in the keycast and its popup
  covers the page; `keycast.lua` turns it off for `pdfview` buffers.
- A window that straddles two displays records cropped.
