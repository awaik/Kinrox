#!/usr/bin/env python3
"""Build per-locale text replacements for the App Store screenshot set v2.

Figma page `14 · App Store — Screenshots v2` (229:304) holds the English and
Russian masters. Every other locale is a copy of the English row whose texts are
replaced from this table: header copy from AppStore/localized-copy.json, device
UI from the app's Localizable.strings, and mock-only strings from `screenshot_ui`.
Output: AppStore/screenshot-strings.json (input to the Figma localization script).
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'AppStore'
DATES = Path(__file__).with_name('lock-screen-dates.swift')

# English mock text -> app localization key (same text in the device UI).
DIRECT = ['Paused', 'Players', 'Online', 'Recent', 'Video', 'Music', 'Artist', 'Album',
          'Shuffle', 'Repeat', 'Favorite', 'Queue', 'Albums', 'Stop',
          'Adding similar tracks as you listen', 'Not interested in this track', 'Remote',
          'Swipe left to remove · hold to reorder', 'Pairing', 'Enter code',
          'Remote Connection', 'Reject', 'Screensavers', 'Active on Mac. No sound.',
          'Turn Off Matrix', 'The movie stays paused.']
RENAMED = {'Now playing': 'Now Playing', 'Fullscreen': 'Full Screen'}
RTL = {'ar', 'he', 'fa', 'ur'}
# Durations use one format per language so regional variants share renders. Overrides
# replace Foundation abbreviations that read poorly in a label ("2 u, 14 m", Latin "2h 14m"
# for Persian).
DURATION_LOCALE = {'en': None, 'fr': 'fr-FR', 'es': 'es-ES', 'pt': 'pt-BR'}
DURATION = {'en': '2 h 14 min', 'fa': '2 ساعت و 14 دقیقه', 'nl': '2 u 14 min', 'sv': '2 h 14 min',
            'cs': '2 h 14 min', 'ro': '2 h 14 min', 'tr': '2 sa 14 dk', 'ms': '2 j 14 min',
            'id': '2 j 14 mnt', 'vi': '2 giờ 14 phút', 'ar': '2 س 14 د', 'el': '2 ώρ. 14 λεπ.',
            'uk': '2 год 14 хв', 'bn': '2 ঘণ্টা 14 মিনিট', 'he': '2 שע׳ 14 דק׳'}


def strings(lang):
    text = (ROOT / f'Resources/Localization/{lang}.lproj/Localizable.strings').read_text()
    pairs = re.findall(r'^"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";$', text, re.M)
    return {k.replace('\\"', '"'): v.replace('\\"', '"').replace('\\n', '\n') for k, v in pairs}


def fmt(template, *args):
    """Fill %@ and positional %n$@ placeholders like Foundation does."""
    counter = iter(range(len(args)))
    def sub(m):
        return str(args[int(m.group(1)) - 1] if m.group(1) else args[next(counter)])
    return re.sub(r'%(?:(\d+)\$)?@', sub, template)


def two_lines(sentence_pair):
    """Break after the first sentence, as in the master's dialog text."""
    m = re.search(r'([.!?。؟।۔])\s+', sentence_pair)
    if m:
        return sentence_pair[:m.end(1)] + '\n' + sentence_pair[m.end():]
    m = re.search(r'([。])', sentence_pair)
    if m and m.end() < len(sentence_pair):
        return sentence_pair[:m.end()] + '\n' + sentence_pair[m.end():]
    return sentence_pair


def lock_screen_formats(locales):
    out = subprocess.run(['swift', str(DATES), *locales], check=True, capture_output=True, text=True)
    return json.loads(out.stdout)


def main():
    manifest = json.loads((BASE / 'manifest.json').read_text())
    locales = {**manifest['locales'], 'fa': 'fa'}
    prepared = json.loads((BASE / 'localized-copy.json').read_text())
    english = prepared['en-US']
    formats = lock_screen_formats(sorted(locales))
    result = {}
    for locale, lang in sorted(locales.items()):
        copy, ui, s = prepared[locale], prepared[locale]['screenshot_ui'], strings(lang)
        L = lambda key: s[key]
        date = formats[locale]['date']
        date = date[:1].upper() + date[1:]
        duration = DURATION.get(lang) or formats[DURATION_LOCALE.get(lang) or locale]['duration']
        m = {}
        for i, (headline, detail) in enumerate(english['screenshots']):
            m[headline], m[detail] = copy['screenshots'][i]
        m[english['requirement']] = copy['requirement']
        m.update({key: L(key) for key in DIRECT})
        m.update({mock: L(key) for mock, key in RENAMED.items()})
        m.update({
            'Movies': ui['movies'], 'sec': ui['sec'], '+ more': ui['more'],
            # Bare "Next" is only the music deck's narrow label column.
            'Next': ui.get('next_label', ui['next']),
            'Code is valid for 2 minutes · 3 attempts left': ui['code_valid'],
            'Wednesday, November 11': date,
            'Controlled by iPhone': fmt(L('Controlled by %@'), 'iPhone'),
            '3 of 12 · Movies': fmt(L('%@ of %@ · %@'), '3', '12', ui['movies']),
            'Not interested in The Lanterns': fmt(L('Not interested in %@'), 'The Lanterns'),
            'Matrix is running on MacBook Pro': fmt(L('Matrix is running on %@'), 'MacBook Pro'),
            'from the Mac screen “MacBook Pro”': fmt(L('from the Mac screen “%@”'), 'MacBook Pro'),
            'Code expires in 1:47': fmt(L('Code expires in %@'), '1:47'),
            'iPhone wants to control Kinrox.\nEnter this code on your phone.': two_lines(
                fmt(L('%@ wants to control Kinrox. Enter this code on your phone.'), 'iPhone')),
            'Esc — exit   ·   Movie paused': L('Esc — exit · Movie paused').replace(' · ', '   ·   '),
            'Ember Dusk.mkv · Paused at 0:42:15': fmt(L('%@ · Paused at %@'), 'Ember Dusk.mkv', '0:42:15'),
            '35 tracks · 2 h 14 min left': fmt(L('%@ tracks'), '35') + ' · ' + fmt(ui['time_left'], duration),
            'Next · Added manually · 1': ui['next'] + ' · ' + L('Added manually') + ' · 1',
            'Then · From the album “Paper Lights” · 9':
                ui['then'] + ' · ' + fmt(ui['from_album'], 'Paper Lights') + ' · 9',
        })
        result[locale] = {'lang': lang, 'rtl': lang in RTL,
                          'map': {k: v for k, v in m.items() if k != v}}
    target = BASE / 'screenshot-strings.json'
    text = json.dumps(result, ensure_ascii=False, indent=1, sort_keys=True) + '\n'
    if '--check' in sys.argv:
        assert target.read_text() == text, 'Stale screenshot strings; rerun this script'
    else:
        target.write_text(text)
    print(f'Screenshot strings for {len(result)} locales.')


if __name__ == '__main__':
    main()
