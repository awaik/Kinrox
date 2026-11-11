#!/usr/bin/env python3
"""Validate authored copy and prepare App Store Connect metadata files."""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCALES = {
    'en-US':'en', 'en-GB':'en', 'en-CA':'en', 'en-AU':'en', 'ru':'ru',
    'es-ES':'es', 'es-MX':'es', 'fr-FR':'fr', 'fr-CA':'fr', 'de-DE':'de',
    'pt-BR':'pt', 'pt-PT':'pt', 'it':'it', 'zh-Hans':'zh-Hans', 'zh-Hant':'zh-Hant',
    'ja':'ja', 'ko':'ko', 'ar-SA':'ar', 'hi':'hi', 'bn-BD':'bn', 'ur-PK':'ur',
    'id':'id', 'ms':'ms', 'vi':'vi', 'th':'th', 'tr':'tr', 'pl':'pl', 'uk':'uk',
    'nl-NL':'nl', 'ro':'ro', 'el':'el', 'cs':'cs', 'sv':'sv', 'hu':'hu', 'he':'he',
}
FIELDS = {'name':30, 'subtitle':30, 'promotional_text':170, 'description':4000, 'keywords':100}
# Owner decision 2026-11-11: no third-party app or service names anywhere in the listing.
FORBIDDEN = ('spotify', 'vlc', 'iina', 'mpv', 'plex', 'netflix', 'youtube', 'soloist')
SCREENSHOTS = 8  # Figma 14 · App Store — Screenshots v2 (229:304)
# Mock-only UI strings inside the screenshot devices that have no app localization key.
SCREENSHOT_UI = ('movies', 'sec', 'next', 'then', 'from_album', 'time_left', 'code_valid', 'more')
# Optional: a shorter "Next" for the narrow label column of the music deck.
SCREENSHOT_UI_OPTIONAL = ('next_label',)


def regionalize(value, locale):
    if locale == 'es-MX':
        for before, after in [('mando','control remoto'), ('vídeo','video'), ('peli.','película.')]:
            value = value.replace(before, after)
    if locale == 'pt-PT':
        for before, after in [('controle','comando'), ('você controla','pode controlar'),
                              ('você','si'), ('a tela cheia','o ecrã inteiro'), ('tela cheia','ecrã inteiro'), ('criptografada','cifrada'),
                              ('criptografado','cifrado'), ('conectar','ligar'), ('Conecte','Ligue'),
                              ('conectado','ligado'),
                              ('Tela Bloqueada','Ecrã Bloqueado'),
                              ('protetor de tela','proteção de ecrã'),
                              ('Este app','Esta aplicação'), ('em um Mac','num Mac')]:
            value = value.replace(before, after)
    return value


