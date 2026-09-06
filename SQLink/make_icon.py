#!/usr/bin/env python3
"""Generate SQLink AppIcon (1024x1024 PNG) — clean, modern iOS style.

Design:
  - iOS squircle mask with a vivid diagonal blue->cyan gradient
  - subtle top radial sheen
  - a glossy white 3-tier database cylinder centered, with rim highlights
  - a small "link" accent dot+line near the top to hint "remote connection"

Rendered at 2x (2048) then downscaled to 1024 with LANCZOS for crisp edges.
"""
from PIL import Image, ImageDraw, ImageFilter

SS = 2048          # supersample size
OUT = 1024         # final size

# ---- palette ----
TOP    = (43, 108, 255)    # #2B6CFF vivid blue
BOT    = (24, 196, 255)    # #18C4FF cyan
SHEEN  = (255, 255, 255)
GLOSS_HI = (255, 255, 255)
GLOSS_LO = (205, 232, 255)
RIM    = (255, 255, 255)
DIV    = (70, 130, 205)


def lerp(a, b, t):
    return int(a + (b - a) * t)


def rounded_rect_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def diagonal_gradient(size, c0, c1):
    """small gradient then upscale -> smooth & fast"""
    small = Image.new("RGB", (256, 256))
    sp = small.load()
    for y in range(256):
        for x in range(256):
            t = (x / 255 + y / 255) / 2.0
            sp[x, y] = (lerp(c0[0], c1[0], t),
                        lerp(c0[1], c1[1], t),
                        lerp(c0[2], c1[2], t))
    return small.resize((size, size), Image.BICUBIC)


def build():
    # base gradient
    base = diagonal_gradient(SS, TOP, BOT).convert("RGBA")

    # top radial sheen (soft white glow, upper area)
    sheen = Image.new("L", (SS, SS), 0)
    sd = ImageDraw.Draw(sheen)
    cx_s, cy_s = SS * 0.32, SS * 0.20
    r_s = SS * 0.55
    sd.ellipse([cx_s - r_s, cy_s - r_s, cx_s + r_s, cy_s + r_s], fill=255)
    sheen = sheen.filter(ImageFilter.GaussianBlur(SS * 0.18))
    white = Image.new("RGBA", (SS, SS), SHEEN + (0,))
    glow = Image.composite(white, Image.new("RGBA", (SS, SS), (0, 0, 0, 0)),
                            sheen.point(lambda p: int(p * 0.20)))
    base = Image.alpha_composite(base, glow)

    # ---- database cylinder glyph ----
    glyph = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
    cx = SS // 2
    rx = int(SS * 0.235)          # half width
    ry = int(SS * 0.082)          # cap ellipse vertical radius
    top_y = int(SS * 0.345)
    bot_y = int(SS * 0.675)
    W = rx * 2

    # gradient fill for the body (white -> light blue, top to bottom)
    body_grad = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
    bg_small = Image.new("RGB", (1, 256))
    bp = bg_small.load()
    for y in range(256):
        t = y / 255
        bp[0, y] = (lerp(GLOSS_HI[0], GLOSS_LO[0], t),
                    lerp(GLOSS_HI[1], GLOSS_LO[1], t),
                    lerp(GLOSS_HI[2], GLOSS_LO[2], t))
    body_grad = bg_small.resize((SS, SS), Image.BICUBIC).convert("RGBA")
    # mask for cylinder shape
    cmask = Image.new("L", (SS, SS), 0)
    cd = ImageDraw.Draw(cmask)
    cd.rectangle([cx - rx, top_y, cx + rx - 1, bot_y], fill=255)
    cd.ellipse([cx - rx, top_y - ry, cx + rx - 1, top_y + ry - 1], fill=255)
    cd.ellipse([cx - rx, bot_y - ry, cx + rx - 1, bot_y + ry - 1], fill=255)
    cmask = cmask.filter(ImageFilter.GaussianBlur(2))
    body = Image.composite(body_grad, Image.new("RGBA", (SS, SS), (0, 0, 0, 0)), cmask)
    # give body a slight uniform alpha so it reads as a solid object
    body_alpha = body.point(lambda p: int(p * 0.96) if p > 0 else 0) if False else body
    glyph = Image.alpha_composite(glyph, body)

    gd = ImageDraw.Draw(glyph)
    # divider ellipses (3 tiers)
    for frac in (1 / 3, 2 / 3):
        y = int(top_y + (bot_y - top_y) * frac)
        gd.ellipse([cx - rx, y - ry, cx + rx - 1, y + ry - 1],
                   outline=DIV + (110,), width=max(2, int(SS * 0.006)))
    # top cap rim highlight (bright)
    gd.ellipse([cx - rx, top_y - ry, cx + rx - 1, top_y + ry - 1],
               outline=RIM + (255,), width=max(3, int(SS * 0.011)))
    # left vertical highlight stripe
    stripe = Image.new("L", (SS, SS), 0)
    sl = ImageDraw.Draw(stripe)
    sl.rounded_rectangle([cx - rx + int(SS * 0.02), top_y,
                          cx - rx + int(SS * 0.075), bot_y],
                         radius=int(SS * 0.02), fill=255)
    stripe = stripe.filter(ImageFilter.GaussianBlur(SS * 0.02))
    hi = Image.composite(Image.new("RGBA", (SS, SS), (255, 255, 255, 120)),
                         Image.new("RGBA", (SS, SS), (0, 0, 0, 0)), stripe)
    glyph = Image.alpha_composite(glyph, hi)

    # composite glyph over base
    base = Image.alpha_composite(base, glyph)

    # ---- squircle mask ----
    radius = int(SS * 0.225)
    mask = rounded_rect_mask(SS, radius)
    bg_layer = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
    base = Image.composite(base, bg_layer, mask)

    # subtle inner border (top light edge)
    border = Image.new("L", (SS, SS), 0)
    bd = ImageDraw.Draw(border)
    bd.rounded_rectangle([2, 2, SS - 3, SS - 3], radius=radius - 2,
                         outline=255, width=max(2, int(SS * 0.006)))
    border = border.filter(ImageFilter.GaussianBlur(SS * 0.004))
    edge = Image.composite(Image.new("RGBA", (SS, SS), (255, 255, 255, 60)),
                           Image.new("RGBA", (SS, SS), (0, 0, 0, 0)), border)
    base = Image.alpha_composite(base, edge)

    # downscale to final
    final = base.resize((OUT, OUT), Image.LANCZOS)
    return final


if __name__ == "__main__":
    out = "SQLink/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
    build().save(out, "PNG")
    print("saved", out)
