#!/usr/bin/env python3
"""Render all website languages offline, or verify committed output with --check."""

import argparse
from collections import Counter
from html import escape
import json
from pathlib import Path
import posixpath
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Website"
OUTPUT = ROOT / "site"
ORIGIN = "https://kinrox.app"
PAGES = ("home", "support", "privacy")
RTL = {"ar", "fa", "he", "ur"}
SLOTS = re.compile(r"\{(\d+)\}")
TOKEN = re.compile(r"\{\{([a-z_]+)(?::([a-z0-9-]+))?\}\}")


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def page_path(locale, page):
    prefix = "" if locale == "en" else f"{locale}/"
    return prefix + ("" if page == "home" else f"{page}/")


def relative_url(current, target):
    return posixpath.relpath(target or ".", current or ".") + "/"


def validate_catalogs(languages, catalogs, markup):
    app_languages = {p.stem for p in (ROOT / "Resources/Localization").glob("*.lproj")}
    if set(languages) != app_languages:
        raise ValueError(f"Website/app language mismatch: {set(languages) ^ app_languages}")
    source = catalogs["en"]
    for locale, strings in catalogs.items():
        if strings.keys() != source.keys():
            raise ValueError(f"Missing/extra strings in {locale}: {strings.keys() ^ source.keys()}")
        for key, value in strings.items():
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f"Empty translation: {locale}/{key}")
            if Counter(SLOTS.findall(value)) != Counter(SLOTS.findall(source[key])):
                raise ValueError(f"Changed markup slots: {locale}/{key}")
            if "<" in value or ">" in value or "{{" in value:
                raise ValueError(f"Unexpected markup in translation: {locale}/{key}")
            if re.search(r"[{}]", SLOTS.sub("", value)):
                raise ValueError(f"Invalid placeholder in translation: {locale}/{key}")
    for key, tags in markup.items():
        if Counter(SLOTS.findall(source[key])) != Counter(map(str, range(len(tags)))):
            raise ValueError(f"Invalid source markup slots: {key}")


def localized_text(key, strings, markup, root, attribute=False):
    value = escape(strings[key], quote=True)
    if attribute:
        if SLOTS.search(value):
            raise ValueError(f"Markup is not allowed in an attribute: {key}")
        return value
    return SLOTS.sub(lambda m: markup[key][int(m[1])].replace("{{root}}", root), value)


def language_menu(locale, page, languages, strings):
    current = page_path(locale, page)
    label = escape(strings["language"], quote=True)
    lines = [
        '<details class="language-menu" id="languages">',
        f'  <summary aria-label="{label}: {escape(languages[locale])}">'
        f'<span aria-hidden="true">◎</span> <bdi>{escape(languages[locale])}</bdi></summary>',
        f'  <nav class="language-options" aria-label="{label}">',
    ]
    for code, name in languages.items():
        selected = ' aria-current="true"' if code == locale else ""
        href = relative_url(current, page_path(code, page))
        direction = "rtl" if code in RTL else "ltr"
        lines.append(
            f'    <a href="{href}" lang="{code}" hreflang="{code}" '
            f'dir="{direction}" data-language="{code}"{selected}>{escape(name)}</a>'
        )
    return "\n".join(lines + ["  </nav>", "</details>"])


