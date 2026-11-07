"""Render English blog pages, RSS 2.0 feed, and llms.txt for the Kinrox static site."""

from datetime import datetime, timezone
from email.utils import format_datetime
from html import escape
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
BLOG_DIR = ROOT / "Website" / "blog"
ORIGIN = "https://kinrox.app"
DMG_URL = "https://github.com/awaik/Kinrox/releases/download/v0.5.5/Kinrox-0.5.5-arm64.dmg"

INLINE_CODE = re.compile(r"`([^`]+)`")
INLINE_LINK = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")
INLINE_BOLD = re.compile(r"\*\*([^*]+)\*\*")
INLINE_STRIKE = re.compile(r"~~([^~]+)~~")
IMAGE_LINE = re.compile(r"^!\[([^\]]*)\]\(([^)]+)\)$")


def slugify(text):
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return slug or "section"


def parse_frontmatter(raw):
    if not raw.startswith("---\n"):
        raise ValueError("Blog post missing YAML frontmatter")
    _, fm_block, body = raw.split("---\n", 2)
    meta = {}
    for line in fm_block.strip().splitlines():
        if not line.strip() or ":" not in line:
            continue
        key, val = line.split(":", 1)
        key = key.strip()
        val = val.strip()
        if val.startswith("[") and val.endswith("]"):
            meta[key] = json.loads(val)
        elif val.startswith('"') and val.endswith('"'):
            meta[key] = json.loads(val)
        else:
            meta[key] = val
    return meta, body.strip()


def format_inline(text, root_prefix, absolute=False):
    code_slots = []

    def save_code(match):
        code_slots.append(f"<code>{escape(match.group(1))}</code>")
        return f"\x00CODE{len(code_slots) - 1}\x00"

    working = INLINE_CODE.sub(save_code, text)

    link_slots = []

    def save_link(match):
        label = escape(match.group(1))
        href = match.group(2).strip()
        if href.startswith("/"):
            href = f"{ORIGIN}{href}" if absolute else f"{root_prefix}{href.lstrip('/')}"
        link_slots.append(f'<a href="{escape(href, quote=True)}">{label}</a>')
        return f"\x00LINK{len(link_slots) - 1}\x00"

    working = INLINE_LINK.sub(save_link, working)
    working = escape(working)
    working = INLINE_BOLD.sub(r"<strong>\1</strong>", working)
    working = INLINE_STRIKE.sub(r"<del>\1</del>", working)

    for idx, html in enumerate(link_slots):
        working = working.replace(f"\x00LINK{idx}\x00", html)
    for idx, html in enumerate(code_slots):
        working = working.replace(f"\x00CODE{idx}\x00", html)
    return working


