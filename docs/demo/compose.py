# Compose the social-media clip: the Ghostty window, title bar included, on a gradient,
# with Keyviz-style keycaps below it. Run in the directory holding the recording:
#   uv run --with pillow docs/demo/compose.py NAME   (NAME.mov + NAME.keys.json -> NAME.mp4)
# NAME.keys.json is {"dur": movie seconds, "events": [{"t": seconds into the movie,
# "k": key as sent to nvim, "kind": "key" | "text"}]}; "text" keys gather into one strip.
# The window geometry below is for a 1120 x 720 pt window captured at 2x (see README.md).
import json, subprocess, sys
from PIL import Image, ImageDraw, ImageFont

NAME = sys.argv[1]
SS = 0.8                      # seconds trimmed from the start
FPS = 30
WX, WY, WW, WH = 112, 76, 2240, 1440   # window inside the capture (Retina px)
RADIUS = 32                   # window corner radius, capture px
CW, CH = 1680, 1080           # output: the window, scaled
CAPS_Y = CH - 182             # top of the keycaps row, just above the statusline
FONT = ImageFont.truetype("/System/Library/Fonts/SFNSRounded.ttf", 40)
MONO = ImageFont.truetype("/System/Library/Fonts/SFNSMono.ttf", 36)

# The window fills the frame; its rounded corners are squared off with the colours
# next to them (title bar at the top, the terminal's bottom edge below).
mask = Image.new("L", (WW, WH), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, WW - 1, WH - 1), RADIUS, fill=255)
TITLE_BG = (32, 38, 42)

# Traffic lights over the recording badge (drawn at 4x for smooth edges).
lights = Image.new("RGBA", (170 * 4, 68 * 4), (0, 0, 0, 0))
d = ImageDraw.Draw(lights)
d.rectangle((6 * 4, 10 * 4, 150 * 4, 58 * 4), fill=TITLE_BG + (255,))
for cx, fill, rim in ((32, (255, 95, 87), (224, 68, 62)), (78, (254, 188, 46), (222, 161, 35)), (124, (40, 200, 64), (26, 171, 41))):
    d.ellipse(((cx - 13) * 4, (33 - 13) * 4, (cx + 13) * 4, (33 + 13) * 4), fill=rim)
    d.ellipse(((cx - 12) * 4, (33 - 12) * 4, (cx + 12) * 4, (33 + 12) * 4), fill=fill)
lights = lights.resize((170, 68), Image.LANCZOS)

# Keycaps: rows of keys, with typed text gathered into one strip.
LABEL = {" ": "Space", "<CR>": "Enter", "<Esc>": "Esc", "<Left>": "←", "<Right>": "→"}
NEW_ROW, HOLD, FADE, PRESS = 1.0, 1.4, 0.25, 0.18
events = json.load(open(f"{NAME}.keys.json"))["events"]
states = []  # (t, items, newest index)
items, last = [], -9
for e in events:
    if e["t"] - last > NEW_ROW:
        items = []
    if e["kind"] == "text" and items and items[-1][0] == "text":
        items[-1] = ("text", items[-1][1] + e["k"])
    elif e["kind"] == "text":
        items.append(("text", e["k"]))
    else:
        items.append(("key", LABEL.get(e["k"], e["k"])))
    items = items[-7:]
    states.append((e["t"], list(items)))
    last = e["t"]

def cap_size(item):
    kind, s = item
    if kind == "text":
        s = s if len(s) <= 28 else "…" + s[-27:]
        return s, MONO, max(84, MONO.getlength(s) + 52)
    return s, FONT, max(84, FONT.getlength(s) + 52)

cache = {}
def caps(items, pressed):
    key = (tuple(items), pressed)
    if key in cache:
        return cache[key]
    sized = [cap_size(i) for i in items]
    while sum(w for *_, w in sized) + 18 * (len(sized) - 1) > CW - 160:
        sized.pop(0)
    total = sum(w for *_, w in sized) + 18 * (len(sized) - 1)
    img = Image.new("RGBA", (CW * 2, 120 * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    x, h = (CW - total) / 2, 84
    for n, (s, font, w) in enumerate(sized):
        hot = pressed and n == len(sized) - 1
        y = 10 + (3 if hot else 0)
        box = lambda dx, dy: [v * 2 for v in (x + dx, y + dy, x + w + dx, y + h + dy)]
        d.rounded_rectangle(box(0, 8), 20 * 2, fill=(0, 0, 0, 110))
        d.rounded_rectangle(box(0, 0), 20 * 2, fill=(30, 31, 38, 255),
                            outline=(140, 180, 255, 255) if hot else (92, 94, 108, 255), width=3 * 2)
        tf = font.font_variant(size=font.size * 2)
        tw = tf.getlength(s)
        d.text(((x + (w - tw / 2) / 2) * 2, (y + h / 2) * 2), s, font=tf, fill=(245, 245, 250), anchor="lm")
        x += w + 18
    img = img.resize((CW, 120), Image.LANCZOS)
    cache[key] = img
    return img

def overlay(t):
    cur = None
    for i, (ts, its) in enumerate(states):
        if ts <= t:
            cur = (ts, its, states[i + 1][0] if i + 1 < len(states) else 1e9)
    if not cur:
        return None, 0
    ts, its, nxt = cur
    end = ts + HOLD
    if nxt - ts <= NEW_ROW:  # row continues: stay fully visible
        end = 1e9
    if t > end + FADE:
        return None, 0
    alpha = 1 if t <= end else 1 - (t - end) / FADE
    return caps(its, t - ts < PRESS), alpha

dur = json.load(open(f"{NAME}.keys.json"))["dur"]
dec = subprocess.Popen(["ffmpeg", "-v", "error", "-ss", str(SS), "-i", f"{NAME}.mov",
                        "-vf", f"fps={FPS},crop={WW}:{WH}:{WX}:{WY}", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                       stdout=subprocess.PIPE)
enc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{CW}x{CH}",
                        "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "slow", "-crf", "16",
                        "-pix_fmt", "yuv420p", "-movflags", "+faststart", f"{NAME}.mp4"], stdin=subprocess.PIPE)
n, size = 0, WW * WH * 3
while True:
    buf = dec.stdout.read(size)
    if len(buf) < size:
        break
    t = SS + n / FPS
    win = Image.frombytes("RGB", (WW, WH), buf)
    win.paste(lights, (0, 0), lights)
    base = Image.new("RGB", (WW, WH), TITLE_BG)
    base.paste(win.getpixel((WW // 2, WH - 4)), (0, WH // 2, WW, WH))
    base.paste(win, (0, 0), mask)
    frame = base.resize((CW, CH), Image.LANCZOS)
    ov, a = overlay(t)
    if ov is not None:
        if a < 1:
            ov = ov.copy()
            ov.putalpha(ov.getchannel("A").point(lambda v: round(v * a)))
        frame.paste(ov, (0, CAPS_Y - 10), ov)
    enc.stdin.write(frame.tobytes())
    n += 1
enc.stdin.close(); enc.wait(); dec.wait()
print("frames", n, "states", len(states), "caps cached", len(cache))
