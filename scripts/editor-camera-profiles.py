"""Reviewed manufacturer specifications; emit the versioned consumer catalog."""
import copy
import json
import re

T = {
    "11": [("main", "Main Camera", 1.8), ("ultra", "Ultra Wide", 2.4)],
    "11pro": [("main", "Main Camera", 1.8), ("ultra", "Ultra Wide", 2.4), ("tele", "Telephoto", 2.0)],
    "12": [("main", "Main Camera", 1.6), ("ultra", "Ultra Wide", 2.4)],
    "12pro": [("main", "Main Camera", 1.6), ("ultra", "Ultra Wide", 2.4), ("tele", "Telephoto", 2.0)],
    "12max": [("main", "Main Camera", 1.6), ("ultra", "Ultra Wide", 2.4), ("tele", "Telephoto", 2.2, 65)],
    "13pro": [("main", "Main Camera", 1.5), ("ultra", "Ultra Wide", 1.8), ("tele", "Telephoto", 2.8, 77)],
    "14": [("main", "Main Camera", 1.5, 26), ("ultra", "Ultra Wide", 2.4, 13)],
    "14pro": [("main", "Main Camera", 1.78, 24), ("ultra", "Ultra Wide", 2.2, 13), ("tele", "Telephoto", 2.8, 77)],
    "15": [("main", "Main Camera", 1.6, 26), ("ultra", "Ultra Wide", 2.4, 13)],
    "15max": [("main", "Main Camera", 1.78, 24, 6.765), ("ultra", "Ultra Wide", 2.2, 13, 2.22), ("tele", "Telephoto", 2.8, 120, 15.66)],
    "16": [("main", "Main Camera", 1.6, 26), ("ultra", "Ultra Wide", 2.2, 13)],
    "16pro": [("main", "Main Camera", 1.78, 24), ("ultra", "Ultra Wide", 2.2, 13), ("tele", "Telephoto", 2.8, 120)],
    "17pro": [("main", "Main Camera", 1.78, 24), ("ultra", "Ultra Wide", 2.2, 13), ("tele", "Telephoto", 2.8, 100)],
    "single": [("main", "Main Camera", 1.6, 26)],
    "se": [("main", "Main Camera", 1.8)],
}
APPLE = [
    ("iPhone 11", "111865", "11", 2.2), ("iPhone 11 Pro", "111879", "11pro", 2.2), ("iPhone 11 Pro Max", "111878", "11pro", 2.2),
    ("iPhone 12", "111876", "12", 2.2), ("iPhone 12 mini", "111877", "12", 2.2), ("iPhone 12 Pro", "111875", "12pro", 2.2), ("iPhone 12 Pro Max", "111874", "12max", 2.2),
    ("iPhone 13", "111872", "12", 2.2), ("iPhone 13 mini", "111873", "12", 2.2), ("iPhone 13 Pro", "111871", "13pro", 2.2), ("iPhone 13 Pro Max", "111870", "13pro", 2.2),
    ("iPhone 14", "111850", "14", 1.9), ("iPhone 14 Plus", "111854", "14", 1.9), ("iPhone 14 Pro", "111849", "14pro", 1.9), ("iPhone 14 Pro Max", "111846", "14pro", 1.9),
    ("iPhone 15", "111831", "15", 1.9), ("iPhone 15 Plus", "111830", "15", 1.9), ("iPhone 15 Pro", "111829", "14pro", 1.9), ("iPhone 15 Pro Max", "111828", "15max", 1.9),
    ("iPhone 16", "121029", "16", 1.9), ("iPhone 16 Plus", "121030", "16", 1.9), ("iPhone 16 Pro", "121031", "16pro", 1.9), ("iPhone 16 Pro Max", "121032", "16pro", 1.9),
    ("iPhone 16e", "122208", "single", 1.9), ("iPhone 17", "125089", "16", 1.9), ("iPhone 17 Pro", "125090", "17pro", 1.9), ("iPhone 17 Pro Max", "125091", "17pro", 1.9),
    ("iPhone 17e", "126470", "single", 1.9), ("iPhone Air", "125092", "single", 1.9), ("iPhone SE (2nd generation)", "111882", "se", 2.2), ("iPhone SE (3rd generation)", "111866", "se", 2.2),
]
DEFAULTS = {"iso": {"min": 40, "max": 1000}, "exposureTimes": ["1/24", "1/30", "1/60", "1/120", "1/240", "1/500", "1/1000"], "exposureCompensations": [0], "software": [], "evidence": "scenario-defaults"}