def render_markdown(body, root_prefix, absolute=False):
    lines = body.splitlines()
    blocks = []
    i = 0
    seen_ids = set()

    def unique_id(base):
        candidate = base
        counter = 2
        while candidate in seen_ids:
            candidate = f"{base}-{counter}"
            counter += 1
        seen_ids.add(candidate)
        return candidate

    while i < len(lines):
        line = lines[i].strip()
        if not line:
            i += 1
            continue

        # Image block
        img_match = IMAGE_LINE.match(line)
        if img_match:
            alt, src = img_match.groups()
            if src.startswith(f"{ORIGIN}/"):
                src = src[len(ORIGIN):]
            if src.startswith("/"):
                resolved_src = f"{ORIGIN}{src}" if absolute else f"{root_prefix}{src.lstrip('/')}"
            else:
                resolved_src = src
            blocks.append(
                f'<figure class="article-figure">'
                f'<img src="{escape(resolved_src, quote=True)}" alt="{escape(alt, quote=True)}" loading="lazy">'
                f"<figcaption>{escape(alt)}</figcaption>"
                f"</figure>"
            )
            i += 1
            continue

        # Standalone YouTube link
        if line.startswith("https://youtu.be/") or line.startswith("https://www.youtube.com/"):
            url = escape(line, quote=True)
            blocks.append(
                f'<div class="video-callout">'
                f'<span class="video-callout-label"><i class="ic ic-play"></i>Video Demonstration on YouTube</span>'
                f'<a class="btn btn-fire" href="{url}">Watch Demo ({url})</a>'
                f"</div>"
            )
            i += 1
            continue

        # Headings
        if line.startswith("### "):
            raw_title = line[4:].strip()
            hid = unique_id(slugify(raw_title))
            blocks.append(f'<h3 id="{hid}">{format_inline(raw_title, root_prefix, absolute)}</h3>')
            i += 1
            continue
        if line.startswith("## "):
            raw_title = line[3:].strip()
            hid = unique_id(slugify(raw_title))
            blocks.append(f'<h2 id="{hid}">{format_inline(raw_title, root_prefix, absolute)}</h2>')
            i += 1
            continue

        # Blockquote
        if line.startswith(">"):
            quote_lines = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                quote_lines.append(lines[i].strip().lstrip(">").strip())
                i += 1
            paragraphs = "".join(f"<p>{format_inline(q, root_prefix, absolute)}</p>" for q in quote_lines if q)
            blocks.append(f"<blockquote>{paragraphs}</blockquote>")
            continue

        # Table
        if line.startswith("|") and i + 1 < len(lines) and re.match(r"^\|\s*---", lines[i + 1].strip()):
            headers = [c.strip() for c in line.strip("|").split("|")]
            i += 2
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                rows.append([c.strip() for c in lines[i].strip().strip("|").split("|")])
                i += 1
            thead = "".join(f"<th>{format_inline(h, root_prefix, absolute)}</th>" for h in headers)
            tbody_rows = []
            for row in rows:
                cells = "".join(f"<td>{format_inline(c, root_prefix, absolute)}</td>" for c in row)
                tbody_rows.append(f"<tr>{cells}</tr>")
            blocks.append(
                f'<div class="article-table-wrap"><table class="article-table">'
                f"<thead><tr>{thead}</tr></thead>"
                f'<tbody>{"".join(tbody_rows)}</tbody>'
                f"</table></div>"
            )
            continue

        # Unordered list
        if line.startswith("- "):
            items = []
            while i < len(lines) and lines[i].strip().startswith("- "):
                items.append(f"<li>{format_inline(lines[i].strip()[2:].strip(), root_prefix, absolute)}</li>")
                i += 1
            blocks.append(f'<ul>{"".join(items)}</ul>')
            continue

        # Ordered list
        if re.match(r"^\d+\.\s+", line):
            items = []
            while i < len(lines) and re.match(r"^\d+\.\s+", lines[i].strip()):
                item_text = re.sub(r"^\d+\.\s+", "", lines[i].strip())
                items.append(f"<li>{format_inline(item_text, root_prefix, absolute)}</li>")
                i += 1
            blocks.append(f'<ol>{"".join(items)}</ol>')
            continue

        # Regular paragraph
        para_lines = []
        while i < len(lines):
            cur = lines[i].strip()
            if (
                not cur
                or cur.startswith("#")
                or cur.startswith(">")
                or cur.startswith("- ")
                or cur.startswith("|")
                or IMAGE_LINE.match(cur)
                or re.match(r"^\d+\.\s+", cur)
                or cur.startswith("https://youtu.be/")
            ):
                break
            para_lines.append(cur)
            i += 1
        blocks.append(f'<p>{format_inline(" ".join(para_lines), root_prefix, absolute)}</p>')

    return "\n".join(blocks)


def load_posts():
    posts = []
    for path in sorted(BLOG_DIR.glob("*.md"), reverse=True):
        meta, body = parse_frontmatter(path.read_text(encoding="utf-8"))
        meta["body"] = body
        posts.append(meta)
    return posts


def blog_nav(root_prefix):
    return (
        f'<header class="nav"><div class="container nav-inner">'
        f'<a class="brand" href="{root_prefix}" aria-label="Kinrox home">'
        f'<img src="{root_prefix}assets/img/kinrox-icon.webp" alt="" width="34" height="34">Kinrox</a>'
        f'<nav class="nav-links" aria-label="Sections">'
        f'<a href="{root_prefix}#remote">Remote</a>'
        f'<a href="{root_prefix}#how">Pairing</a>'
        f'<a href="{root_prefix}#player">Player</a>'
        f'<a href="{root_prefix}#spotify">Spotify</a>'
        f'<a href="{root_prefix}#privacy">Privacy</a>'
        f'<a href="{root_prefix}blog/">Blog</a></nav>'
        f'<div class="nav-actions">'
        f'<a class="btn btn-glass" href="{root_prefix}rss.xml">RSS</a>'
        f'<a class="btn btn-glass" href="https://github.com/awaik/Kinrox">GitHub</a>'
        f"</div></div></header>"
    )


