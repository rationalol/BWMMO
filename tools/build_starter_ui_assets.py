#!/usr/bin/env python3
"""Build the starter-selection scene art.

The starter cutscene is a full-screen presentation, so its backdrop, gift box
and Poké Ball are generated here instead of being assembled from small UI
widgets. Everything is drawn at 3x and downsampled, which keeps the curves and
ribbons smooth at the 960x540 design size.

Outputs (tracked in git, unlike client/assets/bw):
  client/assets/ui/starter/room_bg.png
  client/assets/ui/starter/gift_box.png
  client/assets/ui/starter/poke_ball.png
  client/assets/ui/starter/glow.png
"""

from __future__ import annotations

import math
import random
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "client" / "assets" / "ui" / "starter"
SS = 3


def _s(value: float) -> float:
    return value * SS


def _rgba(color: tuple[int, int, int] | tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    if len(color) == 4:
        return color
    return (color[0], color[1], color[2], 255)


def new_canvas(width: int, height: int) -> Image.Image:
    return Image.new("RGBA", (width * SS, height * SS), (0, 0, 0, 0))


def finish(image: Image.Image, width: int, height: int) -> Image.Image:
    return image.resize((width, height), Image.LANCZOS)


def vertical_gradient(
    width: int,
    height: int,
    top: tuple[int, int, int],
    bottom: tuple[int, int, int],
) -> Image.Image:
    rows = np.linspace(0.0, 1.0, height, dtype=np.float32)[:, None]
    colors = np.array(top, dtype=np.float32)[None, :] * (1.0 - rows) + np.array(
        bottom, dtype=np.float32
    )[None, :] * rows
    pixels = np.repeat(colors[:, None, :], width, axis=1).astype(np.uint8)
    return Image.fromarray(pixels, "RGB").convert("RGBA")


def radial_glow(
    size: int,
    color: tuple[int, int, int],
    alpha: int,
    falloff: float = 2.0,
    aspect: float = 1.0,
) -> Image.Image:
    width = size
    height = max(1, int(size * aspect))
    yy, xx = np.mgrid[0:height, 0:width].astype(np.float32)
    cx = (width - 1) * 0.5
    cy = (height - 1) * 0.5
    nx = (xx - cx) / max(cx, 1.0)
    ny = (yy - cy) / max(cy, 1.0)
    distance = np.sqrt(nx * nx + ny * ny)
    strength = np.clip(1.0 - distance, 0.0, 1.0) ** falloff
    alpha_channel = (strength * alpha).astype(np.uint8)
    rgba = np.zeros((height, width, 4), dtype=np.uint8)
    rgba[:, :, 0] = color[0]
    rgba[:, :, 1] = color[1]
    rgba[:, :, 2] = color[2]
    rgba[:, :, 3] = alpha_channel
    return Image.fromarray(rgba, "RGBA")


def polygon_mask(
    image: Image.Image, points: list[tuple[float, float]]
) -> Image.Image:
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).polygon([(_s(x), _s(y)) for x, y in points], fill=255)
    return mask


def polygon_gradient(
    image: Image.Image,
    points: list[tuple[float, float]],
    top: tuple[int, int, int],
    bottom: tuple[int, int, int],
) -> None:
    xs = [point[0] for point in points]
    ys = [point[1] for point in points]
    x0, x1 = int(min(xs)), int(max(xs)) + 1
    y0, y1 = int(min(ys)), int(max(ys)) + 1
    patch = vertical_gradient(x1 - x0, y1 - y0, top, bottom)
    mask = polygon_mask(image, points).crop(
        (int(_s(x0)), int(_s(y0)), int(_s(x1)), int(_s(y1)))
    )
    image.paste(patch.resize(mask.size, Image.LANCZOS), (int(_s(x0)), int(_s(y0))), mask)