def build_profile(brand, model, sources, rows):
    profile = {"id": re.sub(r"[^a-z0-9]+", "-", (brand + "-" + model.replace("+", " Plus")).lower()).strip("-"), "brand": brand, "model": model, "make": brand, "lensMake": brand, "modelEvidence": "published-product-name", "clearFields": ["software", "hostComputer"], "sources": sources, "randomization": copy.deepcopy(DEFAULTS), "cameras": []}
    for row in rows:
        camera_id, name, aperture = row[:3]
        equivalent = row[3] if len(row) > 3 else None
        physical = row[4] if len(row) > 4 else None
        lens = f"{model} {name}" + (f" {equivalent}mm equivalent" if equivalent is not None else "") + f" f/{aperture:g}"
        fields = {"fNumber": aperture, "lensModel": lens}
        evidence = {"fNumber": "official-spec", "lensModel": "descriptive-label"}
        if equivalent is not None:
            fields["focalLength35mm"] = equivalent
            evidence["focalLength35mm"] = "official-spec"
        if physical is not None:
            fields["focalLength"] = physical
            fields["lensModel"] = f"{model} back triple camera {physical:g}mm f/{aperture:g}"
            evidence.update(focalLength="user-script", lensModel="user-script")
        profile["cameras"].append({"id": camera_id, "name": name, "fields": fields, "fieldEvidence": evidence, "clearFields": [key for key in ("focalLength", "focalLength35mm") if key not in fields], "sources": sources})
    return profile


def catalog():
    profiles = []
    for model, page, template, front in APPLE:
        sources = [f"https://support.apple.com/en-us/{page}"]
        if model == "iPhone 12 Pro Max":
            sources.append("https://www.apple.com/newsroom/2020/11/iphone-12-pro-max-iphone-12-mini-and-homepod-mini-available-to-order-friday/")
        if model.startswith("iPhone 13 Pro"):
            sources.append("https://www.apple.com/newsroom/2021/09/apple-unveils-iphone-13-pro-and-iphone-13-pro-max-more-pro-than-ever-before/")
        p = build_profile("Apple", model, sources, T[template] + [("front", "Front Camera", front)])
        if model == "iPhone 15 Pro Max":
            p["randomization"].update(software=["17.1.1", "17.3", "17.4.1", "17.5.1"], softwareEvidence="user-script")
            p["userScriptReference"] = "spoof_exif.py"
            p["clearFields"] = ["hostComputer"]
        profiles.append(p)
    samsung = {24: "https://news.samsung.com/global/enter-the-new-era-of-mobile-ai-with-samsung-galaxy-s24-series", 25: "https://news.samsung.com/ph/samsung-galaxy-s25-series-sets-the-standard-of-ai-phone-as-a-true-ai-companion"}
    for generation, source in samsung.items():
        standard = [("main", "Main Camera", 1.8), ("ultra", "Ultra Wide", 2.2), ("tele-3x", "Telephoto 3x", 2.4), ("front", "Front Camera", 2.2)]
        ultra = [("main", "Main Camera", 1.7), ("ultra", "Ultra Wide", 2.2 if generation == 24 else 1.9), ("tele-3x", "Telephoto 3x", 2.4), ("tele-5x", "Telephoto 5x", 3.4), ("front", "Front Camera", 2.2)]
        for suffix in ("", "+", " Ultra"):
            profiles.append(build_profile("Samsung", f"Galaxy S{generation}{suffix}", [source], ultra if suffix == " Ultra" else standard))
    google_source = "https://support.google.com/pixelphone/answer/7158570?hl=en"
    for model, ultra, tele in [("Pixel 8", 2.2, False), ("Pixel 8 Pro", 1.95, True), ("Pixel 9", 1.7, False), ("Pixel 9 Pro", 1.7, True), ("Pixel 9 Pro XL", 1.7, True)]:
        rows = [("main", "Main Camera", 1.68), ("ultra", "Ultra Wide", ultra)]
        if tele:
            rows.append(("tele", "Telephoto 5x", 2.8))
        rows.append(("front", "Front Camera", 2.2))
        profiles.append(build_profile("Google", model, [google_source], rows))
    assert len(profiles) == len({p["id"] for p in profiles}) == 42
    assert sum(len(p["cameras"]) for p in profiles) == 146
    return {"schemaVersion": 1, "revision": "2026-10-08", "notes": ["Published specifications differ from device-captured EXIF identifiers.", "Unknown physical focal lengths and software are omitted; clear stale camera-specific values when changing devices.", "ISO/shutter defaults are editable scenario suggestions, not verified hardware limits.", "iPhone 15 Pro Max rear physical focal lengths, lens literals and software candidates are user-script values."], "profiles": profiles}


if __name__ == "__main__":
    print(json.dumps(catalog(), ensure_ascii=False, indent=2))
