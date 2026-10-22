#!/usr/bin/env python3
"""Собирает растровые шрифты поля (формат BMFont: .fnt + .png) из Golos Text в fonts-src/ (TSV-35).

Connect IQ не рисует свои TTF, поэтому шрифт — картинки с нужными символами. Приём и скрипт взяты из проекта
TN_WatchFace (tools/make_fonts.py). Размеры заданы в пикселях экрана 454 (принятые холсты TSV-34) и
масштабируются на другие стороны экрана; папка resources-<сторона> подбирается в monkey.jungle.
Новый размер или символ — строка в FONTS и повторный запуск (нужен Pillow):  python3 tools/make_fonts.py
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
BASE = 454
# ширина экрана (у прямоугольных Venu Sq 2 и Venu X1 — меньшая сторона, у полукруглого fr735xt 215×180 — ширина:
# sc() в коде масштабирует по ширине); модели — manifest.xml, папки — monkey.jungle
SIDES = [454, 260, 218, 240, 280, 320, 360, 390, 416, 448, 466, 215]
TTF = "golos/GolosText[wght].ttf"

# id, размер в px (на экране 454), символы
FONTS = [
    ("tiny", 16, "0123456789:.,-hlacte", 700),
    ("row", 20, "0123456789:.,- /kmilacteonLupv", 500),
    ("error", 20, "0123456789:.,- /()+\"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", 500),
    ("number", 20, "0123456789:.,-hlacte", 700),
    ("near", 24, "0123456789:.,-h", 600),
    ("dist", 36, "0123456789:.,-h", 600),
    ("distmax", 40, "0123456789:.,-h", 600),
    ("active", 48, "0123456789:.,-h", 600),
    ("big", 64, "0123456789:.,-h", 500),
    ("max", 72, "0123456789:.,-h", 600),
    ("key", 38, "0123456789:.,+-/ kmiOKh", 500),
    ("ok", 38, "OK", 600),
    ("live", 16, "LIVE", 600),
]


def build(out, name, size, chars, weight):
    out.mkdir(parents=True, exist_ok=True)
    font = ImageFont.truetype(str(ROOT / "fonts-src" / TTF), size)
    font.set_variation_by_axes([weight])
    chars = "".join(dict.fromkeys(chars))
    ascent, descent = font.getmetrics()

    glyphs = []
    for ch in chars:
        left, top, right, bottom = font.getbbox(ch)
        w, h = max(right - left, 1), max(bottom - top, 1)
        img = Image.new("L", (w, h), 0)
        ImageDraw.Draw(img).text((-left, -top), ch, font=font, fill=255)
        glyphs.append((ch, img, left, top, round(font.getlength(ch))))

    # Высокие знаки первыми: иначе единственная h создаёт целый второй ряд,
    # удваивая атлас MAX и вызывая OOM на 32 КБ (TSV-35).
    glyphs.sort(key=lambda glyph: glyph[1].height, reverse=True)
    def pack(width):
        x, y, shelf, positions = 1, 1, 0, []
        for _, img, *_ in glyphs:
            if x + img.width + 1 > width:
                x, y, shelf = 1, y + shelf + 1, 0
            positions.append((x, y))
            x += img.width + 1
            shelf = max(shelf, img.height)
        return width * (y+shelf+1), width, y+shelf+1, positions

    _, atlas_w, atlas_h, places = min(
        (pack(width) for width in range(64, 513, 32)), key=lambda layout: layout[0])

    alpha = Image.new("L", (atlas_w, atlas_h), 0)
    for (ch, img, *_), (px, py) in zip(glyphs, places):
        alpha.paste(img, (px, py))
    # Garmin берёт покрытие из яркости PNG, не из alpha: RGBA с белым RGB
    # превращал сглаженные края в ступеньки, несмотря на antialias=true (TSV-35).
    png = alpha
    png.save(out / f"{name}.png", optimize=True)

    lines = [
        f'info face="{name}" size={size} bold=0 italic=0 charset="" unicode=1 stretchH=100 smooth=1 aa=1 '
        f'padding=0,0,0,0 spacing=1,1',
        f"common lineHeight={ascent + descent} base={ascent} scaleW={atlas_w} scaleH={atlas_h} pages=1 packed=0",
        f'page id=0 file="{name}.png"',
        f"chars count={len(glyphs)}",
    ]
    for (ch, img, left, top, adv), (px, py) in zip(glyphs, places):
        lines.append(f"char id={ord(ch)} x={px} y={py} width={img.width} height={img.height} "
                     f"xoffset={left} yoffset={top} xadvance={adv} page=0 chnl=15")
    (out / f"{name}.fnt").write_text("\n".join(lines) + "\n")
    # высота цифры нужна коду, чтобы ставить числа по середине строки (DIGIT_H в TNSplitsViewApp.mc)
    dl, dt, dr, db = font.getbbox("0")
    print(f"{name} @{size}: {len(glyphs)} символов, атлас {atlas_w}×{atlas_h}, высота строки {ascent + descent}, "
          f"ascent {ascent}, высота цифры {db - dt}")


if __name__ == "__main__":
    for side in SIDES:
        for name, size, chars, weight in FONTS:
            build(ROOT / f"resources-{side}" / "fonts", name, round(size * (180 if side == 215 else side) / BASE), chars, weight)
        (ROOT / f"resources-{side}" / "fonts" / "fonts.xml").write_text(
            "<fonts>\n    <!-- Собраны tools/make_fonts.py из fonts-src/; руками не править. -->\n"
            + "".join(f'    <font id="{n.capitalize()}" filename="{n}.fnt" antialias="{str(side not in (215, 218, 240, 260)).lower()}"/>\n' for n, _, _, _ in FONTS)
            + "</fonts>\n")
