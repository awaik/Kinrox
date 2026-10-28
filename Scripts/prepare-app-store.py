#!/usr/bin/env python3
"""Validate authored copy and prepare App Store Connect metadata files."""
import argparse
import json
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


def regionalize(value, locale):
    if locale == 'es-MX':
        for before, after in [('mando','control remoto'), ('vídeo','video'), ('peli.','película.')]:
            value = value.replace(before, after)
    if locale == 'pt-PT':
        for before, after in [('controle','comando'), ('você controla','pode controlar'),
                              ('você','si'), ('a tela cheia','o ecrã inteiro'), ('tela cheia','ecrã inteiro'), ('criptografada','cifrada'),
                              ('criptografado','cifrado'), ('conectar','ligar'), ('Conecte','Ligue'),
                              ('conectado','ligado'),
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
    assert len(copy['screenshots']) == 5, lang
    assert 'iOS 17' in copy['description'] and 'Mac' in copy['description'], lang
    for title, detail in copy['screenshots']:
        assert title.strip() and detail.strip(), lang
    assert copy['requirement'].strip(), lang


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    copies = {}
    for path in sorted((ROOT / 'AppStore/copy').glob('*.json')):
        copy = json.loads(path.read_text())
        copy['name'] = 'Kinrox Remote'
        validate(copy, path.stem)
        copies[path.stem] = copy
    expected = {p.stem for p in (ROOT / 'Resources/Localization').glob('*.lproj')}
    assert set(copies) == expected, ('App language coverage', set(copies) ^ expected)
    localized = {}
    for locale, lang in {**LOCALES, 'fa': 'fa'}.items():
        copy = json.loads(regionalize(json.dumps(copies[lang], ensure_ascii=False), locale))
        if locale == 'es-MX':
            copy['subtitle'] = 'Control de películas en Mac'
        if locale == 'pt-PT':
            copy['subtitle'] = 'O comando de filmes do Mac'
        validate(copy, locale)
        localized[locale] = copy
        if locale == 'fa':
            continue
        target = ROOT / 'AppStore/metadata' / locale
        urls = {
            'marketing_url':'https://awaik.github.io/Kinrox/',
            'support_url':'https://awaik.github.io/Kinrox/support/',
            'privacy_url':'https://awaik.github.io/Kinrox/privacy/',
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
    manifest = {'app_name':'Kinrox Remote', 'primary_locale':'en-US', 'bundle_id':'app.kinrox.remote',
                'status':'prepared_locally_not_uploaded', 'locales':LOCALES,
                'unsupported_store_languages':{'fa':'No Persian metadata locale in Apple’s published list; app and screenshot translations retained.'},
                'screenshots_per_locale':5, 'screenshot_sizes':[[1206,2622],[1320,2868]],
                'language_review':'Authored translations; native-language editorial review pending.',
                'source':'https://developer.apple.com/documentation/appstoreconnectapi/managing-metadata-in-your-app-by-using-locale-shortcodes'}
    if not args.check:
        (ROOT / 'AppStore/manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
    print(f'Validated {len(copies)} app languages and {len(LOCALES)} App Store localizations.')


if __name__ == '__main__':
    main()
