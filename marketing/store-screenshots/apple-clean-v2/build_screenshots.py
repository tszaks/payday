from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "marketing/store-screenshots/screenshots2/current_screenshots"
OUTPUT = Path(__file__).resolve().parent

WIDTH = 1242
HEIGHT = 2688
INK = (20, 20, 19)
MUTED = (74, 73, 69)

HEADLINE_FONT = "/System/Library/Fonts/NewYork.ttf"
BODY_FONT = "/System/Library/Fonts/Avenir Next.ttc"


FRAMES = [
    {
        "source": "payday_1.png",
        "output": "01-know-what-you-made.png",
        "headline": "Know what you\nactually made.",
        "subtitle": "Tips, wages, overtime, and every shift in one place.",
    },
    {
        "source": "payday_2.png",
        "output": "02-every-dollar-one-view.png",
        "headline": "Every dollar.\nOne view.",
        "subtitle": "See your pay period clearly, before payday.",
    },
    {
        "source": "payday_4.png.png",
        "output": "03-see-which-shifts-pay.png",
        "headline": "See which shifts\npay best.",
        "subtitle": "Compare earnings by day, service, and hour.",
    },
    {
        "source": "payday_5.png.png",
        "output": "04-watch-your-month-add-up.png",
        "headline": "Watch your month\nadd up.",
        "subtitle": "Every shift, total, and best day at a glance.",
    },
    {
        "source": "payday_3.png.png",
        "output": "05-log-a-shift-in-seconds.png",
        "headline": "Log a shift\nin seconds.",
        "subtitle": "Cash, card, and hours. Done.",
    },
]


def centered(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.FreeTypeFont, y: int, fill, spacing=0):
    box = draw.multiline_textbbox((0, 0), text, font=font, spacing=spacing, align="center")
    x = (WIDTH - (box[2] - box[0])) // 2
    draw.multiline_text((x, y), text, font=font, fill=fill, spacing=spacing, align="center")


def render(frame: dict) -> None:
    source = Image.open(SOURCE / frame["source"]).convert("RGB")
    if source.size != (WIDTH, HEIGHT):
        source = source.resize((WIDTH, HEIGHT), Image.Resampling.LANCZOS)

    # Match the source's own warm studio background so the type and device feel
    # like one composition, while preserving every pixel of the real Payday UI.
    background = source.getpixel((28, 28))
    image = Image.new("RGB", (WIDTH, HEIGHT), background)

    # Enlarge the existing studio render and let it run to the lower edge. This
    # is the visual rhythm used by Vero's strongest listing frames: concise copy
    # above, product dominant below, no decorative scene competing for attention.
    visual = source.crop((0, 500, WIDTH, 2250))
    visual_height = HEIGHT - 540
    visual_width = round(visual.width * visual_height / visual.height)
    visual = visual.resize((visual_width, visual_height), Image.Resampling.LANCZOS)
    image.paste(visual, ((WIDTH - visual_width) // 2, 540))

    draw = ImageDraw.Draw(image)
    draw.rectangle((0, 0, WIDTH, 555), fill=background)

    headline = ImageFont.truetype(HEADLINE_FONT, 124)
    body = ImageFont.truetype(BODY_FONT, 35)

    centered(draw, frame["headline"], headline, 82, INK, spacing=-10)
    centered(draw, frame["subtitle"], body, 382, MUTED)

    image.save(OUTPUT / frame["output"], optimize=True)


if __name__ == "__main__":
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for item in FRAMES:
        render(item)
        print(OUTPUT / item["output"])