def draw_polygon(
    image: Image.Image,
    points: list[tuple[float, float]],
    fill: tuple[int, int, int] | tuple[int, int, int, int] | None,
    outline: tuple[int, int, int] | None = None,
    width: float = 4.0,
) -> None:
    draw = ImageDraw.Draw(image)
    scaled = [(_s(x), _s(y)) for x, y in points]
    if fill is not None:
        draw.polygon(scaled, fill=_rgba(fill))
    if outline is not None:
        draw.line(scaled + [scaled[0]], fill=_rgba(outline), width=int(_s(width)), joint="curve")


def draw_ellipse(
    image: Image.Image,
    bbox: tuple[float, float, float, float],
    fill: tuple[int, int, int] | tuple[int, int, int, int] | None,
    outline: tuple[int, int, int] | None = None,
    width: float = 4.0,
) -> None:
    draw = ImageDraw.Draw(image)
    scaled = tuple(_s(value) for value in bbox)
    draw.ellipse(scaled, fill=_rgba(fill) if fill is not None else None, outline=outline, width=int(_s(width)))


def glow_layer(
    image: Image.Image,
    bbox: tuple[float, float, float, float],
    color: tuple[int, int, int],
    alpha: int,
    blur: float,
) -> None:
    layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    draw.ellipse(tuple(_s(value) for value in bbox), fill=(*color, alpha))
    layer = layer.filter(ImageFilter.GaussianBlur(_s(blur)))
    image.alpha_composite(layer)


def build_room() -> Image.Image:
    width, height = 960, 540
    canvas = new_canvas(width, height)
    wall = vertical_gradient(width * SS, height * SS, (21, 14, 31), (74, 42, 58))
    canvas.alpha_composite(wall)

    # A warm pool of morning light sits behind the gift so the box reads first.
    halo = radial_glow(width * SS, (255, 201, 116), 46, falloff=1.9, aspect=0.62)
    canvas.alpha_composite(halo, (0, -int(_s(70))))

    # Wallpaper seams stay barely visible; they add depth without competing.
    seams = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    seam_draw = ImageDraw.Draw(seams)
    for x in range(48, width, 76):
        seam_draw.line(
            [(_s(x), 0), (_s(x), _s(300))],
            fill=(255, 224, 190, 8),
            width=max(1, int(_s(0.7))),
        )
    canvas.alpha_composite(seams)

    # Out-of-focus bokeh suggests the bedroom without drawing detailed props.
    rng = random.Random(1171)
    bokeh = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    bokeh_draw = ImageDraw.Draw(bokeh)
    for _ in range(26):
        radius = rng.uniform(8, 42)
        cx = rng.uniform(40, width - 40)
        cy = rng.uniform(24, 262)
        color = rng.choice([(255, 219, 158), (255, 173, 148), (213, 165, 255)])
        bokeh_draw.ellipse(
            [(_s(cx - radius), _s(cy - radius)), (_s(cx + radius), _s(cy + radius))],
            fill=(*color, rng.randint(7, 18)),
        )
    bokeh = bokeh.filter(ImageFilter.GaussianBlur(_s(5)))
    canvas.alpha_composite(bokeh)

    # Diagonal light shaft from the upper left.
    shaft = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shaft_draw = ImageDraw.Draw(shaft)
    shaft_draw.polygon(
        [
            (_s(-80), _s(-20)),
            (_s(360), _s(-20)),
            (_s(720), _s(330)),
            (_s(300), _s(360)),
        ],
        fill=(255, 235, 190, 13),
    )
    shaft = shaft.filter(ImageFilter.GaussianBlur(_s(26)))
    canvas.alpha_composite(shaft)

    # Desk: a walnut surface with a soft lit back edge.
    desk_top = 300
    desk = vertical_gradient(width * SS, (height - desk_top) * SS, (68, 42, 31), (26, 15, 12))
    canvas.alpha_composite(desk, (0, int(_s(desk_top))))
    draw = ImageDraw.Draw(canvas)
    draw.line(
        [(_s(0), _s(desk_top)), (_s(width), _s(desk_top))],
        fill=(207, 150, 93, 70),
        width=max(1, int(_s(1.4))),
    )
    draw.line(
        [(_s(0), _s(desk_top + 5)), (_s(width), _s(desk_top + 5))],
        fill=(38, 23, 19, 110),
        width=max(1, int(_s(2))),
    )

    grain = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    grain_draw = ImageDraw.Draw(grain)
    for index in range(34):
        base_y = desk_top + 12 + index * 7.4 + rng.uniform(-2.5, 2.5)
        points: list[tuple[float, float]] = []
        for x in range(-20, width + 40, 24):
            wave = (
                math.sin(x * 0.012 + index * 0.83) * 3.2
                + math.sin(x * 0.031 + index * 1.7) * 1.3
            )
            points.append((x, base_y + wave))
        grain_draw.line(
            [(_s(x), _s(y)) for x, y in points],
            fill=(226, 169, 109, rng.randint(5, 16)),
            width=max(1, int(_s(rng.uniform(0.6, 1.3)))),
        )
    grain = grain.filter(ImageFilter.GaussianBlur(_s(0.5)))
    canvas.alpha_composite(grain)

    # Contact shadow under the box, baked into the backdrop.
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.ellipse(
        [(_s(148), _s(452)), (_s(812), _s(540))],
        fill=(10, 5, 14, 150),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(_s(22)))
    canvas.alpha_composite(shadow)

    # Vignette.
    yy, xx = np.mgrid[0 : height * SS, 0 : width * SS].astype(np.float32)
    nx = (xx - width * SS * 0.5) / (width * SS * 0.5)
    ny = (yy - height * SS * 0.5) / (height * SS * 0.5)
    distance = np.sqrt(nx * nx + ny * ny * 0.82)
    vignette_alpha = (np.clip((distance - 0.48) / 0.62, 0.0, 1.0) ** 1.7 * 150).astype(np.uint8)
    vignette = np.zeros((height * SS, width * SS, 4), dtype=np.uint8)
    vignette[:, :, 3] = vignette_alpha
    canvas.alpha_composite(Image.fromarray(vignette, "RGBA"))

    return finish(canvas, width, height).convert("RGB")