def head(locale, page, strings, root):
    url = f"{ORIGIN}/{page_path(locale, page)}"
    title = escape(strings[f"{page}-title"], quote=True)
    description = escape(strings[f"{page}-description"], quote=True)
    social_title = escape(strings.get(f"{page}-social-title", strings[f"{page}-title"]), quote=True)
    social_description = escape(strings.get(f"{page}-social-description", strings[f"{page}-description"]), quote=True)
    # Use the shared text-free scene so previews do not show another language's headline.
    lines = [
        "<head>",
        '  <meta charset="utf-8">',
        '  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">',
        f"  <title>{title}</title>",
        f'  <meta name="description" content="{description}">',
        '  <meta name="theme-color" content="#000000">',
        f'  <link rel="canonical" href="{url}">',
    ]
    for code in LANGUAGES:
        lines.append(f'  <link rel="alternate" hreflang="{code}" href="{ORIGIN}/{page_path(code, page)}">')
    lines.extend([
        f'  <link rel="alternate" hreflang="x-default" href="{ORIGIN}/{page_path("en", page)}">',
        '  <meta property="og:type" content="website">',
        '  <meta property="og:site_name" content="Kinrox">',
        f'  <meta property="og:title" content="{social_title}">',
        f'  <meta property="og:description" content="{social_description}">',
        f'  <meta property="og:url" content="{url}">',
        f'  <meta property="og:image" content="{ORIGIN}/assets/img/og-scene.png">',
        '  <meta name="twitter:card" content="summary_large_image">',
        f'  <link rel="icon" href="{root}favicon.ico" sizes="32x32">',
        f'  <link rel="icon" href="{root}favicon.png" type="image/png">',
        f'  <link rel="apple-touch-icon" href="{root}apple-touch-icon.png">',
    ])
    for sheet in ("base", "mockups", "hero", "sections", "localization") if page == "home" else ("base", "localization"):
        lines.append(f'  <link rel="stylesheet" href="{root}assets/css/{sheet}.css">')
    lines.append(f'  <script src="{root}assets/js/main.js" defer></script>')
    if page == "home":
        data = {
            "@context": "https://schema.org", "@type": "SoftwareApplication",
            "name": "Kinrox", "applicationCategory": "MultimediaApplication",
            "softwareVersion": "0.3.0",
            "downloadUrl": "https://github.com/awaik/Kinrox/releases/download/v0.3.0/Kinrox-0.3.0-arm64.dmg",
            "operatingSystem": "macOS 14+, iOS 17+", "license": "https://www.gnu.org/licenses/gpl-3.0.html",
            "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
            "url": url, "inLanguage": locale, "description": strings["home-social-description"],
        }
        lines.extend(['  <script type="application/ld+json">',
                      "  " + json.dumps(data, ensure_ascii=False), "  </script>"])
    return "\n".join(lines + ["</head>"])


def render(locale, page, languages, strings, markup):
    current = page_path(locale, page)
    root = "../" * current.count("/") or "./"
    context = {
        "locale": locale, "direction": "rtl" if locale in RTL else "ltr", "root": root,
        "language_name": escape(languages[locale]),
        "languages": language_menu(locale, page, languages, strings),
        "head": head(locale, page, strings, root),
        **{p: relative_url(current, page_path(locale, p)) for p in PAGES},
    }

    def replace(match):
        kind, key = match.groups()
        if kind in {"a", "t"}:
            return localized_text(key, strings, markup, root, attribute=kind == "a")
        return context[kind]

    template = (SOURCE / "templates" / f"{page}.html").read_text(encoding="utf-8")
    result = TOKEN.sub(replace, template)
    if "{{" in result:
        raise ValueError(f"Unresolved template token: {locale}/{page}")
    return result


LANGUAGES = read_json(SOURCE / "languages.json")


def outputs():
    catalogs = {locale: read_json(SOURCE / "locales" / f"{locale}.json") for locale in LANGUAGES}
    markup = read_json(SOURCE / "markup.json")
    validate_catalogs(LANGUAGES, catalogs, markup)
    for locale in LANGUAGES:
        for page in PAGES:
            yield page_path(locale, page) + "index.html", render(locale, page, LANGUAGES, catalogs[locale], markup)
    sitemap = ['<?xml version="1.0" encoding="UTF-8"?>', '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
    sitemap.extend(f"  <url><loc>{ORIGIN}/{page_path(locale, page)}</loc></url>" for locale in LANGUAGES for page in PAGES)
    yield "sitemap.xml", "\n".join(sitemap + ["</urlset>", ""])
    yield "robots.txt", f"User-agent: *\nAllow: /\nSitemap: {ORIGIN}/sitemap.xml\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if committed pages need regeneration; write nothing.")
    args = parser.parse_args()
    stale = []
    for name, content in outputs():
        path = OUTPUT / name
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != content:
                stale.append(name)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
    if stale:
        print("Stale website output; run python3 Scripts/build-site.py:\n" + "\n".join(stale), file=sys.stderr)
        return 1
    print(f"{'Verified' if args.check else 'Generated'} {len(LANGUAGES) * len(PAGES)} pages in {len(LANGUAGES)} languages.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
