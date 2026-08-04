#!/usr/bin/env python3
"""Import the DrawKit avatar part artwork into the Hive asset catalog.

The artwork is DrawKit's "Notion Style Avatar Creator",
https://www.drawkit.com/illustrations/notion-style-avatar-creator.

Takes the pack directory holding that artwork as its argument. The pack lays the
raw SVG exports out as ``<pack>/src/assets/parts/<category>/*.svg``, one
directory per category, and this script rewrites, from scratch, both

  * ``App/Resources/Assets.xcassets/AvatarKit/``  — one ``.imageset`` per layer,
    each holding the ``.svg`` with ``preserves-vector-representation`` set, so the
    catalog keeps true vector data and renders crisply at any size, and
  * ``App/Sources/AvatarKit/AvatarKitCatalog.swift`` — the generated list of
    asset names the avatar feature codes against.

Both outputs are derived purely from the pack, so this is idempotent: run it
again after the artwork updates and the diff is exactly the artwork change.

Stdlib only — this machine has no Homebrew, no cairosvg and no rsvg. It does not
need them: Xcode's asset catalog compiler parses SVG natively, so the whole
"conversion" is a copy plus a generated ``Contents.json``.

Usage
-----
    python3 Tools/avatarkit-import.py [PACK_PATH]
    python3 Tools/avatarkit-import.py --verify        # cross-check only

PACK_PATH defaults to ~/.buzz/.scratch/drawkit-notion-avatars.

Two things about the artwork that this script encodes, both read off the raw
files and re-verified against them:

1. The raw ``accessories/`` directory is NOT one category. Its 18 files are ten
   accessories and eight facial-hair pieces, in a different order from the raw
   filenames. ACCESSORY_SPLIT below is that mapping.
2. The pack ships no artwork for the three "none" options (bald / clean-shaven /
   no accessory). We model "none" as an absent layer, so nothing empty is
   shipped. ``draws_something`` below still filters defensively, in case an
   update introduces an empty file.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import sys
import xml.etree.ElementTree as ET

DEFAULT_PACK = os.path.expanduser("~/.buzz/.scratch/drawkit-notion-avatars")

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG_DIR = os.path.join(REPO_ROOT, "App", "Resources", "Assets.xcassets", "AvatarKit")
SWIFT_FILE = os.path.join(REPO_ROOT, "App", "Sources", "AvatarKit", "AvatarKitCatalog.swift")

# Raw `accessories/AccessoryNN.svg` -> which runtime category it really belongs to.
# Order within each list is the shipped order, i.e. the first entry becomes 01.
ACCESSORY_SPLIT: dict[str, list[str]] = {
    "accessories": [
        "Accessory01",  # bow tie
        "Accessory02",  # thin glasses
        "Accessory03",  # round sunglasses
        "Accessory08",  # surgical mask
        "Accessory09",  # respirator mask
        "Accessory10",  # rectangular glasses
        "Accessory11",  # censor bar
        "Accessory12",  # earphone cords
        "Accessory13",  # cap
        "Accessory14",  # cheek squiggles
    ],
    "facialHair": [
        "Accessory04",  # moustache
        "Accessory05",  # small tuft
        "Accessory06",  # small tuft (same art as the previous one, kept: the pack ships both)
        "Accessory07",  # moustache
        "Accessory15",  # chin beard
        "Accessory16",  # full beard
        "Accessory17",  # beard curve
        "Accessory18",  # soul patch
    ],
}

# (swift property, asset-name prefix, source subdirectory or None for the split above)
# Listed bottom-to-top in paint order, which is also the order of the generated file.
CATEGORIES = [
    ("body", "AvatarKitBody", "base"),
    ("outfits", "AvatarKitOutfit", "outfits"),
    ("heads", "AvatarKitHead", "faces"),
    ("hairs", "AvatarKitHair", "hairs"),
    ("eyes", "AvatarKitEyes", "eyes"),
    ("mouths", "AvatarKitMouth", "mouths"),
    ("facialHair", "AvatarKitFacialHair", None),
    ("accessories", "AvatarKitAccessory", None),
]

# `base/Bg.svg` is a flat background swatch, not a drawn layer: the ground behind an
# avatar is a colour this app fills for itself. Only Body is a real layer.
BASE_KEEP = ["Body"]

MAX_LINE = 120
SWIFT_INDENT = " " * 8


def natural_key(name: str):
    """Sort Hair2 before Hair10 rather than after it."""
    return [int(part) if part.isdigit() else part for part in re.split(r"(\d+)", name)]


def draws_something(path: str) -> bool:
    """True unless the SVG has no drawable geometry — an empty file the pack should not ship."""
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as error:
        raise SystemExit(f"error: {path} is not parseable SVG: {error}")
    drawable = {"path", "circle", "rect", "ellipse", "polygon", "polyline", "line", "text", "image"}
    for element in root.iter():
        if element.tag.rsplit("}", 1)[-1] in drawable:
            return True
    return False


def collect(pack: str) -> tuple[list[tuple[str, list[tuple[str, str]]]], list[str]]:
    """Return [(swift property, [(asset name, source svg path)])] plus any dropped files."""
    parts = os.path.join(pack, "src", "assets", "parts")
    if not os.path.isdir(parts):
        raise SystemExit(f"error: no artwork at {parts} — pass the DrawKit pack directory")

    split_expected = set(ACCESSORY_SPLIT["accessories"]) | set(ACCESSORY_SPLIT["facialHair"])
    on_disk = {f[:-4] for f in os.listdir(os.path.join(parts, "accessories")) if f.endswith(".svg")}
    if on_disk != split_expected:
        missing = sorted(split_expected - on_disk)
        extra = sorted(on_disk - split_expected)
        raise SystemExit(
            "error: the artwork's accessories/ no longer matches ACCESSORY_SPLIT.\n"
            f"  missing from disk: {missing}\n  unclassified on disk: {extra}\n"
            "  Open the new files, decide accessory vs facial hair, and update the table."
        )

    dropped: list[str] = []
    result: list[tuple[str, list[tuple[str, str]]]] = []
    for prop, prefix, subdir in CATEGORIES:
        if subdir is None:
            sources = [os.path.join(parts, "accessories", f"{s}.svg") for s in ACCESSORY_SPLIT[prop]]
        elif subdir == "base":
            sources = [os.path.join(parts, "base", f"{s}.svg") for s in BASE_KEEP]
        else:
            directory = os.path.join(parts, subdir)
            names = sorted((f for f in os.listdir(directory) if f.endswith(".svg")), key=natural_key)
            sources = [os.path.join(directory, f) for f in names]

        kept = []
        seen: dict[str, str] = {}
        for source in sources:
            if not os.path.isfile(source):
                raise SystemExit(f"error: expected artwork file is missing: {source}")
            if not draws_something(source):
                dropped.append(os.path.relpath(source, pack))
                continue
            # Two files in accessories/ are byte-identical artwork. Shipping both puts two
            # indistinguishable cells next to each other in the picker, which reads as a bug.
            digest = hashlib.sha256(open(source, "rb").read()).hexdigest()
            if digest in seen:
                dropped.append(f"{os.path.relpath(source, pack)} (identical to {seen[digest]})")
                continue
            seen[digest] = os.path.basename(source)
            kept.append(source)

        # Renumber contiguously from 01; the raw file's own number is not carried over.
        if prop == "body":
            entries = [(prefix, kept[0])]
        else:
            entries = [(f"{prefix}{i:02d}", src) for i, src in enumerate(kept, start=1)]
        result.append((prop, entries))
    return result, dropped


def xcode_json(obj) -> str:
    """json.dumps, respaced to Xcode's `"key" : value` house style."""
    text = json.dumps(obj, indent=2)
    text = re.sub(r'^(\s*"[^"]*"): ', r"\1 : ", text, flags=re.MULTILINE)
    return text + "\n"


