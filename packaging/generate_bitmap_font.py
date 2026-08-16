#!/usr/bin/env python3
"""Generate the AirPOS Unicode BMFont zip used by package:image."""

from __future__ import annotations

import argparse
import math
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path
from xml.etree import ElementTree

from PIL import Image, ImageDraw, ImageFont


ASCII_PRINTABLE = "".join(chr(codepoint) for codepoint in range(0x20, 0x7F))
REQUIRED_GLYPH_GROUPS = {
    "ascii_printable": ASCII_PRINTABLE,
    "vietnamese_latin_extended": "ĐăộƯé",
    "punctuation_currency": "—、。€",
    "hiragana": "あ",
    "katakana": "アフ",
    "cjk": "牛注文",
}
FONT_NAME = "airpos-unicode"


@dataclass(frozen=True)
class Glyph:
    codepoint: int
    x: int
    y: int
    width: int
    height: int
    xoffset: int
    yoffset: int
    xadvance: int
    page: int


def _codepoints() -> list[int]:
    ranges = (
        (0x20, 0x7E),  # ASCII printable
        (0xA0, 0x24F),  # Latin-1 + Latin Extended A/B
        (0x1E00, 0x1EFF),  # Latin Extended Additional, including Vietnamese
        (0x2000, 0x206F),  # General punctuation
        (0x20A0, 0x20CF),  # Currency symbols
        (0x3000, 0x303F),  # CJK symbols and punctuation
        (0x3040, 0x309F),  # Hiragana
        (0x30A0, 0x30FF),  # Katakana
        (0x4E00, 0x9FFF),  # CJK Unified Ideographs
    )
    values: set[int] = set()
    for start, end in ranges:
        values.update(range(start, end + 1))
    values.update(ord(ch) for glyphs in REQUIRED_GLYPH_GROUPS.values() for ch in glyphs)
    return sorted(values)


def _iter_required_glyphs() -> list[tuple[str, str]]:
    return [
        (group_name, ch)
        for group_name, glyphs in REQUIRED_GLYPH_GROUPS.items()
        for ch in glyphs
    ]


def _missing_mask(font: ImageFont.FreeTypeFont) -> tuple[tuple[int, int], bytes]:
    mask = font.getmask("\uFFFF", mode="L")
    return mask.size, bytes(mask)


def _has_glyph(
    font: ImageFont.FreeTypeFont,
    ch: str,
    missing: tuple[tuple[int, int], bytes],
) -> bool:
    if ch in {" ", "\u00A0", "\u3000"}:
        return True
    mask = font.getmask(ch, mode="L")
    return (mask.size, bytes(mask)) != missing


def _build_pages(
    font: ImageFont.FreeTypeFont,
    codepoints: list[int],
    *,
    page_size: int,
    padding: int,
) -> tuple[list[Image.Image], list[Glyph]]:
    page = Image.new("RGBA", (page_size, page_size), (0, 0, 0, 0))
    pages = [page]
    glyphs: list[Glyph] = []
    x = padding
    y = padding
    row_height = 0
    missing = _missing_mask(font)

    for codepoint in codepoints:
        ch = chr(codepoint)
        if not _has_glyph(font, ch, missing):
            continue
        bbox = font.getbbox(ch)
        advance = max(1, math.ceil(font.getlength(ch)))
        if bbox is None:
            glyphs.append(Glyph(codepoint, 0, 0, 0, 0, 0, 0, advance, 0))
            continue
        left, top, right, bottom = bbox
        width = max(0, right - left)
        height = max(0, bottom - top)
        if width == 0 or height == 0:
            glyphs.append(Glyph(codepoint, 0, 0, 0, 0, left, top, advance, 0))
            continue
        if width + (padding * 2) > page_size or height + (padding * 2) > page_size:
            raise SystemExit(
                f"Glyph U+{codepoint:04X} does not fit page size {page_size}."
            )
        if x + width + padding > page_size:
            x = padding
            y += row_height + padding
            row_height = 0
        if y + height + padding > page_size:
            page = Image.new("RGBA", (page_size, page_size), (0, 0, 0, 0))
            pages.append(page)
            x = padding
            y = padding
            row_height = 0

        glyph = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        ImageDraw.Draw(glyph).text(
            (-left, -top),
            ch,
            font=font,
            fill=(0, 0, 0, 255),
        )
        page.alpha_composite(glyph, (x, y))
        glyphs.append(
            Glyph(codepoint, x, y, width, height, left, top, advance, len(pages) - 1)
        )
        x += width + padding
        row_height = max(row_height, height)

    seen_codepoints = {glyph.codepoint for glyph in glyphs}
    for group_name, ch in _iter_required_glyphs():
        if ord(ch) not in seen_codepoints:
            raise SystemExit(
                f"Font is missing required glyph for {group_name}: "
                f"{ch} U+{ord(ch):04X}"
            )

    if not glyphs:
        raise SystemExit("No glyphs generated.")
    return pages, glyphs


