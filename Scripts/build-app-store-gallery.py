#!/usr/bin/env python3
"""Build the offline review gallery and localized preview timing guides."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'AppStore'
manifest = json.loads((BASE / 'manifest.json').read_text())
locales = {**manifest['locales'], 'fa':'fa'}
prepared = json.loads((BASE / 'localized-copy.json').read_text())
data = {}
timings = [(0,4),(4,9),(9,13),(13,18),(18,23),(23,27)]
for locale, lang in locales.items():
    copy = prepared[locale].copy()
    copy['ui_language'] = lang
    data[locale] = copy
    captions = [s[0] for s in copy['screenshots']] + [copy['requirement']]
    directory = BASE / 'preview/captions'
    directory.mkdir(exist_ok=True)
    def stamp(n): return f'00:00:{n:02d},000'
    text = '\n\n'.join(f'{i+1}\n{stamp(start)} --> {stamp(end)}\n{caption}' for i,((start,end),caption) in enumerate(zip(timings,captions)))
    (directory / f'{locale}.srt').write_text(text+'\n')
html = r'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Kinrox Remote — App Store launch kit</title>
<style>*{box-sizing:border-box}body{margin:0;background:#0e0c0b;color:#f7efe4;font:16px/1.6 system-ui,sans-serif}main{max-width:1600px;padding:42px 32px;margin:auto}header{display:flex;justify-content:space-between;gap:24px;align-items:center}h1{font-size:clamp(28px,4vw,52px);line-height:1.1;margin:12px 0}h2{margin-top:40px}p{max-width:880px;color:#b9b0a9}a{color:#ffa23a}nav{display:flex;gap:24px;flex-wrap:wrap;margin:24px 0}.badge{color:#ffa23a;text-transform:uppercase;font-size:12px;letter-spacing:2px}select{background:#211a16;color:#f7efe4;border:1px solid #574239;padding:12px;border-radius:10px;font:inherit}.controls{display:flex;gap:24px;align-items:center;flex-wrap:wrap;margin:28px 0}.shots{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:16px}.shots img{width:100%;border:1px solid #392a23;border-radius:12px;box-shadow:0 14px 40px #0005}.shots a{text-decoration:none;font-size:13px}.panel{background:#171412;border:1px solid #392a23;border-radius:16px;padding:24px;margin-top:24px}.grid{display:grid;grid-template-columns:1fr 1fr;gap:24px}.copy{white-space:pre-wrap;max-width:850px}.label{font-size:12px;color:#ffa23a;text-transform:uppercase;letter-spacing:1px;margin:22px 0 6px}.timeline{display:grid;grid-template-columns:repeat(3,1fr);gap:16px}.scene{border-top:1px solid #624332;padding-top:18px}.time{color:#ffa23a;font-variant-numeric:tabular-nums}.muted{font-size:13px;color:#a89c92}footer{margin-top:60px;color:#a89c92}#unsupported{color:#ffa23a}label{display:flex;gap:10px;align-items:center}@media(max-width:900px){.shots{grid-template-columns:repeat(2,1fr)}.grid{grid-template-columns:1fr}.timeline{grid-template-columns:1fr 1fr}}@media(max-width:500px){main{padding:24px 16px}header{display:block}.timeline{grid-template-columns:1fr}}</style></head><body><main>
<header><div><div class="badge">KINROX / RELEASE STUDIO</div><h1>Movie night. Within reach.</h1><p>App Store launch assets · 30 app languages · 35 store localizations · Prepared locally, not uploaded.</p></div><div class="badge">01 / iOS launch</div></header>
<nav><a href="RELEASE-CHECKLIST.md">Submission checklist</a><a href="preview/STORYBOARD.md">App Preview script</a><a href="https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U?node-id=23-304">Editable Figma masters</a><a href="review/REVIEW-NOTES.md">Review notes</a></nav>
<div class="controls"><label>Locale <select id="locale" aria-label="Locale"></select></label><label>Image size <select id="size" aria-label="Image size"><option>1206x2622</option><option>1320x2868</option></select></label><span class="muted">Click a screenshot to open the full-resolution PNG.</span></div>
<p id="unsupported" hidden>Persian is included for the app and other channels. Apple does not offer a Persian metadata locale in its published list; do not upload this folder as an App Store localization.</p>
<div class="shots" id="shots"></div>
<div class="grid"><section class="panel"><h2>Store copy</h2><div class="label">Name</div><div id="name"></div><div class="label">Subtitle</div><div id="subtitle"></div><div class="label">Promotional text</div><div id="promotional_text"></div><div class="label">Keywords</div><div id="keywords"></div><div class="label">Description</div><div class="copy" id="description"></div><p class="muted" id="lengths"></p></section><section class="panel"><h2>First App Preview</h2><p>27 seconds. Real iPhone interface. Main controls first. Readable with audio muted. Script only — no video file has been produced.</p><div class="timeline" id="timeline"></div><p><a id="captions" href="#">Localized caption timing guide</a></p><h2>Before submission</h2><p>Confirm the developer account, price, distribution rights, encryption declaration and review contact. Publish the companion Mac download and support/privacy pages. The in-app privacy/support links are implemented. Test the signed release build on iPhone, then upload the final listing.</p><p class="muted">Translations are an authored first pass. Native-language review remains pending. The screenshots show real localized app UI with fictional demonstration data.</p></section></div>
<footer>1320×2868 large and 1206×2622 required medium iPhone PNGs · RGB without alpha · See the checklist for verification and source references.</footer>
<script id="data" type="application/json">__DATA__</script><script>
const packs=JSON.parse(document.getElementById('data').textContent),locale=document.getElementById('locale'),size=document.getElementById('size');
for(const key of Object.keys(packs).sort()){const o=document.createElement('option');o.value=key;try{o.textContent=key+' — '+new Intl.DisplayNames(['en'],{type:'language'}).of(key)}catch{o.textContent=key}locale.append(o)}
locale.value='ru';const times=['00–04 s','04–09 s','09–13 s','13–18 s','18–23 s','23–27 s'];
function render(){const key=locale.value,p=packs[key],rtl=['ar','he','ur','fa'].includes(p.ui_language);document.getElementById('unsupported').hidden=key!=='fa';const shots=document.getElementById('shots');shots.replaceChildren();p.screenshots.forEach((s,i)=>{const screen=i===3?'recents':i===4?'pairing':'remote',a=document.createElement('a'),img=document.createElement('img');a.href=`screenshots/export-20261028-regional/${key}/${size.value}/${String(i+1).padStart(2,'0')}-${screen}.png`;a.target='_blank';img.src=a.href;img.alt=s[0].replaceAll('\n',' ');a.append(img);shots.append(a)});for(const field of ['name','subtitle','promotional_text','keywords','description']){const el=document.getElementById(field);el.textContent=p[field]||'Kinrox Remote';el.dir=rtl?'rtl':'ltr';el.lang=p.ui_language}document.getElementById('lengths').textContent=`Subtitle ${p.subtitle.length}/30 · Promo ${p.promotional_text.length}/170 · Description ${p.description.length}/4000`;const timeline=document.getElementById('timeline');timeline.replaceChildren();[...p.screenshots.map(s=>s[0]),p.requirement].forEach((s,i)=>{const scene=document.createElement('div');scene.className='scene';const time=document.createElement('div');time.className='time';time.textContent=times[i];const caption=document.createElement('div');caption.textContent=s;caption.dir=rtl?'rtl':'ltr';scene.append(time,caption);timeline.append(scene)});document.getElementById('captions').href=`preview/captions/${key}.srt`}
locale.addEventListener('change',render);size.addEventListener('change',render);render();</script></main></body></html>'''
(BASE / 'index.html').write_text(html.replace('__DATA__',json.dumps(data,ensure_ascii=False).replace('</','<\\/')))
print(f'Built offline gallery and {len(locales)} caption scripts.')
