#!/usr/bin/env python3
"""Generate client/boot_splash.png, the static Godot boot splash.

The splash is compiled into the APK's main pack, so it can be shown by the
engine before game.pck is mounted. Keep it free of external fonts: this uses
a Windows UI font when available and falls back to PIL's bitmap font.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "client" / "boot_splash.png"
W, H = 1280, 720

BG = (6, 13, 21)
MINT = (99, 230, 164)
TEXT = (233, 241, 250)
MUTED = (142, 164, 191)
RED = (219, 51, 64)
WHITE = (230, 240, 249)
INK = (13, 20, 28)


def font(name: str, size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    for candidate in (
        Path("C:/Windows/Fonts") / name,
        Path("C:/Windows/Fonts/segoeui.ttf"),
        Path("C:/Windows/Fonts/arial.ttf"),
    ):
        if candidate.exists():
            try:
                return ImageFont.truetype(str(candidate), size)
            except OSError:
                continue
    return ImageFont.load_default()


def main() -> None:
    image = Image.new("RGB", (W, H), BG)
    draw = ImageDraw.Draw(image, "RGBA")

    # Soft vertical gradient so the flat background does not band.
    for y in range(H):
        t = y / max(1, H - 1)
        shade = int(6 + 16 * (1.0 - abs(t - 0.42) * 2.0))
        draw.line([(0, y), (W, y)], fill=(shade, shade + 7, shade + 14))

    # Smooth mint glow behind the ball: one soft ellipse on its own layer,
    # blurred, then composited (drawing concentric alpha circles bands).
    cx, cy, r = W // 2, 210, 92
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow, "RGBA")
    glow_draw.ellipse(
        (cx - 300, cy - 300, cx + 300, cy + 300), fill=(*MINT, 54)
    )
    glow_draw.ellipse(
        (cx - 170, cy - 170, cx + 170, cy + 170), fill=(*MINT, 46)
    )
    glow = glow.filter(ImageFilter.GaussianBlur(80))
    image = Image.alpha_composite(image.convert("RGBA"), glow).convert("RGB")
    draw = ImageDraw.Draw(image, "RGBA")

    draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(*WHITE, 255))
    draw.pieslice((cx - r, cy - r, cx + r, cy + r), 180, 360, fill=(*RED, 255))
    band = 20
    draw.rectangle((cx - r, cy - band // 2, cx + r, cy + band // 2), fill=INK)
    draw.ellipse((cx - r, cy - r, cx + r, cy + r), outline=INK, width=6)
    draw.ellipse((cx - 30, cy - 30, cx + 30, cy + 30), fill=INK)
    draw.ellipse((cx - 22, cy - 22, cx + 22, cy + 22), fill=WHITE)
    draw.ellipse((cx - 9, cy - 9, cx + 9, cy + 9), fill=(184, 198, 212))

    title = font("segoeuib.ttf", 62)
    subtitle = font("segoeuib.ttf", 20)
    caption = font("segoeui.ttf", 16)

    def centered(text: str, y: int, typeface, fill) -> None:
        box = draw.textbbox((0, 0), text, font=typeface)
        draw.text(((W - (box[2] - box[0])) / 2, y), text, font=typeface, fill=fill)

    centered("BWMMO", 380, title, TEXT)
    centered("U N O V A   O N L I N E", 462, subtitle, MINT)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    image.save(OUT, optimize=True)
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
