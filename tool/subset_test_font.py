#!/usr/bin/env python3
"""Reproducible golden font. Python >=3.8; pip install fonttools==4.55.8."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SOURCE_URL = 'https://raw.githubusercontent.com/notofonts/noto-cjk/165c01b46ea533872e002e0785ff17e44f6d97d8/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf'
SOURCE_SHA256 = '2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b'
LICENSE_URL = 'https://raw.githubusercontent.com/notofonts/noto-cjk/165c01b46ea533872e002e0785ff17e44f6d97d8/LICENSE'
VERSION = '4.55.8'
OUTPUT = ROOT / 'dart/packages/chatweave_flutter/test/fonts'
PUNCTUATION = '，。！？；：、（）【】《》〈〉「」『』〔〕［］｛｝“”‘’…—·～￥﹏'


def characters(root=ROOT):
    chars = set(range(32, 127)) | set(map(ord, PUNCTUATION))
    for pattern in ('dart/packages/*/lib/**/*.dart',
                    'dart/packages/*/test/**/*.dart',
                    'fixtures/conformance/**/*.json'):
        for path in sorted(root.glob(pattern)):
            chars.update(ord(c) for c in path.read_text(encoding='utf-8')
                         if ord(c) > 127)
    return sorted(chars)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def check(output, codepoints):
    from fontTools.ttLib import TTFont
    manifest = json.loads((output / 'manifest.json').read_text(encoding='utf-8'))
    data = (output / 'ChatWeaveTestSans.otf').read_bytes()
    if sha256(data) != manifest['outputSha256']:
        raise ValueError('Font SHA-256 does not match manifest')
    if manifest['sourceSha256'] != SOURCE_SHA256 or manifest['sourceUrl'] != SOURCE_URL:
        raise ValueError('Unexpected font source')
    with TTFont(output / 'ChatWeaveTestSans.otf') as font:
        missing = sorted(set(codepoints) - set(font.getBestCmap()))
    if missing:
        raise ValueError('Missing characters: ' + ' '.join(
            'U+{:04X} ({})'.format(cp, chr(cp)) for cp in missing))


def generate(source, output, codepoints):
    # Verify before importing fonttools or making any network request.
    if sha256(source.read_bytes()) != SOURCE_SHA256:
        raise ValueError('Source font SHA-256 mismatch')
    import fontTools
    from fontTools import subset
    from fontTools.ttLib import TTFont
    if fontTools.__version__ != VERSION:
        raise ValueError('Requires fonttools==' + VERSION)
    font = TTFont(source, recalcTimestamp=False)
    missing = sorted(set(codepoints) - set(font.getBestCmap()))
    if missing:
        raise ValueError('Source font lacks: ' + ' '.join(
            'U+{:04X} ({})'.format(cp, chr(cp)) for cp in missing))
    options = subset.Options()
    options.recalc_timestamp = False
    options.canonical_order = True
    options.name_IDs = ['*']
    options.name_legacy = True
    options.name_languages = ['*']
    subsetter = subset.Subsetter(options=options)
    subsetter.populate(unicodes=codepoints)
    subsetter.subset(font)
    font['head'].created = font['head'].modified = 2082844800  # 1970-01-01
    # Pin license bytes by the same immutable upstream revision.
    with urllib.request.urlopen(LICENSE_URL, timeout=60) as response:
        license_text = response.read()
    output.mkdir(parents=True, exist_ok=True)
    target = output / 'ChatWeaveTestSans.otf'
    font.save(target, reorderTables=True)
    font.close()
    (output / 'OFL.txt').write_bytes(license_text)
    manifest = dict(sourceUrl=SOURCE_URL, sourceSha256=SOURCE_SHA256,
                    outputSha256=sha256(target.read_bytes()),
                    characterCount=len(codepoints), fonttoolsVersion=VERSION)
    (output / 'manifest.json').write_text(
        json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + '\n',
        encoding='utf-8')
    check(output, codepoints)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, nargs='?')
    parser.add_argument('output', type=Path, nargs='?', default=OUTPUT)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        if args.check:
            if args.source and sha256(args.source.read_bytes()) != SOURCE_SHA256:
                raise ValueError('Source font SHA-256 mismatch')
            check(args.output, characters())
        elif args.source:
            generate(args.source, args.output, characters())
        else:
            parser.error('source font path is required for generation')
    except (ValueError, OSError, KeyError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