def blog_footer(root_prefix):
    return (
        f'<footer class="footer"><div class="container footer-inner">'
        f'<a class="brand" href="{root_prefix}">'
        f'<img src="{root_prefix}assets/img/kinrox-icon.webp" alt="" width="34" height="34" loading="lazy">Kinrox</a>'
        f"<span>Mac: GPL-3.0 · iPhone: Personal use only</span>"
        f'<nav class="footer-links" aria-label="Footer">'
        f'<a href="{root_prefix}blog/">Blog</a>'
        f'<a href="{root_prefix}rss.xml">RSS</a>'
        f'<a href="{root_prefix}llms.txt">llms.txt</a>'
        f'<a href="{root_prefix}privacy/">Privacy</a>'
        f'<a href="{root_prefix}support/">Support</a>'
        f'<a href="https://github.com/awaik/Kinrox">Source code</a>'
        f'<a href="https://github.com/awaik/Kinrox/blob/main/LICENSING.md">License</a>'
        f'<a href="https://github.com/awaik/Kinrox/issues">Issues</a>'
        f"</nav></div></footer>"
    )


def blog_head(root, title, description, url, og_image, og_type="website", extra=""):
    return f"""<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>{escape(title)}</title>
  <meta name="description" content="{escape(description, quote=True)}">
  <meta name="theme-color" content="#000000">
  <link rel="canonical" href="{escape(url, quote=True)}">
  <link rel="alternate" type="application/rss+xml" title="Kinrox Blog RSS" href="{ORIGIN}/rss.xml">
  <meta property="og:type" content="{og_type}">
  <meta property="og:site_name" content="Kinrox">
  <meta property="og:title" content="{escape(title, quote=True)}">
  <meta property="og:description" content="{escape(description, quote=True)}">
  <meta property="og:url" content="{escape(url, quote=True)}">
  <meta property="og:image" content="{escape(og_image, quote=True)}">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="{escape(title, quote=True)}">
  <meta name="twitter:description" content="{escape(description, quote=True)}">
  <meta name="twitter:image" content="{escape(og_image, quote=True)}">
  <link rel="icon" href="{root}favicon.ico" sizes="32x32">
  <link rel="icon" href="{root}favicon.png" type="image/png">
  <link rel="apple-touch-icon" href="{root}apple-touch-icon.png">
  <link rel="stylesheet" href="{root}assets/css/base.css">
  <link rel="stylesheet" href="{root}assets/css/localization.css">
  <link rel="stylesheet" href="{root}assets/css/blog.css">
  <script src="{root}assets/js/main.js" defer></script>{extra}
</head>"""


def render_blog_index(posts):
    root = "../"
    url = f"{ORIGIN}/blog/"
    title = "Kinrox Blog — Engineering Notes on Native macOS, SwiftUI, libmpv & Spotify"
    description = (
        "Engineering deep dives on building Kinrox: a native Swift 6 & SwiftUI video player on libmpv "
        "with an encrypted iPhone remote and a 196 MB standalone Spotify player."
    )
    cards = []
    for post in posts:
        slug = post["slug"]
        cover = f'{root}{post["cover_image"].lstrip("/")}'
        tags_html = "".join(f'<span class="blog-tag">#{escape(t)}</span>' for t in post.get("tags", []))
        cards.append(
            f'<article class="blog-card">'
            f'<div class="blog-card-media"><img src="{escape(cover, quote=True)}" alt="{escape(post["cover_alt"], quote=True)}" width="1800" height="1000"></div>'
            f'<div class="blog-card-body">'
            f'<div class="blog-card-meta"><time datetime="{escape(post["date"])}">{escape(post["date"])}</time><span>·</span><span>{escape(post.get("reading_time", "12 min read"))}</span></div>'
            f'<h2 class="blog-card-title"><a href="./{escape(slug)}/">{escape(post["title"])}</a></h2>'
            f'<p class="blog-card-excerpt">{escape(post["description"])}</p>'
            f'<div class="blog-tags">{tags_html}</div>'
            f'<div><a class="btn btn-fire" href="./{escape(slug)}/">Read article</a></div>'
            f"</div></article>"
        )

    head_html = blog_head(root, title, description, url, f"{ORIGIN}/assets/img/blog/kinrox-blog-cover.jpg")
    return f"""<!doctype html>
<html lang="en" dir="ltr">
{head_html}
<body>
<a class="skip-link" href="#main">Skip to content</a>
{blog_nav(root)}
<main id="main">
  <section class="blog-hero">
    <div class="container">
      <span class="overline">Engineering Blog</span>
      <h1 class="display">Notes from building Kinrox.</h1>
      <p class="lead">Deep dives into native Swift 6, SwiftUI performance on macOS, libmpv, local-network cryptography, and squeezing Spotify down from 2 GB to 196 MB.</p>
      <div class="blog-meta-bar">
        <a class="chip" href="{root}rss.xml"><i class="dot ember"></i>RSS Feed (rss.xml)</a>
        <a class="chip" href="{root}llms.txt">llms.txt for AI parsers</a>
      </div>
    </div>
  </section>
  <section class="container"><div class="blog-grid">{"".join(cards)}</div></section>
</main>
{blog_footer(root)}
</body>
</html>"""


