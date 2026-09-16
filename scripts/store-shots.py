#!/usr/bin/env python3
"""Turn raw iPhone screenshots into App Store assets.

The five shots on the store today are bare device captures — no caption, no
frame, nothing. Both leaders in the category do the same thing as each other and
neither does that: a bold caption ABOVE a device frame, one benefit per shot,
exactly one word in an accent colour. Locally AI's first shot is "Run AI
**Locally** on iPhone" over a phone reading a photograph; Enclave's is "Chat
offline with an **AI** using your voice". Against those, a raw capture reads as
a screenshot dump.

This exists because the two shots that matter — the assistant answering "what's
on tomorrow?" and a reminder being set — cannot be taken on a simulator. A
tool-capable model is 1.1GB and the simulator reports 722MB usable, so every
model in the catalogue shows "Too large". They have to come off a real phone.
So: take them on the phone, drop the PNGs in, run this.

    python3 scripts/store-shots.py raw/ docs/store/

Each input file is matched to a caption by its name — see CAPTIONS. Output is
1320x2868, which is the 6.7" size already on the listing.
"""

import sys
import os
from PIL import Image, ImageDraw, ImageFont

# The 6.7" App Store size, which is what the listing already uses.
W, H = 1320, 2868

INK = (17, 17, 19)
ACCENT = (10, 132, 255)          # iOS system blue, which the app already uses
BG_TOP = (247, 247, 250)
BG_BOTTOM = (232, 234, 242)

# One benefit per shot, and the order is the argument. Slot 1 is the only one
# most people see, so it is the assistant doing the thing no competitor can do
# — not the introduction, and not the model talking about itself, which is what
# the current slot 1 does.
#
# The accent word is the one the eye should land on. Exactly one per caption:
# two is a ransom note.
CAPTIONS = [
    ("chat-calendar",  "It knows what's on|tomorrow.",                "tomorrow."),
    ("chat-reminder",  "Ask it to remind you.|It actually does.",     "actually"),
    ("chat-repeat",    "Every weekday|at 7am.",                       "Every"),
    ("abilities",      "Three switches.|All start off.",              "off."),
    ("privacy",        "Nothing leaves|the phone.",                   "Nothing"),
    ("models",         "Tells you what fits|before you download.",    "fits"),
    ("server",         "Also: your phone|is an AI server.",           "server."),
]


def font(size, bold=True):
    """SF first, because it is what the screenshots inside the frame are set in."""
    for path in (
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Supplemental/Helvetica.ttc",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    ):
        if os.path.exists(path):
            try:
                f = ImageFont.truetype(path, size)
                # SFNS is variable; ask for the bold face where we can.
                if bold and "SFNS" in path:
                    try:
                        f.set_variation_by_name("Bold")
                    except Exception:
                        pass
                return f
            except Exception:
                continue
    return ImageFont.load_default()


def background():
    """A vertical wash rather than flat white.

    Flat white is what a bare capture already looks like against the store's own
    white, so the shot loses its edges and reads as part of the page. A wash
    gives it a boundary without adding anything to look at.
    """
    bg = Image.new("RGB", (W, H), BG_TOP)
    draw = ImageDraw.Draw(bg)
    for y in range(H):
        t = y / H
        draw.line(
            [(0, y), (W, y)],
            fill=tuple(int(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM)),
        )
    return bg


def rounded(image, radius):
    """Round the screenshot's own corners so it sits inside the bezel."""
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, *image.size], radius=radius, fill=255)
    out = image.convert("RGBA")
    out.putalpha(mask)
    return out


def draw_caption(canvas, text, accent):
    """Two lines, centred, with one word in the accent colour.

    Split on a literal pipe rather than wrapped automatically: where the line
    breaks changes what the sentence emphasises, and that is an editorial
    decision rather than a measurement.
    """
    draw = ImageDraw.Draw(canvas)
    size = 96
    f = font(size)
    lines = text.split("|")

    # Shrink until the widest line fits the margins. Cheaper than measuring
    # every candidate size, and it runs seven times.
    while size > 40:
        f = font(size)
        if max(draw.textlength(l, font=f) for l in lines) <= W - 200:
            break
        size -= 4

    line_height = int(size * 1.18)
    y = 150
    for line in lines:
        x = (W - draw.textlength(line, font=f)) / 2
        # Drawn word by word so one of them can be a different colour, which is
        # the thing both leaders do and the current shots do not.
        for word in line.split(" "):
            piece = word + " "
            colour = ACCENT if word.strip() == accent.strip() else INK
            draw.text((x, y), piece, font=f, fill=colour)
            x += draw.textlength(piece, font=f)
        y += line_height
    return y


def compose(shot_path, caption, accent, out_path):
    shot = Image.open(shot_path).convert("RGB")
    canvas = background()
    bottom_of_caption = draw_caption(canvas, caption, accent)

    # The device fills the rest, with its own breathing room. Scaled to a fixed
    # width so seven shots line up at the same size in the store's filmstrip —
    # a set whose frames drift in size reads as carelessness at thumbnail size.
    frame_w = 1000
    scale = frame_w / shot.width
    frame_h = int(shot.height * scale)
    shot = shot.resize((frame_w, frame_h), Image.LANCZOS)
    shot = rounded(shot, 56)

    bezel = 14
    x = (W - frame_w) // 2
    # Tight to the caption rather than parked at a fixed line. Measured against
    # the two leaders: their device occupies about seventy per cent of the
    # height and the caption sits directly above it. A wide gap in the middle
    # reads as a layout that did not finish.
    y = bottom_of_caption + 80

    plate = Image.new("RGBA", (frame_w + bezel * 2, frame_h + bezel * 2), (0, 0, 0, 0))
    ImageDraw.Draw(plate).rounded_rectangle(
        [0, 0, frame_w + bezel * 2, frame_h + bezel * 2], radius=70, fill=(8, 8, 10, 255)
    )
    canvas.paste(plate, (x - bezel, y - bezel), plate)
    canvas.paste(shot, (x, y), shot)

    canvas.save(out_path, "PNG")
    return out_path


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        print("usage: store-shots.py <raw-dir> <out-dir>")
        return 1
    raw, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)

    made, missing = [], []
    for index, (slug, caption, accent) in enumerate(CAPTIONS, 1):
        source = None
        for ext in (".png", ".PNG", ".jpg", ".jpeg"):
            candidate = os.path.join(raw, slug + ext)
            if os.path.exists(candidate):
                source = candidate
                break
        if source is None:
            missing.append(slug)
            continue
        target = os.path.join(out, f"{index:02d}-{slug}.png")
        compose(source, caption, accent, target)
        made.append(target)

    for path in made:
        print("made", path)
    if missing:
        # Named rather than counted: "3 missing" sends somebody back to the
        # script to find out which.
        print("\nstill needed in", raw, "(name the file after the slug):")
        for slug in missing:
            caption = next(c for s, c, _ in CAPTIONS if s == slug)
            print(f"  {slug}.png — {caption.replace('|', ' ')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