def _fnt_xml(
    glyphs: list[Glyph],
    *,
    pages: int,
    page_size: int,
    size: int,
    line_height: int,
    base: int,
) -> bytes:
    font = ElementTree.Element("font")
    ElementTree.SubElement(
        font,
        "info",
        {
            "face": FONT_NAME,
            "size": str(size),
            "bold": "0",
            "italic": "0",
            "charset": "",
            "unicode": "1",
            "stretchH": "100",
            "smooth": "1",
            "aa": "1",
            "padding": "0,0,0,0",
            "spacing": "1,1",
            "outline": "0",
        },
    )
    ElementTree.SubElement(
        font,
        "common",
        {
            "lineHeight": str(line_height),
            "base": str(base),
            "scaleW": str(page_size),
            "scaleH": str(page_size),
            "pages": str(pages),
            "packed": "0",
        },
    )
    pages_node = ElementTree.SubElement(font, "pages")
    for page_id in range(pages):
        ElementTree.SubElement(
            pages_node,
            "page",
            {"id": str(page_id), "file": f"{FONT_NAME}_{page_id}.png"},
        )
    chars_node = ElementTree.SubElement(font, "chars", {"count": str(len(glyphs))})
    for glyph in glyphs:
        ElementTree.SubElement(
            chars_node,
            "char",
            {
                "id": str(glyph.codepoint),
                "x": str(glyph.x),
                "y": str(glyph.y),
                "width": str(glyph.width),
                "height": str(glyph.height),
                "xoffset": str(glyph.xoffset),
                "yoffset": str(glyph.yoffset),
                "xadvance": str(glyph.xadvance),
                "page": str(glyph.page),
                "chnl": "15",
            },
        )
    return ElementTree.tostring(font, encoding="utf-8", xml_declaration=True)


def validate_archive(path: Path) -> None:
    if not path.is_file():
        raise SystemExit(f"Font archive not found: {path}")
    with zipfile.ZipFile(path) as archive:
        fnt_names = [name for name in archive.namelist() if name.endswith(".fnt")]
        if len(fnt_names) != 1:
            raise SystemExit("Font archive must contain exactly one .fnt file.")
        root = ElementTree.fromstring(archive.read(fnt_names[0]))
        common = root.find("common")
        pages = root.findall("./pages/page")
        chars = root.findall("./chars/char")
        if common is None or not pages or not chars:
            raise SystemExit("Font archive is missing common/pages/chars data.")
        if int(common.attrib["pages"]) != len(pages):
            raise SystemExit("Font page count does not match common.pages.")

        page_sizes: dict[int, tuple[int, int]] = {}
        for page in pages:
            page_id = int(page.attrib["id"])
            filename = page.attrib["file"]
            if filename not in archive.namelist():
                raise SystemExit(f"Font archive is missing page image: {filename}")
            with archive.open(filename) as handle:
                with Image.open(handle) as image:
                    image.load()
                    page_sizes[page_id] = image.size

        by_id = {int(char.attrib["id"]): char for char in chars}
        for group_name, ch in _iter_required_glyphs():
            char = by_id.get(ord(ch))
            if char is None:
                raise SystemExit(
                    f"Font archive is missing required glyph for {group_name}: "
                    f"{ch} U+{ord(ch):04X}"
                )
            if ch != " " and (
                int(char.attrib["width"]) <= 0 or int(char.attrib["height"]) <= 0
            ):
                raise SystemExit(
                    f"Required glyph is empty for {group_name}: "
                    f"{ch} U+{ord(ch):04X}"
                )

        for char in chars:
            page_id = int(char.attrib["page"])
            if page_id not in page_sizes:
                raise SystemExit(f"Glyph references missing page: {page_id}")
            width, height = page_sizes[page_id]
            x = int(char.attrib["x"])
            y = int(char.attrib["y"])
            char_width = int(char.attrib["width"])
            char_height = int(char.attrib["height"])
            if x + char_width > width or y + char_height > height:
                raise SystemExit(f"Glyph U+{int(char.attrib['id']):04X} exceeds page bounds.")


def generate(
    font_path: Path,
    output: Path,
    *,
    size: int,
    page_size: int,
    padding: int,
) -> None:
    font = ImageFont.truetype(str(font_path), size)
    ascent, descent = font.getmetrics()
    pages, glyphs = _build_pages(
        font,
        _codepoints(),
        page_size=page_size,
        padding=padding,
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(
            f"{FONT_NAME}.fnt",
            _fnt_xml(
                glyphs,
                pages=len(pages),
                page_size=page_size,
                size=size,
                line_height=ascent + descent,
                base=ascent,
            ),
        )
        for index, page in enumerate(pages):
            with tempfile.SpooledTemporaryFile() as handle:
                page.save(handle, format="PNG", optimize=True)
                handle.seek(0)
                archive.writestr(f"{FONT_NAME}_{index}.png", handle.read())
    validate_archive(output)
    print(f"Generated {output} ({len(glyphs)} glyphs, {len(pages)} pages)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--font", type=Path, help="Noto Sans CJK TTF/TTC source font.")
    parser.add_argument("--output", required=True, type=Path, help="Output .fnt.zip path.")
    parser.add_argument("--size", type=int, default=24)
    parser.add_argument("--page-size", type=int, default=2048)
    parser.add_argument("--padding", type=int, default=1)
    parser.add_argument("--validate-only", action="store_true")
    args = parser.parse_args()

    if args.validate_only:
        validate_archive(args.output)
        print(f"Validated {args.output}")
        return
    if args.font is None or not args.font.is_file():
        raise SystemExit(f"Font source not found: {args.font}")
    if args.size <= 0 or args.page_size <= 0 or args.padding < 0:
        raise SystemExit("Size and page size must be positive, and padding cannot be negative.")
    generate(args.font, args.output, size=args.size, page_size=args.page_size, padding=args.padding)


if __name__ == "__main__":
    main()