def render_blog_post(post):
    root = "../../"
    url = post["canonical_url"]
    title = post["title"]
    description = post["description"]
    og_image = f'{ORIGIN}{post.get("og_image", post["cover_image"])}'
    article_html = render_markdown(post["body"], root, absolute=False)
    tags_html = "".join(f'<span class="blog-tag">#{escape(t)}</span>' for t in post.get("tags", []))
    ld_json = {
        "@context": "https://schema.org", "@type": "BlogPosting",
        "headline": title, "description": description,
        "datePublished": f'{post["date"]}T09:00:00Z', "dateModified": f'{post["date"]}T09:00:00Z',
        "author": {"@type": "Person", "name": post.get("author", "Alex"), "url": "https://github.com/awaik"},
        "publisher": {"@type": "Organization", "name": "Kinrox", "url": ORIGIN},
        "image": og_image, "url": url,
        "mainEntityOfPage": {"@type": "WebPage", "@id": url}, "inLanguage": "en",
    }
    extra = (
        f'\n  <meta property="article:published_time" content="{escape(post["date"])}T09:00:00Z">'
        f'\n  <script type="application/ld+json">\n  {json.dumps(ld_json, ensure_ascii=False)}\n  </script>'
    )
    head_html = blog_head(root, f"{title} — Kinrox Blog", description, url, og_image, "article", extra)
    return f"""<!doctype html>
<html lang="en" dir="ltr">
{head_html}
<body>
<a class="skip-link" href="#main">Skip to content</a>
{blog_nav(root)}
<main id="main" class="article-wrap">
  <article class="container">
    <header class="article-header">
      <div class="article-breadcrumbs"><a href="{root}blog/">← Kinrox Blog</a></div>
      <h1 class="display">{escape(title)}</h1>
      <div class="article-byline">
        <time datetime="{escape(post["date"])}">{escape(post["date"])}</time>
        <span>·</span><span>{escape(post.get("reading_time", "14 min read"))}</span>
        <span>·</span><span>By {escape(post.get("author", "Alex"))}</span>
      </div>
      <div class="blog-tags">{tags_html}</div>
    </header>
    <div class="article-prose">
{article_html}
    </div>
    <aside class="article-cta" aria-labelledby="cta-title">
      <h2 class="display" id="cta-title">Try Kinrox on your Mac</h2>
      <p>Native Swift 6 &amp; SwiftUI video player on libmpv with an encrypted iPhone remote, standalone Spotify playback, and the Matrix screensaver.</p>
      <div class="article-cta-actions">
        <a class="btn btn-fire" href="{DMG_URL}">Download for Mac (DMG)</a>
        <a class="btn btn-glass" href="https://github.com/awaik/Kinrox">View Source on GitHub</a>
        <a class="btn btn-glass" href="{root}rss.xml">Subscribe via RSS</a>
      </div>
    </aside>
  </article>
</main>
{blog_footer(root)}
</body>
</html>"""


def render_rss(posts):
    items = []
    for post in posts:
        dt = datetime.strptime(post["date"], "%Y-%m-%d").replace(hour=9, tzinfo=timezone.utc)
        pub_date = format_datetime(dt, usegmt=True)
        url = post["canonical_url"]
        html_content = render_markdown(post["body"], f"{ORIGIN}/", absolute=True)
        items.append(
            f"""    <item>
      <title>{escape(post["title"])}</title>
      <link>{escape(url)}</link>
      <guid isPermaLink="true">{escape(url)}</guid>
      <pubDate>{pub_date}</pubDate>
      <description>{escape(post["description"])}</description>
      <content:encoded><![CDATA[{html_content}]]></content:encoded>
    </item>"""
        )

    latest_dt = datetime.strptime(posts[0]["date"], "%Y-%m-%d").replace(hour=9, tzinfo=timezone.utc)
    last_build = format_datetime(latest_dt, usegmt=True)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" xmlns:content="http://purl.org/rss/1.0/modules/content/">
  <channel>
    <title>Kinrox Blog</title>
    <link>{ORIGIN}/blog/</link>
    <description>Engineering deep dives from Kinrox: native Swift 6 &amp; SwiftUI macOS video player on libmpv, encrypted LAN iPhone remote, and standalone 196 MB Spotify player.</description>
    <language>en</language>
    <lastBuildDate>{last_build}</lastBuildDate>
    <atom:link href="{ORIGIN}/rss.xml" rel="self" type="application/rss+xml"/>
{chr(10).join(items)}
  </channel>