def validate(copy, lang):
    for field, limit in FIELDS.items():
        value = copy[field]
        assert value.strip(), (lang, field, 'empty')
        assert len(value) <= limit, (lang, field, len(value), limit)
        if field == 'keywords':
            assert len(value.encode()) <= 100, (lang, field, 'UTF-8 limit')
    assert len(copy['screenshots']) == SCREENSHOTS, lang
    assert 'iOS 17' in copy['description'] and 'Mac' in copy['description'], lang
    for title, detail in copy['screenshots']:
        assert title.strip() and detail.strip(), lang
        assert title.count('\n') <= 1, (lang, 'headline has more than two lines', title)
    assert copy['requirement'].strip(), lang
    ui = copy['screenshot_ui']
    assert set(SCREENSHOT_UI) <= set(ui) <= set(SCREENSHOT_UI + SCREENSHOT_UI_OPTIONAL), (lang, 'screenshot_ui')
    assert all(v.strip() for v in ui.values()), (lang, 'screenshot_ui')
    for key in ('from_album', 'time_left'):
        assert ui[key].count('%@') == 1, (lang, key)
    shown = [copy[field] for field in FIELDS] + [copy['requirement'], *ui.values()]
    shown += [text for pair in copy['screenshots'] for text in pair]
    for text in shown:
        lowered = text.lower()
        assert not any(name in lowered for name in FORBIDDEN), (lang, text, 'third-party name')
    # Name and subtitle words are indexed already; repeating them wastes keyword bytes.
    indexed = set(re.findall(r'\w+', (copy['name'] + ' ' + copy['subtitle']).lower()))
    repeated = [k for k in copy['keywords'].lower().split(',') if k.strip() in indexed]
    assert not repeated, (lang, 'keywords repeat name or subtitle', repeated)
    assert ' ,' not in copy['keywords'] and ', ' not in copy['keywords'], (lang, 'keyword spaces')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    manifest_path = ROOT / 'AppStore/manifest.json'
    existing_manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    manifest = dict(existing_manifest)
    copies = {}
    for path in sorted((ROOT / 'AppStore/copy').glob('*.json')):
        copy = json.loads(path.read_text())
        overrides = copy.pop('locales', {})
        copy.setdefault('name', 'Kinrox Remote')
        validate(copy, path.stem)
        copy['locales'] = overrides
        copies[path.stem] = copy
    expected = {p.stem for p in (ROOT / 'Resources/Localization').glob('*.lproj')}
    assert set(copies) == expected, ('App language coverage', set(copies) ^ expected)
    localized = {}
    for locale, lang in {**LOCALES, 'fa': 'fa'}.items():
        copy = json.loads(regionalize(json.dumps(copies[lang], ensure_ascii=False), locale))
        # Storefronts index other localizations too (en-GB in most of them), so a locale
        # may carry its own name, subtitle and keywords instead of a duplicate.
        copy.update(copy.pop('locales', {}).get(locale, {}))
        validate(copy, locale)
        localized[locale] = copy
        if locale == 'fa':
            continue
        target = ROOT / 'AppStore/metadata' / locale
        urls = {
            'marketing_url':'https://kinrox.app/',
            'support_url':'https://kinrox.app/support/',
            'privacy_url':'https://kinrox.app/privacy/',
        }
        if args.check:
            for field in FIELDS:
                assert (target / f'{field}.txt').read_text() == copy[field] + '\n', (locale, field)
            for field, value in urls.items():
                assert (target / f'{field}.txt').read_text() == value + '\n', (locale, field)
        else:
            target.mkdir(parents=True, exist_ok=True)
            for field in FIELDS:
                (target / f'{field}.txt').write_text(copy[field] + '\n')
            for field, value in urls.items():
                (target / f'{field}.txt').write_text(value + '\n')
    # Both the Swift renderer and gallery consume these exact regional texts.
    prepared = ROOT / 'AppStore/localized-copy.json'
    if args.check:
        assert json.loads(prepared.read_text()) == localized, 'Stale localized copy; run prepare-app-store.py'
    else:
        prepared.write_text('{\n' + ',\n'.join(
            '  ' + json.dumps(locale) + ': ' + json.dumps(copy, ensure_ascii=False)
            for locale, copy in localized.items()) + '\n}\n')
    # Delivery records are maintained separately from generated metadata.
    manifest.setdefault('status', 'prepared_locally_not_uploaded')
    manifest.update({'app_name':'Kinrox Remote', 'primary_locale':'en-US', 'bundle_id':'app.kinrox.remote',
                'locales':LOCALES,
                'unsupported_store_languages':{'fa':'No Persian metadata locale in Apple’s published list; app and screenshot translations retained.'},
                'screenshots_per_locale':2 * SCREENSHOTS, 'screenshots_per_locale_per_size':SCREENSHOTS,
                'screenshot_sizes':[[1206,2622],[1320,2868]],
                'language_review':'Authored translations; native-language editorial review pending.',
                'source':'https://developer.apple.com/documentation/appstoreconnectapi/managing-metadata-in-your-app-by-using-locale-shortcodes'})
    if args.check:
        assert existing_manifest == manifest, 'Stale manifest; run prepare-app-store.py'
    else:
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
    print(f'Validated {len(copies)} app languages and {len(LOCALES)} App Store localizations.')


if __name__ == '__main__':
    main()
