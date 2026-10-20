"""Source wiring checks only. Does not compile Swift or measure AppKit fonts."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
source = Path(sys.argv[1]).read_text() if len(sys.argv) > 1 else (
    root / "SpotifyLyrics/Lyrics/FloatingLyricsPresentation.swift"
).read_text()


def block(signature, text=source):
    start = text.index(signature)
    opening = text.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[opening + 1:end - 1]


expected = {
    "FloatingEstimatedLineWidthCacheKey": {
        "text": "String?", "rubyTokens": "[LyricRubyToken]?", "hasRuby": "Bool",
        "fontSize": "Double", "outlineWidth": "Double",
    },
    "FloatingFittedFontSizeCacheKey": {
        "requested": "Double", "height": "Double", "doubleLine": "Bool",
        "hasRuby": "Bool", "outlineWidth": "Double", "width": "Double?",
        "text": "String?", "rubyTokens": "[LyricRubyToken]?",
        "companionText": "String?", "minFontSize": "Double",
    },
}
for name, fields in expected.items():
    key = block(f"final class {name}: NSObject")
    inputs = block("private struct Inputs: Hashable", key)
    actual = dict(re.findall(r"let (\w+): ([^\n]+)", inputs))
    assert actual == fields, (name, actual)
    assert "private let inputs: Inputs" in key
    assert "override var hash: Int { inputs.hashValue }" in key
    assert "return inputs == other.inputs" in key
    for field in fields:
        assert re.search(rf"\b{field}: {field}\b", key), (name, field)

width = block("public static func estimatedLineWidth(")
fit = block("public static func fittedFontSize(")
for body, name in [(width, "FloatingEstimatedLineWidthCacheKey"),
                   (fit, "FloatingFittedFontSizeCacheKey")]:
    assert f"let cacheKey = {name}(" in body
    for field in expected[name]:
        assert re.search(rf"\b{field}: {field}\b", body), (name, field)
    assert "rubyTokens?.count" not in body
    assert "as NSString" not in body.split("if let cached", 1)[0]

assert "NSCache<FloatingEstimatedLineWidthCacheKey, NSNumber>" in source
assert "NSCache<FloatingFittedFontSizeCacheKey, NSNumber>" in source
assert "cache.countLimit = 512" in block("private static let estimatedLineWidthCache:")
assert "cache.countLimit = 256" in block("private static let fittedFontSizeCache:")

tests = (root / "Tests/Native/Presentation/FloatingLyricsPresentationTests.swift").read_text()
assert all(marker in tests for marker in (
    "changedSurface", "changedGrouping", "A-to-B-to-A", 'text: "ABC-DE"',
    'companionText: "DE-F"', "longRubyWidth > shortRubyWidth",
    "longRubySize < shortRubySize",
))
print("SOURCE CONTRACT PASS: complete immutable key fields, equality wiring, call arguments, cache limits and regression presence")
print("Swift compilation, NSCache runtime and AppKit font measurements: NOT RUN by this source checker")
