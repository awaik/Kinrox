#!/usr/bin/env python3
"""Print the `use_figma` code that builds one localized screenshot row in Figma.

Usage: python3 Scripts/app-store/figma-row-call.py <store-locale> [--engine]

The printed JavaScript removes any earlier "TMP export" row on page 229:304, then runs
Scripts/app-store/figma-localize-screenshots.js with this locale's replacements from
AppStore/screenshot-strings.json. With --engine it first stores the current script in
the Figma text node ENGINE_NODE (create that node once, hidden, and delete it after the
export). Russian uses its own master row without replacements.

After the call, export the returned wrapper with get_screenshot at maxDimension 10560
and split it with Scripts/app-store/split-screenshots.swift.
"""
import base64
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ENGINE = Path(__file__).with_name('figma-localize-screenshots.js')
ENGINE_NODE = '246:1539'  # Temporary text node used during the 2026-11-11 export.

STANDARD = ['Thin', 'ExtraLight', 'Light', 'Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold', 'Black']
CJK = ['Thin', 'Light', 'DemiLight', 'Regular', 'Medium', 'Bold', 'Black']
# SF Pro covers Latin, Cyrillic, Greek and Vietnamese. Other scripts use Noto families
# available in Figma. Urdu uses Naskh: Noto Nastaliq's tall glyphs collide at the
# headline line height.
FONTS = {
    'ja': ('Noto Sans JP', CJK), 'zh-Hans': ('Noto Sans SC', CJK), 'zh-Hant': ('Noto Sans TC', CJK),
    'ko': ('Noto Sans KR', CJK), 'ar': ('Noto Sans Arabic', STANDARD), 'fa': ('Noto Sans Arabic', STANDARD),
    'ur': ('Noto Sans Arabic', STANDARD), 'he': ('Noto Sans Hebrew', STANDARD),
    'hi': ('Noto Sans Devanagari', STANDARD), 'bn': ('Noto Sans Bengali', STANDARD),
    'th': ('Noto Sans Thai', STANDARD),
}


def main():
    locale = sys.argv[1]
    strings = json.loads((ROOT / 'AppStore/screenshot-strings.json').read_text())[locale]
    source = 'ru' if locale == 'ru' else 'en'
    font = FONTS.get(strings['lang'])
    data = {
        'locale': locale, 'source': source, 'rtl': strings['rtl'],
        'map': {} if source == 'ru' else strings['map'],
        'font': {'family': font[0], 'styles': font[1]} if font else None, 'y': 8000,
    }
    code = []
    if '--engine' in sys.argv:
        encoded = base64.b64encode(ENGINE.read_bytes()).decode()
        code.append(
            f'const b64="{encoded}";const bytes=figma.base64Decode(b64);let s0="";'
            'for(let i=0;i<bytes.length;i+=4096)s0+=String.fromCharCode.apply(null,Array.from(bytes.subarray(i,i+4096)));'
            'await figma.loadFontAsync({family:"Inter",style:"Regular"});'
            f'(await figma.getNodeByIdAsync("{ENGINE_NODE}")).characters=s0;')
    code.append(
        'const pg=await figma.getNodeByIdAsync("229:304");await figma.setCurrentPageAsync(pg);'
        'for(const n of pg.children.filter(c=>c.name.startsWith("TMP export")))n.remove();')
    code.append('const DATA=' + json.dumps(data, ensure_ascii=False, separators=(',', ':')) + ';')
    code.append(f'const src=(await figma.getNodeByIdAsync("{ENGINE_NODE}")).characters;')
    code.append('return await eval("(async function(DATA){\\n"+src+"\\n})")(DATA);')
    print('\n'.join(code))


if __name__ == '__main__':
    main()
