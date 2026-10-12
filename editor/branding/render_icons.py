"""Render the original SVG mark into committed opaque iOS asset sizes.

Development utility only. Requires Pillow; there is no app runtime dependency.
The trusted SVG intentionally uses only a background, groups, polylines and dots.
The Flutter MetadataMarkPainter mirrors this 32-unit geometry.
"""
import json
from pathlib import Path
import xml.etree.ElementTree as ET

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
ASSETS = HERE.parent / "ios/Runner/Assets.xcassets"


def render(size):
    if not isinstance(size, int) or size <= 0:
        raise ValueError("Icon size must be a positive integer")
    canvas_size = max(1024, size * 4)
    factor = canvas_size / 32
    svg = ET.parse(HERE / "mark.svg").getroot()
    background = list(svg)[0]
    canvas = Image.new("RGB", (canvas_size, canvas_size), background.attrib["fill"])
    draw = ImageDraw.Draw(canvas)

    def paint(element, inherited):
        attributes = {**inherited, **element.attrib}
        kind = element.tag.rsplit("}", 1)[-1]
        if kind == "g":
            for child in element:
                paint(child, attributes)
        elif kind == "polyline":
            if attributes.get("stroke-linecap") != "round":
                raise ValueError("The mark renderer supports only round line caps")
            points = [tuple(float(value) * factor for value in pair.split(","))
                      for pair in attributes["points"].split()]
            color = attributes["stroke"]
            width = round(float(attributes["stroke-width"]) * factor)
            radius = (width - 1) / 2
            draw.line(points, fill=color, width=width, joint="curve")
            for x, y in points:
                draw.ellipse((x - radius, y - radius, x + radius, y + radius),
                             fill=color)
        elif kind == "circle":
            x, y, radius = (float(attributes[key]) * factor
                           for key in ("cx", "cy", "r"))
            draw.ellipse((x - radius, y - radius, x + radius, y + radius),
                         fill=attributes["fill"])
        else:
            raise ValueError(f"Unsupported SVG element: {kind}")

    for element in list(svg)[1:]:
        paint(element, {})
    return canvas.resize((size, size), Image.Resampling.LANCZOS)


def main():
    icons = ASSETS / "AppIcon.appiconset"
    entries = json.loads((icons / "Contents.json").read_text())["images"]
    for entry in entries:
        points = float(entry["size"].split("x")[0])
        scale = float(entry["scale"].removesuffix("x"))
        render(round(points * scale)).save(icons / entry["filename"])
    launch = ASSETS / "LaunchImage.imageset"
    launch_entries = json.loads((launch / "Contents.json").read_text())["images"]
    for entry in launch_entries:
        scale = float(entry["scale"].removesuffix("x"))
        render(round(96 * scale)).save(launch / entry["filename"])
    print(f"Rendered {len(entries)} app-icon entries and "
          f"{len(launch_entries)} launch sizes from mark.svg.")


if __name__ == "__main__":
    main()
