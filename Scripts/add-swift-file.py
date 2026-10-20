#!/usr/bin/env python3
"""Register new Swift files in SpotifyLyrics.xcodeproj next to an existing one.

    Scripts/add-swift-file.py SIBLING.swift NEW.swift [NEW2.swift ...]

Each new file joins the sibling's group and the app target's Sources phase,
with a path written in the same style as the sibling's. generate_xcodeproj.py
is obsolete; the project file is maintained by hand, so keep this minimal.
"""
from pathlib import Path
import hashlib
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
PBX = ROOT / "SpotifyLyrics.xcodeproj/project.pbxproj"


def ident(seed: str) -> str:
    return hashlib.sha1(seed.encode()).hexdigest()[:24].upper()


def main(sibling: str, news: list[str]) -> None:
    text = PBX.read_text()
    m = re.search(r"\t\t(\w{24}) /\* %s \*/ = \{isa = PBXFileReference;[^\n]*path = ([^;]+);" % re.escape(sibling), text)
    if not m:
        raise SystemExit(f"sibling {sibling} not found")
    sibling_ref, sibling_path = m.group(1), m.group(2)
    prefix = sibling_path[: -len(sibling)]
    for name in news:
        if f"/* {name} */" in text:
            print(f"skip {name}: already registered")
            continue
        ref, build = ident("ref:" + name), ident("build:" + name)
        text = text.replace(
            "/* End PBXBuildFile section */",
            f"\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};\n/* End PBXBuildFile section */", 1)
        text = text.replace(
            "/* End PBXFileReference section */",
            f'\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {prefix}{name}; sourceTree = "<group>"; }};\n/* End PBXFileReference section */', 1)
        child = f"\t\t\t\t{sibling_ref} /* {sibling} */,\n"
        if text.count(child) != 1:
            raise SystemExit(f"sibling {sibling} group entry not unique")
        text = text.replace(child, child + f"\t\t\t\t{ref} /* {name} */,\n", 1)
        source = re.search(r"\t\t\t\t\w{24} /\* %s in Sources \*/,\n" % re.escape(sibling), text)
        if not source:
            raise SystemExit(f"sibling {sibling} not in Sources")
        text = text.replace(source.group(0), source.group(0) + f"\t\t\t\t{build} /* {name} in Sources */,\n", 1)
        print(f"added {prefix}{name}")
    PBX.write_text(text)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2:])
