#!/usr/bin/env python3
"""Compose App Store screenshots from raw simulator captures.

Same family as Vero's marketing set: a light canvas, a Didot headline, a
quiet subhead, and the phone below bleeding off the bottom edge. Payday's
app is dark, so the device reads as one solid object against the light
field rather than a floating rectangle.

Input frames are 1320x2868 (iPhone 6.9"), which is also the output size,
so uploads need no resampling.

    python3 scripts/make-store-screenshots.py
"""

from PIL import Image, ImageDraw, ImageFont, ImageFilter
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "marketing" / "store-screenshots"

W, H = 1320, 2868
BG = (250, 250, 250)
INK = (10, 10, 10)
MUTED = (110, 110, 112)
BEZEL = (18, 18, 20)

# Bodoni 72 Book, not Didot: Vero's headline has a descending hooked J and
# a heavier hairline contrast that Didot Regular renders too delicately.
SERIF = "/System/Library/Fonts/Supplemental/Bodoni 72.ttc"
SERIF_INDEX = 0
SANS = "/System/Library/Fonts/Supplemental/Helvetica.ttc"
SANS_BOLD = "/System/Library/Fonts/Supplemental/Helvetica.ttc"

MARGIN = 96
HEAD_TOP = 150

# The phone: wide enough to read the UI, tall enough to run off the bottom
# so the frame never looks like a sticker sitting in space.
PHONE_W = 940
PHONE_TOP = 660
BEZEL_PAD = 16
CORNER = 84

# (source file, headline, subhead)
SHOTS = [
    ("Payday Screenshot 1.png", "Know your\nnumber.",
     "Every shift adds up live, long before payday."),
    ("Payday Screenshot 6.png", "Which nights\nactually pay.",
     "Saturdays average $322. Tuesdays, $119."),
    ("Payday Screenshot 3.png", "Check their\nmath.",
     "Payday predicts your tips line, then flags a short check."),
    ("Payday Screenshot 4.png", "Your month,\nat a glance.",
     "The brighter the night, the better it paid."),
    ("Payday Screenshot 7.png", "Log a shift\nin seconds.",
     "Cash, credit, done. The rest is optional."),
    ("Payday Screenshot 2.png", "Nothing\nhidden.",
     "Cash, credit, tip-out, wages. The math is one tap away."),
    ("Payday Screenshot 5.png", "Know what\nnext week holds.",
     "Built from the nights you actually work."),
]


def tracked_text(draw, origin, text, font, fill, tracking):
    """PIL has no letter-spacing, and the subhead's air is half its
    character — so the glyphs get placed one at a time."""
    x, y = origin
    for char in text:
        draw.text((x, y), char, font=font, fill=fill)
        x += draw.textlength(char, font=font) + tracking


def rounded_mask(size, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255)
    return mask


def compose(src: Path, headline: str, subhead: str, dest: Path):
    canvas = Image.new("RGB", (W, H), BG)
    draw = ImageDraw.Draw(canvas)

    head_font = ImageFont.truetype(SERIF, 126, index=SERIF_INDEX)
    sub_font = ImageFont.truetype(SANS, 44)

    y = HEAD_TOP
    for line in headline.split("\n"):
        draw.text((MARGIN, y), line, font=head_font, fill=INK)
        y += 138
    tracked_text(draw, (MARGIN, y + 52), subhead, sub_font, MUTED, tracking=2.4)

    shot = Image.open(src).convert("RGB")
    scale = PHONE_W / shot.width
    shot = shot.resize((PHONE_W, int(shot.height * scale)), Image.LANCZOS)
    shot.putalpha(rounded_mask(shot.size, CORNER - BEZEL_PAD))

    frame_size = (shot.width + BEZEL_PAD * 2, shot.height + BEZEL_PAD * 2)
    frame = Image.new("RGBA", frame_size, (0, 0, 0, 0))
    ImageDraw.Draw(frame).rounded_rectangle(
        [0, 0, frame_size[0] - 1, frame_size[1] - 1], radius=CORNER, fill=BEZEL + (255,)
    )
    frame.paste(shot, (BEZEL_PAD, BEZEL_PAD), shot)

    x = (W - frame_size[0]) // 2

    # A soft shadow so the device sits on the field instead of floating.
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [x + 10, PHONE_TOP + 24, x + frame_size[0] - 10, PHONE_TOP + frame_size[1]],
        radius=CORNER, fill=(0, 0, 0, 46),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(38))
    canvas.paste(Image.alpha_composite(canvas.convert("RGBA"), shadow).convert("RGB"), (0, 0))

    canvas.paste(frame, (x, PHONE_TOP), frame)
    canvas.save(dest, "PNG")
    return dest


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for index, (name, head, sub) in enumerate(SHOTS, start=1):
        src = REPO / name
        if not src.exists():
            print(f"missing: {name}")
            continue
        slug = head.replace("\n", " ").rstrip(".").lower().replace(" ", "-")
        dest = OUT / f"{index:02d}-{slug}.png"
        compose(src, head, sub, dest)
        print(f"wrote {dest.name}")


if __name__ == "__main__":
    main()