def build_gift_box() -> Image.Image:
    width, height = 800, 600
    canvas = new_canvas(width, height)
    outline = (43, 22, 58)
    gold_outline = (118, 72, 20)

    # Lid leaning open behind the box. It stays low so the partner can float
    # above it without covering the lid's ribbon and bow.
    lid = [(188, 126), (612, 112), (660, 228), (140, 244)]
    polygon_gradient(canvas, lid, (107, 61, 143), (63, 32, 89))
    draw_polygon(canvas, lid, None, outline, 5)
    lid_inner = [(211, 151), (592, 139), (633, 220), (168, 233)]
    polygon_gradient(canvas, lid_inner, (214, 193, 230), (164, 132, 198))
    draw_polygon(canvas, lid_inner, None, (66, 35, 92), 3)
    draw_polygon(
        canvas,
        [(211, 151), (592, 139), (594, 149), (214, 161)],
        (246, 235, 255, 120),
    )

    # Gold ribbon across the lining, following the lid's perspective.
    ribbon = [(385, 124), (423, 122), (432, 232), (390, 235)]
    polygon_gradient(canvas, ribbon, (255, 224, 127), (201, 139, 36))
    draw_polygon(canvas, ribbon, None, gold_outline, 3)
    draw_polygon(
        canvas, [(395, 126), (406, 126), (414, 233), (402, 234)], (255, 246, 199, 145)
    )

    # Bow, tucked behind the lid's top edge.
    left_loop = [(399, 122), (352, 88), (318, 111), (334, 146), (382, 141)]
    right_loop = [(399, 122), (448, 84), (482, 107), (468, 148), (417, 141)]
    for loop in (left_loop, right_loop):
        polygon_gradient(canvas, loop, (255, 227, 133), (207, 143, 37))
        draw_polygon(canvas, loop, None, gold_outline, 4)
    draw_polygon(canvas, [(389, 105), (373, 120), (387, 138), (402, 124)], (255, 238, 166, 110))
    draw_ellipse(canvas, (381, 105, 420, 144), (242, 187, 71), gold_outline, 3)
    draw_ellipse(canvas, (389, 113, 412, 136), (255, 222, 115))
    draw_ellipse(canvas, (394, 117, 404, 126), (255, 246, 205, 220))

    # Box opening: dark interior with a warm patch of light.
    draw_ellipse(canvas, (120, 230, 680, 382), (92, 51, 124), outline, 5)
    draw_ellipse(canvas, (142, 245, 658, 362), (34, 18, 46), (58, 31, 75), 3)
    glow_layer(canvas, (250, 252, 550, 358), (255, 198, 108), 125, 24)
    draw_ellipse(canvas, (142, 245, 658, 362), None, (255, 221, 146, 155), 1.5)

    # Three recesses line up with the Poké Ball buttons drawn by the client.
    for cx in (270, 400, 530):
        draw_ellipse(canvas, (cx - 55, 268, cx + 55, 360), (20, 10, 29, 225))
        draw_ellipse(canvas, (cx - 53, 266, cx + 53, 356), None, (255, 214, 126, 95), 1.5)
        draw_ellipse(canvas, (cx - 43, 279, cx + 43, 340), (14, 7, 21, 120))

    # Front of the box, with a subtle top rim and side shading.
    front = [(116, 330), (684, 330), (716, 528), (84, 528)]
    polygon_gradient(canvas, front, (103, 58, 141), (52, 26, 78))
    draw_polygon(canvas, front, None, outline, 5)
    left_side = [(84, 528), (116, 330), (144, 330), (126, 528)]
    draw_polygon(canvas, left_side, (50, 26, 74, 105))
    right_light = [(656, 330), (684, 330), (716, 528), (686, 528)]
    draw_polygon(canvas, right_light, (156, 98, 194, 65))
    draw_polygon(
        canvas,
        [(124, 334), (676, 334), (679, 350), (121, 350)],
        (190, 130, 221, 75),
    )
    draw_polygon(
        canvas,
        [(121, 350), (679, 350), (680, 358), (121, 358)],
        (43, 22, 59, 130),
    )

    # Gold ribbon: horizontal band and vertical band, then their highlights.
    horizontal = [(88, 402), (712, 402), (715, 458), (86, 458)]
    polygon_gradient(canvas, horizontal, (249, 205, 86), (203, 137, 33))
    draw_polygon(canvas, horizontal, None, gold_outline, 3)
    draw_polygon(canvas, [(92, 410), (711, 410), (711, 421), (91, 421)], (255, 240, 168, 150))
    vertical = [(365, 334), (437, 334), (433, 528), (369, 528)]
    polygon_gradient(canvas, vertical, (255, 218, 103), (197, 128, 28))
    draw_polygon(canvas, vertical, None, gold_outline, 3)
    draw_polygon(canvas, [(379, 336), (394, 336), (391, 528), (381, 528)], (255, 245, 181, 140))

    # Bottom rim and a few corner glints keep the box from reading flat.
    draw_polygon(canvas, [(84, 514), (716, 514), (716, 528), (84, 528)], (34, 17, 50, 190))
    for cx, cy, radius in (
        (116, 353, 6),
        (686, 353, 6),
        (102, 500, 5),
        (700, 500, 5),
    ):
        draw_ellipse(canvas, (cx - radius, cy - radius, cx + radius, cy + radius), (247, 211, 128, 165))

    # A soft sheen on the front face.
    sheen = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    sheen_draw = ImageDraw.Draw(sheen)
    sheen_draw.polygon(
        [(_s(158), _s(362)), (_s(310), _s(362)), (_s(232), _s(514)), (_s(110), _s(514))],
        fill=(255, 238, 255, 17),
    )
    sheen = sheen.filter(ImageFilter.GaussianBlur(_s(9)))
    canvas.alpha_composite(sheen)

    return finish(canvas, width, height)