def write_catalog(categories) -> int:
    if not CATALOG_DIR.endswith(os.path.join("Assets.xcassets", "AvatarKit")):
        raise SystemExit(f"refusing to delete {CATALOG_DIR}")
    shutil.rmtree(CATALOG_DIR, ignore_errors=True)
    os.makedirs(CATALOG_DIR)

    # No `provides-namespace`: asset names stay flat, so `Image("AvatarKitHair01")`
    # works without a folder prefix.
    with open(os.path.join(CATALOG_DIR, "Contents.json"), "w") as handle:
        handle.write(xcode_json({"info": {"author": "xcode", "version": 1}}))

    count = 0
    for _, entries in categories:
        for name, source in entries:
            imageset = os.path.join(CATALOG_DIR, f"{name}.imageset")
            os.makedirs(imageset)
            shutil.copyfile(source, os.path.join(imageset, f"{name}.svg"))
            contents = {
                "images": [{"filename": f"{name}.svg", "idiom": "universal"}],
                "info": {"author": "xcode", "version": 1},
                # Without this the catalog bakes a fixed-size bitmap and a large
                # render (we draw at 512pt) comes out soft.
                "properties": {"preserves-vector-representation": True},
            }
            with open(os.path.join(imageset, "Contents.json"), "w") as handle:
                handle.write(xcode_json(contents))
            count += 1
    return count


