#!/usr/bin/env python3
"""Generate the LectureGuard launcher icons and splash mark.

The artwork mirrors ``branding/lectureguard_icon.svg``: a teal gradient tile with
a white shield, three wifi arcs and a green verified badge. Drawing it with
Pillow keeps the asset set reproducible without an SVG rasteriser:

    python3 tool/generate_app_icons.py

Outputs (all overwritten, nothing else is touched):

    android/app/src/main/res/mipmap-<density>/ic_launcher.png
    android/app/src/main/res/mipmap-<density>/ic_launcher_round.png
    android/app/src/main/res/mipmap-<density>/ic_launcher_foreground.png
    android/app/src/main/res/mipmap-<density>/ic_launcher_monochrome.png
    android/app/src/main/res/drawable-<density>/splash_logo.png
    assets/branding/app_icon.png  (in-app mark for the sign-in screen)
    ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png
"""

import json
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
ANDROID_RES = ROOT / "android/app/src/main/res"
IOS_ICONS = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"

# The SVG is authored on a 1024x1024 canvas; every coordinate below is in that
# space and scaled by ``k`` when rendered.
DESIGN = 1024
SUPERSAMPLE = 4

TEAL_LIGHT = (0x14, 0xB8, 0xA6)
TEAL_DARK = (0x0B, 0x4F, 0x4A)
ARC_TEAL = (0x0F, 0x76, 0x6E)
WHITE = (0xFF, 0xFF, 0xFF)
GREEN = (0x16, 0xA3, 0x4A)

DENSITIES = {
    "mdpi": 1.0,
    "hdpi": 1.5,
    "xhdpi": 2.0,
    "xxhdpi": 3.0,
    "xxxhdpi": 4.0,
}


def _bezier(p0, p1, p2, p3, steps=96):
    """Sample a cubic bezier so the shield outline can be filled as a polygon."""
    points = []
    for index in range(1, steps + 1):
        t = index / steps
        u = 1 - t
        points.append(
            (
                u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0],
                u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1],
            )
        )
    return points


# M512 190 L742 270 V500 C742 660 640 770 512 835 C384 770 282 660 282 500 V270 Z
SHIELD = (
    [(512, 190), (742, 270), (742, 500)]
    + _bezier((742, 500), (742, 660), (640, 770), (512, 835))
    + _bezier((512, 835), (384, 770), (282, 660), (282, 500))
    + [(282, 270)]
)

ARC_CENTRE = (512, 540)
ARC_RADII = (60, 110, 160)
STEM = ((512, 540), (512, 650))
BADGE_CENTRE = (655, 700)
BADGE_RING_RADIUS = 94
BADGE_RADIUS = 76
CHECK = ((615, 702), (645, 732), (698, 668))

ARC_STROKE = 26
CHECK_STROKE = 22


def _supersample(px):
    """Enough oversampling for smooth edges without huge canvases at 1024px."""
    return SUPERSAMPLE if px <= 128 else 2


def _blank(canvas_px):
    return Image.new("L", (canvas_px, canvas_px), 0)


def _stroke(draw, points, width):
    """Draw a round-capped, round-joined polyline into an alpha mask."""
    radius = width / 2
    for start, end in zip(points, points[1:]):
        draw.line([start, end], fill=255, width=max(1, round(width)))
    for x, y in points:
        draw.ellipse([x - radius, y - radius, x + radius, y + radius], fill=255)


def _art_masks(canvas_px):
    k = canvas_px / DESIGN

    def scale(point):
        return (point[0] * k, point[1] * k)

    shield = _blank(canvas_px)
    ImageDraw.Draw(shield).polygon([scale(point) for point in SHIELD], fill=255)

    arcs = _blank(canvas_px)
    draw = ImageDraw.Draw(arcs)
    centre = scale(ARC_CENTRE)
    stroke = ARC_STROKE * k
    for radius in ARC_RADII:
        scaled = radius * k
        # SVG strokes straddle the path radius; PIL's arc width grows inward
        # from the bounding box, so the box has to be the outer edge.
        outer = scaled + stroke / 2
        draw.arc(
            [
                centre[0] - outer,
                centre[1] - outer,
                centre[0] + outer,
                centre[1] + outer,
            ],
            start=180,
            end=360,
            fill=255,
            width=max(1, round(stroke)),
        )
        for x in (centre[0] - scaled, centre[0] + scaled):
            draw.ellipse(
                [x - stroke / 2, centre[1] - stroke / 2, x + stroke / 2, centre[1] + stroke / 2],
                fill=255,
            )
    _stroke(draw, [scale(point) for point in STEM], stroke)

    badge_centre = scale(BADGE_CENTRE)
    ring = _blank(canvas_px)
    ring_radius = BADGE_RING_RADIUS * k
    ImageDraw.Draw(ring).ellipse(
        [
            badge_centre[0] - ring_radius,
            badge_centre[1] - ring_radius,
            badge_centre[0] + ring_radius,
            badge_centre[1] + ring_radius,
        ],
        fill=255,
    )

    badge = _blank(canvas_px)
    badge_radius = BADGE_RADIUS * k
    ImageDraw.Draw(badge).ellipse(
        [
            badge_centre[0] - badge_radius,
            badge_centre[1] - badge_radius,
            badge_centre[0] + badge_radius,
            badge_centre[1] + badge_radius,
        ],
        fill=255,
    )

    check = _blank(canvas_px)
    _stroke(ImageDraw.Draw(check), [scale(point) for point in CHECK], CHECK_STROKE * k)

    return shield, arcs, ring, badge, check


