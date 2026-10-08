"""Render our original metadata mark into the committed iOS asset sizes.

Development utility only. Requires Pillow; there is no app runtime dependency.
The deliberately simple trusted SVG uses only a rectangle and polylines.
"""
import json
from pathlib import Path
import xml.etree.ElementTree as ET
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
ASSETS = HERE.parent / "ios/Runner/Assets.xcassets"


def render(size):
    # Supersampling preserves round strokes at small icon dimensions.
    canvas_size = max(1024, size * 4)
    factor = canvas_size / 32
    svg = ET.parse(HERE / "mark.svg").getroot()
    background, group = list(svg)
    canvas = Image.new("RGB", (canvas_size, canvas_size), background.attrib["fill"])
    draw = ImageDraw.Draw(canvas)
    color = group.attrib["stroke"]
    width = round(float(group.attrib["stroke-width"]) * factor)
    radius = width / 2
    for line in group:
        points = [tuple(float(value) * factor for value in pair.split(","))
                  for pair in line.attrib["points"].split()]
        draw.line(points, fill=color, width=width, joint="curve")
        for x, y in points:
            draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=color)
    return canvas.resize((size, size), Image.Resampling.LANCZOS)


def main():
    icons = ASSETS / "AppIcon.appiconset"
    entries = json.loads((icons / "Contents.json").read_text())["images"]
    for entry in entries:
        points = float(entry["size"].split("x")[0])
        scale = float(entry["scale"].removesuffix("x"))
        render(round(points * scale)).save(icons / entry["filename"])
    launch = ASSETS / "LaunchImage.imageset"
    for entry in json.loads((launch / "Contents.json").read_text())["images"]:
        scale = float(entry["scale"].removesuffix("x"))
        render(round(96 * scale)).save(launch / entry["filename"])
    print("Rendered 19 app-icon entries and 3 launch sizes from the original mark.")


if __name__ == "__main__":
    main()