def build_poke_ball() -> Image.Image:
    size = 96
    scale = 4
    canvas = Image.new("RGBA", (size * scale, size * scale), (0, 0, 0, 0))
    center = size * scale // 2
    radius = int(size * scale * 0.43)
    outline = (31, 27, 36)
    box = (center - radius, center - radius, center + radius, center + radius)

    ball_mask = Image.new("L", canvas.size, 0)
    ImageDraw.Draw(ball_mask).ellipse(box, fill=255)

    # White lower shell.
    body = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(body).ellipse(box, fill=(247, 243, 233))

    # Red cap, clipped to the upper half of the ball circle.
    cap = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    cap_draw = ImageDraw.Draw(cap)
    cap_draw.ellipse(box, fill=(228, 59, 52))
    cap_draw.ellipse(
        [box[0] + 24 * scale, box[1] + 12 * scale, center - 12 * scale, center - 14 * scale],
        fill=(255, 154, 132, 42),
    )
    cap_mask = Image.new("L", canvas.size, 0)
    mask_draw = ImageDraw.Draw(cap_mask)
    mask_draw.rectangle([0, 0, canvas.width, center - int(radius * 0.08)], fill=255)
    cap_mask = ImageChops.multiply(ball_mask, cap_mask)
    body.alpha_composite(Image.composite(cap, Image.new("RGBA", canvas.size), cap_mask))

    # Cool shade at the bottom and a soft rim light on the white shell.
    shade = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shade_draw = ImageDraw.Draw(shade)
    shade_draw.ellipse(
        [box[0] + 5 * scale, center + int(radius * 0.36), box[2] - 5 * scale, box[3] - 2 * scale],
        fill=(185, 178, 168, 95),
    )
    body.alpha_composite(Image.composite(shade, Image.new("RGBA", canvas.size), ball_mask))

    # Black equator band.
    band = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    band_draw = ImageDraw.Draw(band)
    band_draw.rectangle(
        [box[0], center - int(radius * 0.13), box[2], center + int(radius * 0.13)],
        fill=outline,
    )
    body.alpha_composite(Image.composite(band, Image.new("RGBA", canvas.size), ball_mask))

    draw = ImageDraw.Draw(body)
    draw.ellipse(box, outline=outline, width=int(3.2 * scale))
    button_radius = int(radius * 0.32)
    draw.ellipse(
        (center - button_radius, center - button_radius, center + button_radius, center + button_radius),
        fill=outline,
    )
    inner = int(button_radius * 0.72)
    draw.ellipse(
        (center - inner, center - inner, center + inner, center + inner),
        fill=(249, 246, 238),
    )
    draw.ellipse(
        (
            center - int(inner * 0.62),
            center - int(inner * 0.62),
            center + int(inner * 0.62),
            center + int(inner * 0.62),
        ),
        outline=(176, 170, 162),
        width=max(1, int(1.1 * scale)),
    )
    highlight = int(radius * 0.18)
    draw.ellipse(
        (
            center - int(radius * 0.45),
            center - int(radius * 0.60),
            center - int(radius * 0.45) + highlight,
            center - int(radius * 0.60) + highlight,
        ),
        fill=(255, 255, 255, 165),
    )
    draw.arc(
        [box[0] + 2 * scale, box[1] + 2 * scale, box[2] - 2 * scale, box[3] - 2 * scale],
        198,
        330,
        fill=(255, 255, 255, 55),
        width=max(1, int(1.4 * scale)),
    )

    return body.resize((size, size), Image.LANCZOS)


def build_glow() -> Image.Image:
    size = 320
    glow = radial_glow(size, (255, 255, 255), 190, falloff=1.7)
    return glow


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    room = build_room()
    room.save(OUT_DIR / "room_bg.png")

    gift = build_gift_box()
    gift.save(OUT_DIR / "gift_box.png")

    ball = build_poke_ball()
    ball.save(OUT_DIR / "poke_ball.png")

    glow = build_glow()
    glow.save(OUT_DIR / "glow.png")

    for name in ("room_bg.png", "gift_box.png", "poke_ball.png", "glow.png"):
        path = OUT_DIR / name
        print(f"wrote {path.relative_to(ROOT)} ({path.stat().st_size // 1024} KiB)")


if __name__ == "__main__":
    main()
