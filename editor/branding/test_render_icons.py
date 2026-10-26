"""Focused checks for the canonical mark and its committed iOS assets."""
import json
import unittest
import xml.etree.ElementTree as ET

from PIL import Image

import render_icons


class MarkTests(unittest.TestCase):
    def test_master_has_neutral_focus_and_evenly_spaced_rows(self):
        master = ET.parse(render_icons.HERE / "mark.svg").getroot()
        dots = master.findall("{*}circle")
        self.assertEqual([dot.attrib["cy"] for dot in dots], ["10", "16", "22"])
        self.assertEqual(dots[0].attrib["fill"], "#CFCFCF")
        self.assertEqual(dots[1].attrib["r"], dots[2].attrib["r"])
        corners = list(master)[1]
        self.assertEqual(corners.attrib["stroke-width"], "1.8")
        self.assertEqual(len(corners), 4)

    def test_committed_assets_match_master_and_manifest(self):
        for name in ("AppIcon.appiconset", "LaunchImage.imageset"):
            folder = render_icons.ASSETS / name
            entries = json.loads((folder / "Contents.json").read_text())["images"]
            for entry in entries:
                scale = float(entry["scale"].removesuffix("x"))
                points = float(entry.get("size", "96x96").split("x")[0])
                size = round(points * scale)
                with self.subTest(asset=entry["filename"]):
                    with Image.open(folder / entry["filename"]) as actual:
                        self.assertEqual(actual.size, (size, size))
                        self.assertEqual(actual.mode, "RGB")
                        self.assertEqual(actual.tobytes(), render_icons.render(size).tobytes())

    def test_small_and_large_marks_are_opaque_and_achromatic(self):
        for size in (20, 29, 32, 40, 58, 60, 76, 80, 87, 120, 152, 167, 180, 288, 1024):
            with self.subTest(size=size):
                image = render_icons.render(size)
                self.assertEqual(image.mode, "RGB")
                self.assertTrue(all(red == green == blue
                                    for count, (red, green, blue)
                                    in image.getcolors(maxcolors=size * size)))
                self.assertTrue(any(red > 150 for count, (red, green, blue)
                                    in image.getcolors(maxcolors=size * size)))
                self.assertEqual(image.getpixel((0, 0)), (37, 37, 37))

    def test_invalid_dimensions_are_rejected(self):
        for size in (0, -1, 20.5):
            with self.assertRaises(ValueError):
                render_icons.render(size)


if __name__ == "__main__":
    unittest.main()