def swift_array(prop: str, names: list[str]) -> list[str]:
    """One `static let` as wrapped source lines, all under MAX_LINE columns."""
    lines = [f"    static let {prop}: [String] = ["]
    current = ""
    for index, name in enumerate(names):
        piece = f'"{name}"' + ("," if index < len(names) - 1 else "")
        candidate = f"{current} {piece}" if current else piece
        if len(SWIFT_INDENT) + len(candidate) > MAX_LINE - 1:
            lines.append(SWIFT_INDENT + current)
            current = piece
        else:
            current = candidate
    if current:
        lines.append(SWIFT_INDENT + current)
    lines.append("    ]")
    return lines


def write_swift(categories) -> int:
    os.makedirs(os.path.dirname(SWIFT_FILE), exist_ok=True)
    lines = [
        '// Generated from the DrawKit "Notion Style Avatar Creator" artwork. Do not hand-edit.',
        "//",
        "// Artwork: DrawKit, https://www.drawkit.com/illustrations/notion-style-avatar-creator,",
        "// taken from the raw src/assets/parts/**/*.svg exports in that pack.",
        "//",
        "// Produced by Tools/avatarkit-import.py, which also writes the matching imagesets in",
        "// App/Resources/Assets.xcassets/AvatarKit. Re-run that script to regenerate both.",
        "//",
        '// There is no "none" entry anywhere below, by design: bald, clean-shaven and',
        "// no-accessory are an omitted layer in code, not an empty asset, so every name",
        "// here draws something.",
        "enum AvatarKitCatalog {",
    ]
    total = 0
    for prop, entries in categories:
        names = [name for name, _ in entries]
        total += len(names)
        if prop == "body":
            lines.append(f'    static let body = "{names[0]}"')
        else:
            lines.extend(swift_array(prop, names))
    lines.append("}")

    text = "\n".join(lines) + "\n"
    over = [line for line in text.splitlines() if len(line) > MAX_LINE]
    if over:
        raise SystemExit(f"error: generated {len(over)} line(s) over {MAX_LINE} columns")
    with open(SWIFT_FILE, "w") as handle:
        handle.write(text)
    return total


def verify() -> int:
    """Cross-check the Swift file against the catalog in both directions."""
    if not os.path.isfile(SWIFT_FILE) or not os.path.isdir(CATALOG_DIR):
        raise SystemExit("error: nothing to verify — run the import first")
    swift_names = set(re.findall(r'"(AvatarKit[A-Za-z0-9]+)"', open(SWIFT_FILE).read()))
    disk_names = {d[: -len(".imageset")] for d in os.listdir(CATALOG_DIR) if d.endswith(".imageset")}

    missing_on_disk = sorted(swift_names - disk_names)
    missing_in_swift = sorted(disk_names - swift_names)
    print(f"names in AvatarKitCatalog.swift : {len(swift_names)}")
    print(f"imageset directories on disk     : {len(disk_names)}")
    print(f"named in Swift but no imageset   : {len(missing_on_disk)} {missing_on_disk}")
    print(f"imageset but not named in Swift  : {len(missing_in_swift)} {missing_in_swift}")

    unflagged = []
    for name in sorted(disk_names):
        contents = os.path.join(CATALOG_DIR, f"{name}.imageset", "Contents.json")
        with open(contents) as handle:
            data = json.load(handle)
        if data.get("properties", {}).get("preserves-vector-representation") is not True:
            unflagged.append(name)
        image = data["images"][0]["filename"]
        if not os.path.isfile(os.path.join(CATALOG_DIR, f"{name}.imageset", image)):
            unflagged.append(f"{name} (missing {image})")
    print(f"imagesets missing the vector flag: {len(unflagged)} {unflagged}")

    ok = not missing_on_disk and not missing_in_swift and not unflagged
    print("VERIFY: " + ("OK" if ok else "FAILED"))
    return 0 if ok else 1


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if a != "--verify"]
    if "--verify" in argv[1:]:
        return verify()
    pack = args[0] if args else DEFAULT_PACK

    categories, dropped = collect(pack)
    imagesets = write_catalog(categories)
    named = write_swift(categories)

    for prop, entries in categories:
        print(f"  {prop:12s} {len(entries):3d}")
    print(f"  {'TOTAL':12s} {imagesets:3d} imagesets, {named} names")
    if dropped:
        print(f"dropped {len(dropped)} empty or duplicate asset(s): {dropped}")
    else:
        print("dropped 0 empty assets (the source ships no empty SVGs)")
    print(f"catalog: {CATALOG_DIR}")
    print(f"swift  : {SWIFT_FILE}")
    return verify()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
