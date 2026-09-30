#!/usr/bin/env python3
"""Собирает растровые шрифты поля (формат BMFont: .fnt + .png) из TTF в fonts-src/ (TSV-18).

Connect IQ не рисует свои TTF, поэтому шрифт — картинки с нужными символами. Приём и скрипт взяты из проекта
TN_WatchFace (tools/make_fonts.py). Размеры заданы в пикселях экрана 454 (макет design/mockup.html) и
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
TTF = "courierprime/CourierPrime-Bold.ttf"

# id, размер в px (на экране 454), символы
FONTS = [
    # строка списка: номер, время, дистанция, темп; «-» — темп без данных, «h» — круг от часа («1h05», TSV-29)
    ("row", 26, "0123456789:.,- h"),
    # кнопки ввода («+1», «-0,1», «OK»), центральная строка карусели и подписи карточки («12.34 km», «4:16 /mi»)
    ("key", 38, "0123456789:.,+-/ kmiOKh"),
    # значение лактата и время круга в карточке
    ("big", 64, "0123456789:.,-h"),
]


def build(out, name, size, chars):
    out.mkdir(parents=True, exist_ok=True)
    font = ImageFont.truetype(str(ROOT / "fonts-src" / TTF), size)
    ascent, descent = font.getmetrics()

    glyphs = []
    for ch in chars:
        left, top, right, bottom = font.getbbox(ch)
        w, h = max(right - left, 1), max(bottom - top, 1)
        img = Image.new("L", (w, h), 0)
        ImageDraw.Draw(img).text((-left, -top), ch, font=font, fill=255)
        glyphs.append((ch, img, left, top, round(font.getlength(ch))))

    atlas_w, x, y, shelf = 256, 1, 1, 0
    places = []
    for ch, img, *_ in glyphs:
        if x + img.width + 1 > atlas_w:
            x, y, shelf = 1, y + shelf + 1, 0
        places.append((x, y))
        x += img.width + 1
        shelf = max(shelf, img.height)
    atlas_h = y + shelf + 1

    alpha = Image.new("L", (atlas_w, atlas_h), 0)
    for (ch, img, *_), (px, py) in zip(glyphs, places):
        alpha.paste(img, (px, py))
    png = Image.new("RGBA", (atlas_w, atlas_h), (255, 255, 255, 0))
    png.putalpha(alpha)
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
        for name, size, chars in FONTS:
            build(ROOT / f"resources-{side}" / "fonts", name, round(size * side / BASE), chars)
        (ROOT / f"resources-{side}" / "fonts" / "fonts.xml").write_text(
            "<fonts>\n    <!-- Собраны tools/make_fonts.py из fonts-src/; руками не править. -->\n"
            + "".join(f'    <font id="{n.capitalize()}" filename="{n}.fnt" antialias="true"/>\n' for n, _, _ in FONTS)
            + "</fonts>\n")
