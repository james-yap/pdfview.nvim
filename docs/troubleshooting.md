# Troubleshooting

- [Error messages](#error-messages)
- [Supported platforms](#supported-platforms)
- [Limitations](#limitations)

Start with `:checkhealth pdfview`. It checks Neovim, the terminal, uv and the helper
that reads PDFs, and says what to fix.

## Error messages

| Message | Fix |
| --- | --- |
| `pdfview needs uv on $PATH` | Install [uv](https://docs.astral.sh/uv/getting-started/installation/). If you start Neovim from a GUI launcher, check that its `PATH` includes uv's folder, often `~/.local/bin`. |
| `no page view: needs kitty or Ghostty` | Open the PDF in kitty or Ghostty. |
| `tmux is not supported` | Open the PDF outside tmux. |
| `PDF helper exited (…): Failed to download …` | The first run downloads PyMuPDF and Typst from PyPI. Behind a proxy, set `HTTPS_PROXY`; for a mirror, set `UV_INDEX_URL`. |
| `PDF helper timed out` | The first install took longer than two minutes. Run `:checkhealth pdfview`, which waits for it, then open the PDF again. |
| `needs Neovim 0.12 or newer` | Upgrade Neovim. |

## Supported platforms

PyMuPDF and Typst must have prebuilt packages for your system:

- macOS,
- Linux on x86_64 or aarch64 with glibc 2.28 or newer,
- Linux on x86_64 with musl (such as Alpine).

`'termguicolors'` must be on. Neovim turns it on by itself when the terminal supports it.

Copying snapshots to the clipboard works on macOS only. Elsewhere the snapshot is saved
and its path is shown.

## Limitations

- **Text order.** The text follows the order it is stored in the PDF. Multi-column pages
  and maths can come out in an odd order, which affects motions, search and yanks. The
  rendered page and snapshots always show the real layout.
- **Unsupported PDFs.** Scanned PDFs (no text layer), encrypted PDFs and rotated pages
  do not work.
- **Search and Leap** only find characters that are in the text layer.
- **Selections** for annotations and snapshots must stay on one page.
- **One view per PDF.** Only one window shows the rendered pages. Other windows on the
  same buffer show its text.