</rss>
"""


def render_llms_txt(posts):
    post_lines = []
    for post in posts:
        post_lines.append(
            f"- [{post['title']}]({post['canonical_url']}): {post['description']}"
        )
    articles_section = "\n".join(post_lines)
    return f"""# Kinrox

> Kinrox is a native macOS video and Spotify music player written in Swift 6 and SwiftUI (built on libmpv and Spotify Soloist) with an encrypted local-network iPhone companion remote and a built-in 30 fps Matrix screensaver. No WebViews, no Electron, no cloud accounts, and no telemetry.

## Key Facts & Architecture

- **Platform**: macOS 14+ on Apple Silicon (`arm64`) for the Mac player (`PlayerMac`); iOS 17+ for the companion iPhone remote (`RemoteiOS`).
- **Video Engine**: `libmpv 0.41.0` (`FFmpeg 9.0.1`, OpenGL render context, hardware decoding via `VideoToolbox`), isolated behind the Swift `PlayerEngine` protocol. Supports `MKV`, `MP4`, `M4V`, `MOV`, `AVI`, `WebM`, `TS`, recursive external audio/subtitle track discovery in nested folders, and natural Finder-ordered folder playlists.
- **Standalone Spotify Music Mode**: Uses 180–196 MB of RAM in `Kinrox.app` + 25–27 MiB in Spotify's official headless `com.spotify.soloist` binary (~10x less memory than the ~2 GB Electron-based `Spotify.app`) and <1% of a single CPU core (~0% when occluded/minimized). Operates with `Spotify.app` completely closed. Includes a local `SQLite` library cache (opens 10,000 tracks in 40.98 ms with 0 HTTP requests), `O(1)` catalog indexing, a 20-second pause-parking mechanism (0 MB RAM and 0% CPU during long pauses), and a 53 KB C watchdog reaper (`KinroxSoloistHost`) to prevent orphaned audio processes on `SIGKILL`.
- **Encrypted LAN iPhone Remote**: Zero-configuration discovery via Bonjour (`_kinrox._tcp`), 6-digit PIN pairing, and authenticated Diffie-Hellman handshake using Apple `CryptoKit` (`X25519` ECDH + `HKDF-SHA256` + `ChaCha20-Poly1305` AEAD) over local WebSocket (`Network.framework`). Pairing tokens are stored in the macOS Data Protection Keychain and iOS Keychain.
- **Matrix Screensaver**: Built-in 30 fps falling katakana/glyph rain on `SwiftUI Canvas`, triggered from Mac (`Screensaver -> Matrix`) or directly from the iPhone remote after hardware pause confirmation.
- **Localization**: Full UI and website support for 30 languages (including RTL layout for Arabic, Hebrew, Persian, and Urdu).
- **Licensing**: Mac player is open source under `GPL-3.0-only`; iPhone remote source code is available under the Kinrox Remote Personal Use License 1.0 (free for personal non-commercial use and source-sharing forks).

## Primary Links

- [Official Website]({ORIGIN}/): Landing page, feature overview, and localized documentation in 30 languages.
- [Signed & Notarized Mac Download (v0.5.5 DMG)]({DMG_URL}): Direct download for Apple Silicon Macs (macOS 14+).
- [GitHub Repository](https://github.com/awaik/Kinrox): Complete Swift 6 source code for `PlayerMac`, `RemoteiOS`, `KinroxMusic`, `RemoteProtocol`, and engineering research reports (`docs/RESEARCHES`).
- [Engineering Blog]({ORIGIN}/blog/): Deep-dive articles on architecture, benchmarks, and debugging.
- [RSS Feed]({ORIGIN}/rss.xml): RSS 2.0 feed with full article content.
- [Support & Troubleshooting]({ORIGIN}/support/): Pairing instructions, local network setup, and demo mode (`-KinroxDemo`).
- [Privacy Policy]({ORIGIN}/privacy/): Local-first data handling and optional Spotify connection terms.

## Blog Articles

{articles_section}
"""


def blog_outputs():
    posts = load_posts()
    yield "blog/index.html", render_blog_index(posts)
    for post in posts:
        yield f'blog/{post["slug"]}/index.html', render_blog_post(post)
    yield "rss.xml", render_rss(posts)
    yield "llms.txt", render_llms_txt(posts)


def blog_urls():
    posts = load_posts()
    urls = [f"{ORIGIN}/blog/"]
    urls.extend(post["canonical_url"] for post in posts)
    return urls
