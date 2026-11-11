// Figma Plugin API body that builds one localized row of the App Store screenshot set v2.
// Run through the Figma MCP `use_figma` tool as the body of `async function (DATA)`:
//   DATA = { locale, source: "en" | "ru", rtl, map: {english: localized}, font: {family, styles} | null, y }
// It clones the eight master frames of page 229:304 into a wrapper frame named
// "TMP export <locale>", replaces texts, fits them into the master geometry and returns
// the wrapper id plus a report. Export the wrapper at 10560 x 2868, then remove it.
const PAGE = '229:304';
const MASTERS = {
  en: ['229:329', '229:342', '229:355', '229:368', '229:381', '229:394', '229:407', '229:420'],
  ru: ['229:433', '229:446', '229:459', '229:472', '229:485', '229:498', '229:511', '229:524'],
};
const W = 1320, H = 2868, HEADLINE_MAX = 86, HEADLINE_MIN = 56, DETAIL_MIN = 38, GAP = 40;
const page = await figma.getNodeByIdAsync(PAGE);
await figma.setCurrentPageAsync(page);
const map = DATA.map || {};
const used = new Set();
const report = { shrunk: [], overflow: [], mixed: [] };

const SCRIPT = /[\u0590-\u08FF\u0900-\u09FF\u0E00-\u0E7F\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF\uFB1D-\uFEFF\uFF00-\uFFEF]/;
const WEIGHTS = [
  [/ultralight/i, ['ExtraLight', 'Light', 'Regular']], [/thin/i, ['Thin', 'Light', 'Regular']],
  [/light/i, ['Light', 'Regular']], [/semibold/i, ['SemiBold', 'Bold', 'Medium']],
  [/medium/i, ['Medium', 'Regular']], [/heavy|black/i, ['ExtraBold', 'Black', 'Bold']],
  [/bold/i, ['Bold', 'SemiBold']], [/.*/, ['Regular']],
];
function targetFont(current) {
  const chain = WEIGHTS.find(([re]) => re.test(current.style))[1];
  const style = chain.find((s) => DATA.font.styles.includes(s)) || 'Regular';
  return { family: DATA.font.family, style };
}
async function loadAll(node) {
  for (const f of node.getRangeAllFontNames(0, node.characters.length)) await figma.loadFontAsync(f);
}
function size(node) { return node.fontSize === figma.mixed ? null : node.fontSize; }
function setSize(node, value) {
  if (node.fontSize !== figma.mixed) { node.fontSize = value; return; }
  // Scale each run proportionally (rare: mixed sizes inside one label).
  const runs = node.getStyledTextSegments(['fontSize']);
  const base = Math.max(...runs.map((r) => r.fontSize));
  for (const r of runs) node.setRangeFontSize(r.start, r.end, Math.max(1, r.fontSize * value / base));
}
function baseSize(node) {
  return size(node) ?? Math.max(...node.getStyledTextSegments(['fontSize']).map((r) => r.fontSize));
}
// Layers inside an instance cannot be moved; auto-layout children are placed by their parent.
function managed(node) {
  const p = node.parent;
  if (node.id.startsWith('I')) return true;
  return p && 'layoutMode' in p && p.layoutMode !== 'NONE' && node.layoutPositioning !== 'ABSOLUTE';
}
// Line count, independent of the font's line height (Noto scripts are taller than SF Pro).
function lines(node) {
  const mode = node.textAutoResize, w = node.width, h0 = node.height;
  if (mode === 'NONE' || mode === 'TRUNCATE') node.textAutoResize = 'HEIGHT';
  const text = node.characters, h = node.height;
  node.characters = text.slice(0, 1) || ' ';
  const one = node.height;
  node.characters = text;
  if (node.textAutoResize !== mode) { node.textAutoResize = mode; node.resize(w, h0); }
  return Math.max(1, Math.round(h / one));
}
function box(node) {
  const b = node.absoluteBoundingBox;
  return b ? { x: b.x, y: b.y, r: b.x + b.width, b: b.y + b.height, w: b.width, h: b.height } : null;
}
function visibleFill(node) {
  return Array.isArray(node.fills) && node.fills.some((f) => f.visible !== false && (f.opacity ?? 1) > 0.05);
}
// Nearest ancestor that visibly bounds the text (a card, button, screen or dialog).
function container(node, b) {
  for (let p = node.parent; p && p.type !== 'PAGE'; p = p.parent) {
    if (!['FRAME', 'INSTANCE', 'COMPONENT'].includes(p.type)) continue;
    const pb = box(p);
    // A pill that hugs its label grows with it; its own neighbours limit the text instead.
    const hugs = 'layoutMode' in p && ((p.layoutMode === 'HORIZONTAL' && p.primaryAxisSizingMode === 'AUTO')
      || (p.layoutMode === 'VERTICAL' && p.counterAxisSizingMode === 'AUTO'));
    if (!hugs && pb && (visibleFill(p) || p.clipsContent) && pb.w > b.w + 16) return { node: p, box: pb };
  }
  return null;
}
// Width the text may take without crossing its container's inset or a neighbour on its row.
function allowedWidth(node, b) {
  const c = container(node, b);
  if (!c) return b.w;
  const pad = (inset) => Math.max(0, Math.min(inset, 32));
  let left = c.box.x + pad(b.x - c.box.x);
  let right = c.box.r - pad(c.box.r - b.r);
  const cx = b.x + b.w / 2;
  for (const o of c.node.findAllWithCriteria({ types: ['TEXT', 'INSTANCE', 'VECTOR', 'RECTANGLE', 'ELLIPSE', 'FRAME', 'BOOLEAN_OPERATION'] })) {
    if (o === node || !o.visible) continue;
    const ob = box(o);
    if (!ob || ob.w >= c.box.w * 0.9) continue;
    if (ob.x <= cx && ob.r >= cx && ob.y <= b.y + b.h / 2 && ob.b >= b.y + b.h / 2) continue; // background or ancestor
    const overlap = Math.min(ob.b, b.b) - Math.max(ob.y, b.y);
    if (overlap < Math.min(ob.h, b.h) * 0.4) continue;
    if (ob.x >= b.r - 1) right = Math.min(right, ob.x - 12);
    else if (ob.r <= b.x + 1) left = Math.max(left, ob.r + 12);
  }
  const align = node.textAlignHorizontal;
  const room = align === 'CENTER' ? 2 * Math.min(cx - left, right - cx)
    : align === 'RIGHT' ? b.r - left : right - b.x;
  return Math.max(b.w, room);
}
function fit(node, before, label) {
  // Labels that truncate with an ellipsis are measured at their natural width and must
  // fit their original box: a cut-off word reads worse than a smaller one.
  const truncating = node.textTruncation === 'ENDING';
  const measureNone = !truncating && (before.mode === 'NONE' || before.mode === 'TRUNCATE');
  if (truncating) { node.textTruncation = 'DISABLED'; node.textAutoResize = 'WIDTH_AND_HEIGHT'; }
  if (measureNone) node.textAutoResize = 'HEIGHT';
  const autoWidth = truncating || before.mode === 'WIDTH_AND_HEIGHT';
  let limit = before.w;
  const tooBig = () => (autoWidth ? node.width > limit + 1 : lines(node) > before.lines);
  if (tooBig() && !truncating) {
    limit = before.fixedLimit ?? allowedWidth(node, before.box);
    // A wrapping label first gets the free width beside it, then shrinks if still needed.
    if (!autoWidth && !managed(node) && limit > before.w + 1) {
      node.resize(limit, node.height);
      node.textAutoResize = 'HEIGHT';
      if (node.textAlignHorizontal === 'CENTER') node.x = before.x - (limit - before.w) / 2;
      if (node.textAlignHorizontal === 'RIGHT') node.x = before.x - (limit - before.w);
    }
  }
  let current = baseSize(node);
  const floor = current * 0.6;
  while (tooBig() && current > floor) {
    current = Math.max(floor, current * 0.95);
    setSize(node, current);
  }
  if (current < before.size * 0.999) report.shrunk.push([label, node.characters.slice(0, 40), Math.round(100 * current / before.size)]);
  if (tooBig()) report.overflow.push([label, node.characters.slice(0, 40)]);
  if (truncating || measureNone) {
    if (before.mode !== 'WIDTH_AND_HEIGHT') node.resize(truncating ? before.w : node.width, before.h);
    node.textAutoResize = before.mode;
    if (truncating) node.textTruncation = 'ENDING';
  }
  if (before.mode === 'WIDTH_AND_HEIGHT' && !managed(node)) {
    if (node.textAlignHorizontal === 'CENTER') node.x = before.x + before.w / 2 - node.width / 2;
    if (node.textAlignHorizontal === 'RIGHT') node.x = before.x + before.w - node.width;
    node.y = before.y + before.h / 2 - node.height / 2;
  }
}
async function replace(node, label, fitIt) {
  const english = node.characters;
  if (!(english in map)) return false;
  used.add(english);
  await loadAll(node);
  const before = { w: node.width, h: node.height, x: node.x, y: node.y, mode: node.textAutoResize, size: baseSize(node), box: box(node) };
  before.lines = before.mode === 'WIDTH_AND_HEIGHT' ? 1 : lines(node);
  const value = map[english];
  node.characters = value;
  if (DATA.font && SCRIPT.test(value)) {
    const fonts = node.getRangeAllFontNames(0, value.length);
    if (fonts.length > 1) report.mixed.push([label, value.slice(0, 30)]);
    const target = targetFont(fonts[0]);
    await figma.loadFontAsync(target);
    node.fontName = target;
  }
  if (DATA.rtl && value !== english && /[\u0590-\u08FF\uFB1D-\uFEFF]/.test(value) && node.textAlignHorizontal === 'LEFT' && fitIt === 'header') {
    node.textAlignHorizontal = 'RIGHT';
  }
  if (fitIt === true) fit(node, before, label);
  return true;
}

