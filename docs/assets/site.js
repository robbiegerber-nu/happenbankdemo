/* Happen Bank Contact Center demo — shared header, disclaimer, footer, theme, formatting and status rules.
   Every dashboard loads this file so the rules in the wiki's Dashboard Style Guide live in one place. */
(function () {
  'use strict';

  const DISCLAIMER = 'Demonstration only. All data is simulated and does not reflect real customers, employees or performance. Not affiliated with or endorsed by Happen Bank.';
  const WIKI = 'https://github.com/robbiegerber-nu/happenbankdemo/wiki';

  // Site navigation. href = null means the dashboard is planned but not built yet.
  const NAV = [
    { group: 'Overview', items: [{ name: 'Executive scorecard', href: 'executive.html', id: 'executive' }] },
    { group: 'Operations', items: [
      { name: 'Service & access', href: null }, { name: 'Workforce management', href: null }, { name: 'Agent & team coaching', href: null }] },
    { group: 'Analysis', items: [{ name: 'Performance driver explorer', href: 'drivers.html', id: 'drivers' }, { name: 'Process stability monitor', href: 'stability.html', id: 'stability' }] },
    { group: 'Customers', items: [
      { name: 'Customer experience', href: null }, { name: 'Customer & persona insights', href: null },
      { name: 'Product launch impact', href: null }, { name: 'Self-service & channel shift', href: null }] },
    { group: 'Data', items: [{ name: 'Data quality', href: 'index.html', id: 'quality' }] }
  ];

  // ---------- Theme ----------
  const THEME_KEY = 'happen-demo-theme';
  function storedTheme() { try { return localStorage.getItem(THEME_KEY); } catch (e) { return null; } }
  function applyTheme(t) { if (t === 'light' || t === 'dark') document.documentElement.setAttribute('data-theme', t); }
  applyTheme(storedTheme());
  function currentTheme() {
    const t = document.documentElement.getAttribute('data-theme');
    if (t) return t;
    return window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }
  function toggleTheme() {
    const next = currentTheme() === 'dark' ? 'light' : 'dark';
    applyTheme(next);
    try { localStorage.setItem(THEME_KEY, next); } catch (e) { /* private mode: theme just isn't remembered */ }
    document.dispatchEvent(new CustomEvent('themechange'));
    updateThemeBtn();
  }
  function updateThemeBtn() {
    const b = document.getElementById('theme-btn');
    if (!b) return;
    const dark = currentTheme() === 'dark';
    b.textContent = dark ? '☀' : '☾';
    b.setAttribute('aria-label', dark ? 'Switch to light theme' : 'Switch to dark theme');
    b.title = b.getAttribute('aria-label');
  }

  // ---------- Formatting (Style Guide: Numbers and formatting) ----------
  const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const MINUS = '−';
  const round = (v, d) => { const f = Math.pow(10, d); return Math.round((v + Number.EPSILON) * f) / f; };  // half up
  const sign = (v) => (v > 0 ? '+' : v < 0 ? MINUS : '');
  const withCommas = (v) => Math.round(v).toLocaleString('en-US');
  function shortNum(v) {
    const a = Math.abs(v);
    if (a < 1000) return String(Math.round(v));
    const [div, suf] = a >= 1e9 ? [1e9, 'B'] : a >= 1e6 ? [1e6, 'M'] : [1e3, 'K'];
    const x = a / div;
    const s = x >= 100 ? x.toFixed(0) : x >= 10 ? x.toFixed(1) : x.toFixed(2);
    return (v < 0 ? MINUS : '') + parseFloat(s) + suf;
  }
  function secs(v) {           // durations: "6m 12s"; waits under 2 minutes: "28 s"
    const s = Math.round(v);
    const m = Math.floor(Math.abs(s) / 60), r = Math.abs(s) % 60;
    return (s < 0 ? MINUS : '') + m + 'm ' + String(r).padStart(2, '0') + 's';
  }
  const fmt = {
    month(m) { const [y, mo] = m.split('-'); return MONTHS[+mo - 1] + ' ' + y; },
    monthShort(m) { return MONTHS[+m.split('-')[1] - 1]; },
    date(iso) { const [y, mo, d] = iso.slice(0, 10).split('-'); return MONTHS[+mo - 1] + ' ' + (+d) + ', ' + y; },
    dateShort(iso) { const [, mo, d] = iso.slice(0, 10).split('-'); return MONTHS[+mo - 1] + ' ' + (+d); },
    time(isoTs) { const [h, m] = isoTs.slice(11, 16).split(':').map(Number); return `${h % 12 || 12}:${String(m).padStart(2, '0')} ${h < 12 ? 'am' : 'pm'}`; },
    count: withCommas, shortNum,
    // Display value for each KPI format. `full` = tables and tooltips.
    value(v, f, full) {
      if (v == null || isNaN(v)) return '–';
      switch (f) {
        case 'pct': return round(v, 1).toFixed(1) + '%';
        case 'signedpct': { const r = round(v, 1); return sign(r) + Math.abs(r).toFixed(1) + '%'; }
        case 'nps': { const r = Math.round(v); return sign(r) + Math.abs(r); }
        case 'rate': return round(v, 1).toFixed(1);
        case 'wait': return Math.round(v) < 120 ? Math.round(v) + ' s' : secs(v);
        case 'duration': return secs(v);
        case 'count': return full ? withCommas(v) : shortNum(v);
        default: return String(v);
      }
    },
    // The value the status is decided on: exactly what is displayed (Style Guide: status uses the displayed value).
    displayed(v, f) {
      switch (f) {
        case 'pct': case 'signedpct': case 'rate': return round(v, 1);
        case 'nps': case 'wait': case 'duration': case 'count': return Math.round(v);
        default: return v;
      }
    },
    // Change between two values, in the KPI's own unit.
    change(cur, prev, f) {
      if (cur == null || prev == null) return null;
      const a = fmt.displayed(cur, f), b = fmt.displayed(prev, f);
      let d, text;
      switch (f) {
        case 'pct': case 'signedpct': d = round(a - b, 1); text = Math.abs(d).toFixed(1) + (Math.abs(d) === 1 ? ' pt' : ' pts'); break;
        case 'nps': d = a - b; text = Math.abs(d) + (Math.abs(d) === 1 ? ' pt' : ' pts'); break;
        case 'rate': d = round(a - b, 1); text = Math.abs(d).toFixed(1); break;
        case 'wait': d = a - b; text = Math.abs(d) < 120 ? Math.abs(d) + ' s' : secs(Math.abs(d)); break;
        case 'duration': d = a - b; text = Math.abs(d) < 60 ? Math.abs(d) + ' s' : secs(Math.abs(d)); break;
        case 'count': d = b ? round((a - b) / b * 100, 1) : 0; text = Math.abs(d).toFixed(1) + '%'; break;
        default: d = a - b; text = String(Math.abs(d));
      }
      return { delta: d, text: (d > 0 ? '+' : d < 0 ? MINUS : '') + text, flat: d === 0 };
    }
  };

  // ---------- Status (Style Guide: watch bands, status uses the displayed value) ----------
  function statusOf(kpi, v) {
    if (v == null || kpi.target == null) return 'none';
    const x = fmt.displayed(v, kpi.format);
    if (kpi.better === 'higher') return x >= kpi.target ? 'good' : x >= kpi.watch ? 'watch' : 'off';
    if (kpi.better === 'lower') return x <= kpi.target ? 'good' : x <= kpi.watch ? 'watch' : 'off';
    if (kpi.better === 'range') {
      const [lo, hi] = kpi.target, [wlo, whi] = kpi.watch;
      if (x >= lo && x <= hi) return 'good';
      if (x >= wlo && x <= whi) return 'watch';
      return 'off';
    }
    return 'none';
  }
  const STATUS_WORD = { good: 'On target', watch: 'Watch', off: 'Off target', none: 'No target' };
  // Was a change good or bad for this KPI? Arrow colors follow this, never the raw direction.
  function changeQuality(kpi, cur, prev, chg) {
    if (!chg || chg.flat) return 'flat';
    if (kpi.better === 'higher') return chg.delta > 0 ? 'better' : 'worse';
    if (kpi.better === 'lower') return chg.delta < 0 ? 'better' : 'worse';
    if (kpi.better === 'range') {
      const dist = (v) => { const x = fmt.displayed(v, kpi.format); return x < kpi.target[0] ? kpi.target[0] - x : x > kpi.target[1] ? x - kpi.target[1] : 0; };
      const a = dist(cur), b = dist(prev);
      return a < b ? 'better' : a > b ? 'worse' : 'neutral';
    }
    return 'neutral';
  }

  const QUALITY_WORD = { better: 'better', worse: 'worse' };

  // ---------- Header, disclaimer, footer ----------
  function el(tag, attrs, html) {
    const e = document.createElement(tag);
    for (const k in attrs || {}) e.setAttribute(k, attrs[k]);
    if (html != null) e.innerHTML = html;
    return e;
  }
  function esc(s) { return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }

  function renderChrome(pageId) {
    const header = el('header', { class: 'site-header' });
    const nav = NAV.map((g) => {
      const cur = g.items.some((i) => i.id === pageId);
      const items = g.items.map((i) => i.href
        ? `<a href="${i.href}"${i.id === pageId ? ' aria-current="page"' : ''}>${esc(i.name)}</a>`
        : `<span aria-disabled="true">${esc(i.name)} <small>Planned</small></span>`).join('');
      return `<details><summary${cur ? ' class="current"' : ''}>${esc(g.group)}</summary><div class="menu">${items}</div></details>`;
    }).join('');
    header.innerHTML = `<div class="wrap">
        <a class="wordmark" href="executive.html"><b>Happen Bank Contact Center</b><span class="demo-tag">Demo</span></a>
        <button class="icon-btn menu-btn" id="menu-btn" aria-expanded="false" aria-controls="site-nav" aria-label="Menu">☰</button>
        <nav class="site-nav" id="site-nav" aria-label="Dashboards">${nav}</nav>
        <div class="header-tools">
          <a class="fresh-badge" id="fresh-badge" href="index.html">Checking data…</a>
          <button class="icon-btn" id="theme-btn" type="button"></button>
        </div></div>`;
    const disc = el('div', { class: 'disclaimer', role: 'note' }, `<div class="wrap"><b>Demonstration only.</b> ${esc(DISCLAIMER.replace('Demonstration only. ', ''))}</div>`);
    const strip = el('div', { class: 'gradient-strip', 'aria-hidden': 'true' });
    const skip = el('a', { class: 'skip', href: '#main' }, 'Skip to content');
    document.body.prepend(skip, header, disc, strip);
    const main = document.getElementById('main');
    if (main) { main.setAttribute('tabindex', '-1'); skip.addEventListener('click', (e) => { e.preventDefault(); main.focus(); main.scrollIntoView(); }); }

    const footer = el('footer', { class: 'site-footer' }, `<div class="wrap">
      <div><b>Demonstration only.</b> ${esc(DISCLAIMER.replace('Demonstration only. ', ''))}</div>
      <div>Definitions: <a href="${WIKI}/Data-Dictionary-KPI-Definitions" target="_blank" rel="noopener">KPI definitions</a> ·
        <a href="${WIKI}/Dashboard-Style-Guide" target="_blank" rel="noopener">Dashboard style guide</a> ·
        <a href="https://github.com/robbiegerber-nu/happenbankdemo" target="_blank" rel="noopener">Source</a></div>
      <div id="footer-generated"></div></div>`);
    document.body.append(footer);

    document.getElementById('theme-btn').addEventListener('click', toggleTheme);
    updateThemeBtn();
    const mb = document.getElementById('menu-btn'), sn = document.getElementById('site-nav');
    mb.addEventListener('click', () => { const o = sn.classList.toggle('open'); mb.setAttribute('aria-expanded', o); });
    // Close other nav menus when one opens, and all on outside click or Esc
    const dets = [...header.querySelectorAll('details')];
    dets.forEach((d) => d.addEventListener('toggle', () => { if (d.open) dets.forEach((o) => { if (o !== d) o.open = false; }); }));
    document.addEventListener('click', (e) => { if (!header.contains(e.target)) dets.forEach((d) => (d.open = false)); });
    document.addEventListener('keydown', (e) => { if (e.key === 'Escape') dets.forEach((d) => { if (d.open) { const inside = d.contains(document.activeElement); d.open = false; if (inside) d.querySelector('summary').focus(); } }); });

    loadFreshness();
  }

  // Data-freshness badge, from the Data Quality Dashboard's latest run
  function loadFreshness() {
    const b = document.getElementById('fresh-badge');
    fetch('data/summary.json').then((r) => r.json()).then((s) => {
      const o = s.overall || {}, through = s.period && s.period.end;
      let word, cls;
      if (o.failed > 0) { word = o.failed + (o.failed === 1 ? ' check failing' : ' checks failing'); cls = 'off'; }
      else if (o.warned > 0) { word = o.warned + (o.warned === 1 ? ' check to watch' : ' checks to watch'); cls = 'watch'; }
      else { word = 'all checks passing'; cls = 'good'; }
      b.innerHTML = `<span class="status ${cls}" aria-hidden="true" style="padding:0 4px"></span><span>Data through ${esc(fmt.date(through))}</span><span class="long"> · ${esc(word)}</span>`;
      b.title = `Data quality: ${o.passed} of ${o.checks} checks passed. Open the Data Quality Dashboard.`;
    }).catch(() => { b.textContent = 'Data quality'; });
  }

  // ---------- KPI definition popover (Style Guide: KPI definitions) ----------
  let openPop = null;
  function closePopover() { if (openPop) { openPop.pop.remove(); openPop.btn.setAttribute('aria-expanded', 'false'); openPop.btn.focus(); openPop = null; } }
  function infoButton(kpi) {
    const b = el('button', { class: 'info-btn', type: 'button', 'aria-label': 'About ' + kpi.name, 'aria-expanded': 'false' }, 'ⓘ');
    b.addEventListener('click', (e) => {
      e.stopPropagation();
      const wasThis = openPop && openPop.btn === b;
      closePopover();
      if (wasThis) return;
      const tgt = kpi.target == null ? 'No target' : kpi.targetLabel;
      const watch = kpi.target == null ? null
        : kpi.better === 'range' ? `${kpi.watch[0].toFixed(1)}–${kpi.target[0].toFixed(1)}% or ${kpi.target[1].toFixed(1)}–${kpi.watch[1].toFixed(1)}%`
        : kpi.better === 'higher' ? `${fmt.value(kpi.watch, kpi.format)} to just under ${fmt.value(kpi.target, kpi.format)}`
        : `just over ${fmt.value(kpi.target, kpi.format)} to ${fmt.value(kpi.watch, kpi.format)}`;
      const pop = el('div', { class: 'popover', role: 'dialog', 'aria-label': kpi.name }, `
        <h4>${esc(kpi.name)}</h4><div>${esc(kpi.definition)}</div>
        <dl><dt>Formula</dt><dd>${esc(kpi.formula)}</dd><dt>Target</dt><dd>${esc(tgt)}</dd>
        ${watch ? `<dt>Watch</dt><dd>${esc(watch)}</dd>` : ''}
        ${kpi.exclusions ? `<dt>Excludes</dt><dd>${esc(kpi.exclusions.replace(/^Excludes /, ''))}</dd>` : ''}</dl>
        <a href="${WIKI}/Data-Dictionary-KPI-Definitions#${kpi.wiki}" target="_blank" rel="noopener">Full definition ↗</a>`);
      document.body.append(pop);
      const r = b.getBoundingClientRect();
      const left = Math.min(Math.max(16, r.left + window.scrollX - 12), window.scrollX + document.documentElement.clientWidth - pop.offsetWidth - 16);
      pop.style.left = left + 'px';
      pop.style.top = (r.bottom + window.scrollY + 8) + 'px';
      b.setAttribute('aria-expanded', 'true');
      openPop = { pop, btn: b };
      pop.addEventListener('click', (ev) => ev.stopPropagation());
      // move into the popover so its link is the next Tab stop; tabbing out closes it and returns to the button
      pop.tabIndex = -1; pop.focus({ preventScroll: true });
      pop.addEventListener('focusout', (ev) => { if (openPop && openPop.pop === pop && ev.relatedTarget && !pop.contains(ev.relatedTarget)) closePopover(); });
    });
    return b;
  }
  document.addEventListener('click', () => { if (openPop) { openPop.pop.remove(); openPop.btn.setAttribute('aria-expanded', 'false'); openPop = null; } });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closePopover(); });

  // ---------- Focus across redraws ----------
  // Elements carry data-k; after a redraw the same element gets focus back, or a fallback if it is gone.
  function focusKey() { const a = document.activeElement; return a && a.closest('#main') && a !== document.getElementById('main') ? a.dataset.k || (a.id ? '#' + a.id : 'gone') : null; }
  function restoreFocus(key, fallback) {
    if (!key || (document.activeElement && document.activeElement !== document.body)) return;
    const e = key[0] === '#' ? document.getElementById(key.slice(1)) : [...document.querySelectorAll('[data-k]')].find((x) => x.dataset.k === key);
    const t = e || (fallback && document.querySelector(fallback));
    if (t) t.focus({ preventScroll: true });
  }

  // ---------- Tooltip ----------
  // stays while the pointer is over it, and Esc dismisses it
  let tip = null, tipTimer = 0;
  function showTip(html, x, y) {
    clearTimeout(tipTimer);
    if (!tip) {
      tip = el('div', { class: 'tooltip', role: 'tooltip' }); document.body.append(tip);
      tip.addEventListener('mouseenter', () => clearTimeout(tipTimer));
      tip.addEventListener('mouseleave', hideTip);
      document.addEventListener('keydown', (e) => { if (e.key === 'Escape') tip.style.display = 'none'; });
    }
    tip.innerHTML = html; tip.style.display = 'block';
    const w = tip.offsetWidth, h = tip.offsetHeight, vw = document.documentElement.clientWidth;
    let left = x + 14, top = y - h - 12;
    if (left + w > vw - 8) left = x - w - 14;
    if (top < 8) top = y + 16;
    tip.style.left = Math.max(8, left) + 'px'; tip.style.top = top + 'px';
  }
  function hideTip() { clearTimeout(tipTimer); tipTimer = setTimeout(() => { if (tip) tip.style.display = 'none'; }, 150); }

  // ---------- CSV and links (Style Guide: Export and sharing) ----------
  function downloadCsv(name, through, filters, header, rows) {
    const q = (v) => { const s = v == null ? '' : String(v); return /[",\r\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
    const text = ['# ' + DISCLAIMER, '# ' + filters.replace(/[\r\n]+/g, ' '), header.map(q).join(','), ...rows.map((r) => r.map(q).join(','))].join('\r\n');
    const a = el('a', { download: `happen-demo_${name}_${through}.csv`, href: URL.createObjectURL(new Blob(['﻿' + text], { type: 'text/csv;charset=utf-8' })) });
    document.body.append(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }
  function copyLink(b) {
    const done = (t) => { b.textContent = t; setTimeout(() => (b.textContent = 'Copy link'), 1800); };
    if (navigator.clipboard) navigator.clipboard.writeText(location.href).then(() => done('Link copied'), () => done('Copy failed'));
    else done('Copy failed');
  }

  window.Site = { focusKey, restoreFocus, QUALITY_WORD, downloadCsv, copyLink, renderChrome, fmt, statusOf, STATUS_WORD, changeQuality, infoButton, showTip, hideTip, esc, el, DISCLAIMER, WIKI, currentTheme };
})();
