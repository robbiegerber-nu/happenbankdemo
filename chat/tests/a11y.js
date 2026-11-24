window.audit = () => {
  const out = {}, vis = (e) => e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden' && !e.closest('.sr-only'), all = (s) => [...document.querySelectorAll(s)].filter(vis);
  const cv = document.createElement('canvas').getContext('2d', { willReadFrequently: true });
  const rgb = (c) => { cv.clearRect(0, 0, 1, 1); cv.fillStyle = c; cv.fillRect(0, 0, 1, 1); const d = cv.getImageData(0, 0, 1, 1).data; return [d[0], d[1], d[2], d[3] / 255]; };
  const bg = (e) => { for (; e; e = e.parentElement) { const c = rgb(getComputedStyle(e).backgroundColor); if (c[3] > 0.99) return c; } return [255, 255, 255, 1]; };
  const lum = (c) => { const f = c.slice(0, 3).map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * f[0] + 0.7152 * f[1] + 0.0722 * f[2]; };
  const ratio = (a, b) => { const x = [lum(a), lum(b)].sort((p, q) => q - p); return +((x[0] + 0.05) / (x[1] + 0.05)).toFixed(2); };
  const texts = all('body *').filter((e) => [...e.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim()) && !['SCRIPT', 'STYLE'].includes(e.tagName) && !e.closest('svg'));
  const res = texts.map((e) => { const s = getComputedStyle(e), big = parseFloat(s.fontSize) >= 24 || (parseFloat(s.fontSize) >= 18.66 && +s.fontWeight >= 700); return { t: e.textContent.trim().slice(0, 30), r: ratio(rgb(s.color), bg(e)), need: big ? 3 : 4.5 }; });
  out.textChecked = res.length; out.lowest = res.sort((a, b) => a.r - b.r)[0]; out.contrastFails = res.filter((x) => x.r < x.need);
  out.placeholders = all('input').map((e) => ratio(rgb(getComputedStyle(e, '::placeholder').color), bg(e)));
  out.controlBorders = all('input,.chip,main .btn').map((e) => ratio(rgb(getComputedStyle(e).borderTopColor), bg(e.parentElement))).filter((x) => x < 3);
  out.noName = all('a[href],button,input,select').filter((e) => !(e.getAttribute('aria-label') || e.getAttribute('aria-labelledby') || (e.labels && e.labels.length) || e.textContent.trim())).map((e) => e.outerHTML.slice(0, 80));
  out.smallTargets = all('a[href],button,input').filter((e) => getComputedStyle(e).display !== 'inline').map((e) => [e.textContent.trim().slice(0, 20) || e.id, Math.round(e.getBoundingClientRect().width), Math.round(e.getBoundingClientRect().height)]).filter((x) => x[1] < 24 || x[2] < 24);
  const ids = [...document.querySelectorAll('[id]')].map((e) => e.id); out.dupIds = ids.filter((x, i) => ids.indexOf(x) !== i);
  out.badRefs = [...document.querySelectorAll('[aria-labelledby],[aria-describedby],[aria-controls],label[for]')].flatMap((e) => ['aria-labelledby', 'aria-describedby', 'aria-controls', 'for'].flatMap((a) => (e.getAttribute(a) || '').split(/\s+/).filter(Boolean))).filter((i) => !document.getElementById(i));
  out.headings = all('h1,h2,h3,h4').map((e) => e.tagName + ' ' + e.textContent.trim()); out.landmarks = ['header', 'nav', 'main', 'footer'].map((t) => t + ':' + document.querySelectorAll(t).length);
  out.first = (() => { const e = document.querySelector('a[href],button'); return e.textContent.trim() + ' -> ' + e.getAttribute('href'); })();
  out.overflow = document.documentElement.scrollWidth - innerWidth; out.size = [innerWidth, innerHeight]; out.sticky = [getComputedStyle(document.querySelector('.ask')).position, Math.round(document.querySelector('.ask').getBoundingClientRect().height)];
  out.imgNoAlt = all('img:not([alt])').length; out.svgBare = all('svg').filter((e) => !e.getAttribute('aria-hidden') && !e.getAttribute('aria-label') && !e.getAttribute('aria-labelledby') && !e.closest('[aria-hidden]')).length;
  out.covered = []; const ask = document.querySelector('.ask'); // anything focused that ends up under the fixed question box
  if (getComputedStyle(ask).position === 'sticky') for (const e of all('a[href],button').filter((x) => !ask.contains(x))) { scrollTo(0, 0); e.focus(); const r = e.getBoundingClientRect(), a = ask.getBoundingClientRect(); if (r.bottom > a.top + 1 && r.top < a.bottom - 1 && a.bottom <= innerHeight + 1) out.covered.push(e.textContent.trim().slice(0, 25)); }
  out.noFocusRing = all('a[href],button,input').filter((e) => { e.focus({ focusVisible: true }); const s = getComputedStyle(e); return s.outlineStyle === 'none' && s.boxShadow === 'none'; }).map((e) => e.textContent.trim().slice(0, 20) || e.id);
  return out;
};