def _layer(mask, colour):
    layer = Image.new("RGBA", mask.size, colour + (0,))
    layer.putalpha(mask)
    return layer


def render_mark(
    px,
    *,
    arcs="solid",
    monochrome=False,
    shield=WHITE,
    arc=ARC_TEAL,
    ring=WHITE,
    badge=GREEN,
    check=WHITE,
):
    """Render the mark on a transparent canvas: shield, arcs and verified badge."""
    shield_mask, arc_mask, ring_mask, badge_mask, check_mask = _art_masks(
        px * _supersample(px)
    )

    if monochrome:
        # Themed icons are tinted from alpha alone, so the mark is a single
        # silhouette: the arcs and the check are punched out of the union of the
        # shield and the badge ring.
        body = ImageChops.lighter(
            ImageChops.subtract(shield_mask, arc_mask), ring_mask
        )
        body = ImageChops.subtract(body, check_mask)
        mark = _layer(body, WHITE)
    else:
        body = ImageChops.subtract(shield_mask, arc_mask) if arcs == "cut" else shield_mask
        mark = _layer(body, shield)
        if arcs != "cut":
            mark.alpha_composite(_layer(arc_mask, arc))
        mark.alpha_composite(_layer(ring_mask, ring))
        mark.alpha_composite(_layer(badge_mask, badge))
        mark.alpha_composite(_layer(check_mask, check))

    return mark.resize((px, px), Image.LANCZOS)


def _gradient(px):
    """Diagonal teal gradient matching the SVG's #14B8A6 -> #0B4F4A fill."""
    resolution = 128
    small = Image.new("RGB", (resolution, resolution))
    pixels = small.load()
    for y in range(resolution):
        for x in range(resolution):
            t = (x + y) / (2 * (resolution - 1))
            pixels[x, y] = tuple(
                round(start + (end - start) * t)
                for start, end in zip(TEAL_LIGHT, TEAL_DARK)
            )
    return small.resize((px, px), Image.BICUBIC)


def _tile_mask(px, *, rounded=0.0, circle=False):
    big = Image.new("L", (px * _supersample(px), px * _supersample(px)), 0)
    draw = ImageDraw.Draw(big)
    edge = px * _supersample(px) - 1
    if circle:
        draw.ellipse([0, 0, edge, edge], fill=255)
    else:
        draw.rounded_rectangle(
            [0, 0, edge, edge],
            radius=round(edge * rounded),
            fill=255,
        )
    return big.resize((px, px), Image.LANCZOS)


def render_tile(px, *, rounded=0.0, circle=False):
    """Square app icon: gradient tile plus the mark."""
    tile = _gradient(px).convert("RGBA")
    tile.alpha_composite(render_mark(px))
    if circle or rounded:
        tile.putalpha(_tile_mask(px, rounded=rounded, circle=circle))
    return tile


def render_adaptive(px, *, monochrome=False):
    """Adaptive-icon layer on the 108dp canvas; art inside the 66dp safe zone."""
    inner = round(px * 0.92)
    layer = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    offset = (px - inner) // 2
    layer.alpha_composite(render_mark(inner, monochrome=monochrome), (offset, offset))
    return layer


def main():
    for density, scale in DENSITIES.items():
        mipmap = ANDROID_RES / f"mipmap-{density}"
        mipmap.mkdir(parents=True, exist_ok=True)
        render_tile(round(48 * scale), rounded=0.18).save(mipmap / "ic_launcher.png")
        render_tile(round(48 * scale), circle=True).save(mipmap / "ic_launcher_round.png")
        render_adaptive(round(108 * scale)).save(mipmap / "ic_launcher_foreground.png")
        render_adaptive(round(108 * scale), monochrome=True).save(
            mipmap / "ic_launcher_monochrome.png"
        )

        drawable = ANDROID_RES / f"drawable-{density}"
        drawable.mkdir(parents=True, exist_ok=True)
        render_mark(round(160 * scale), arcs="cut").save(drawable / "splash_logo.png")

    app_assets = ROOT / "assets/branding"
    app_assets.mkdir(parents=True, exist_ok=True)
    render_tile(512, rounded=0.18).save(app_assets / "app_icon.png")

    contents = json.loads((IOS_ICONS / "Contents.json").read_text())
    for image in contents["images"]:
        side = float(image["size"].split("x")[0])
        pixels = round(side * int(image["scale"].rstrip("x")))
        # App Store icons must not carry an alpha channel.
        render_tile(pixels).convert("RGB").save(IOS_ICONS / image["filename"])

    print(
        "LectureGuard icons written to android/app/src/main/res "
        "and the iOS asset catalog"
    )


if __name__ == "__main__":
    main()