const wrapper = figma.createFrame();
wrapper.name = `TMP export ${DATA.locale}`;
wrapper.fills = [];
wrapper.clipsContent = true;
wrapper.resize(W * 8, H);
wrapper.x = 0;
wrapper.y = DATA.y ?? 8000;
const frames = [];
for (const [i, id] of MASTERS[DATA.source].entries()) {
  const clone = (await figma.getNodeByIdAsync(id)).clone();
  wrapper.appendChild(clone);
  clone.x = i * W;
  clone.y = 0;
  clone.name = `${DATA.locale} / ${clone.name.split(' / ').slice(1).join(' / ')}`;
  frames.push(clone);
}

const headers = [];
for (const [i, frame] of frames.entries()) {
  const header = frame.children.find((c) => c.name === 'Header');
  const footer = frame.children.find((c) => c.name === 'Footer');
  const others = frame.children.filter((c) => c !== header && c !== footer && c.type !== 'ELLIPSE');
  const limit = Math.min(...others.map((o) => o.y)) - GAP;
  const headline = header.findOne((n) => n.name === 'Headline');
  const detail = header.findOne((n) => n.name === 'Detail');
  const offer = footer.findOne((n) => n.type === 'TEXT' && n.name === 'Offer');
  for (const t of [headline, detail]) await replace(t, `${i + 1}/header`, 'header');
  const offerBefore = { w: offer.width, h: offer.height, x: offer.x, y: offer.y, mode: offer.textAutoResize, size: baseSize(offer), box: box(offer), fixedLimit: 1146 };
  if (await replace(offer, `${i + 1}/footer`, false)) fit(offer, offerBefore, `${i + 1}/footer`);
  // Right after clone() Figma materializes nested instance layers lazily; a criteria
  // search alone then misses texts inside them. Walking the children first loads them.
  const walk = (n) => { if ('children' in n) for (const k of n.children) walk(k); };
  walk(frame);
  for (const t of frame.findAllWithCriteria({ types: ['TEXT'] })) {
    if (t === headline || t === detail || t === offer) continue;
    await replace(t, `${i + 1}/${t.name}`, true);
  }
  await loadAll(headline);
  await loadAll(detail);
  headers.push({ header, headline, detail, limit, frame });
}

// One headline size for the whole row (Figma notes): at most two lines, and every
// header must end above its frame's devices.
const headlineLines = (t, s) => Math.round(t.height / (s * 1.06));
let headlineSize = HEADLINE_MAX;
for (;;) {
  for (const h of headers) { h.headline.fontSize = headlineSize; h.detail.fontSize = 48; }
  let ok = headers.every((h) => headlineLines(h.headline, headlineSize) <= 2);
  if (ok) {
    for (const h of headers) {
      let d = 48;
      while (h.header.y + h.header.height > h.limit && d > DETAIL_MIN) { d -= 2; h.detail.fontSize = d; }
      if (h.header.y + h.header.height > h.limit) ok = false;
    }
  }
  if (ok || headlineSize <= HEADLINE_MIN) break;
  headlineSize -= 2;
}
for (const h of headers) {
  if (headlineLines(h.headline, headlineSize) > 2 || h.header.y + h.header.height > h.limit) report.overflow.push([h.frame.name, 'header']);
}

const missing = Object.keys(map).filter((k) => !used.has(k));
return {
  wrapper: wrapper.id, locale: DATA.locale, headlineSize,
  details: headers.map((h) => h.detail.fontSize), missing, ...report,
};
