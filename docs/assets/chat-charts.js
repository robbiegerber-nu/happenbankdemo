/* Draws the charts in the dashboard chat. It draws only what chat-tools.js worked out from the dashboards' data: the AI
   picks the KPI, period and filters, and never supplies a value. Line: a KPI by month. Bar: a KPI by group.
   Follows the Style Guide: zoomed lines say so and can start at zero, bars start at zero, totals are per day, events have a key. */
(function (root) {
  'use strict';
  const { esc, fmt } = Site, shown = new Set(); let zero = false, events = true, width = 0;
  function el(tag, at, parent) { const e = document.createElementNS('http://www.w3.org/2000/svg', tag); for (const k in at) e.setAttribute(k, at[k]); if (parent) parent.append(e); return e; }
  function text(p, x, y, s, cls, anchor) { const t = el('text', { x, y, ...(cls ? { class: cls } : {}), ...(anchor ? { 'text-anchor': anchor } : {}) }, p); t.textContent = s; return t; }
  function tip(node, html) { const show = (ev) => { const b = node.getBoundingClientRect(); Site.showTip(html(), ev.clientX ?? b.left + b.width / 2, ev.clientY ?? b.top + b.height / 3); }; node.addEventListener('mousemove', show); node.addEventListener('focus', show); node.addEventListener('mouseleave', Site.hideTip); node.addEventListener('blur', Site.hideTip); }
  function arrows(svg) { svg.addEventListener('keydown', (e) => { const list = [...svg.querySelectorAll('.hit')], i = list.indexOf(document.activeElement); if (i < 0) return; const n = { ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: list.length - 1 }[e.key]; if (n == null) return; e.preventDefault(); const t = list[Math.max(0, Math.min(list.length - 1, n))]; list.forEach((x) => x.setAttribute('tabindex', -1)); t.setAttribute('tabindex', 0); t.focus(); }); }
  const tick = (f, v) => (f === 'pct' || f === 'signedpct' ? (f === 'signedpct' && v > 0 ? '+' : v < 0 ? '−' : '') + Math.abs(+v.toFixed(1)) + '%' : f === 'nps' ? (v > 0 ? '+' : v < 0 ? '−' : '') + Math.abs(+v.toFixed(1)) : ['duration', 'wait'].includes(f) ? fmt.value(v, f) : f === 'count' ? fmt.shortNum(v) : String(+v.toFixed(2)));
  const last = (m) => new Date(Date.UTC(+m.slice(0, 4), +m.slice(5), 0)).toISOString().slice(0, 10);

  function line(c, body, note) {
    const f = c.kpi.format, V = (v) => fmt.value(v, f, true), P = c.pts, w = body.clientWidth || 640, H = 250, G = { t: 38, r: 14, b: 28, l: 54 }, iw = w - G.l - G.r, ih = H - G.t - G.b, aims = c.target == null ? [] : [].concat(c.target);
    const { a, b, edge } = Site.trendAxis([...P.map((p) => p.v), ...aims], f, zero), step = iw / P.length, x = (i) => G.l + (i + .5) * step, y = (v) => G.t + (b - v) / (b - a) * ih;
    const scale = Site.axisNote(note, { edge, zero, show: (v) => tick(f, v), set: (z) => { zero = z; shown.forEach((d) => d()); } });
    const s = el('svg', { viewBox: `0 0 ${w} ${H}`, height: H, role: 'group', 'aria-label': `${title(c)}, ${c.period}. ${scale} Use View as table for values.` }, body), g = el('g', { class: 'g' }, s), ax = el('g', { class: 'ax' }, s);
    for (const t of Site.ticks(a, b, 5, f)) { el('line', { x1: G.l, x2: G.l + iw, y1: y(t), y2: y(t) }, g); text(ax, G.l - 8, y(t) + 4, tick(f, t), '', 'end'); }
    const every = Math.ceil(P.length * 34 / iw); P.forEach((p, i) => { if ((P.length - 1 - i) % every === 0) text(ax, x(i), H - 8, fmt.monthShort(p.m) + (P.length <= 13 ? (p.m.endsWith('-01') || (i === 0 && w >= 560) ? ` ’${p.m.slice(2, 4)}` : '') : ` ’${p.m.slice(2, 4)}`), '', 'middle'); });
    const marks = []; if (events) { // by day within the month
      const at = (iso) => { const i = P.findIndex((p) => p.m === iso.slice(0, 7)); return G.l + (i + (+iso.slice(8) - .5) / Site.monthDays(iso.slice(0, 7))) * step; }, t0 = P[0].m + '-01', t1 = last(P[P.length - 1].m); let n = 0;
      for (const e of c.events) { const from = e.start < t0 ? t0 : e.start, to = e.end > t1 ? t1 : e.end; if (to < from) continue; n++; const ea = at(from), eb = at(to); if (e.span === 'Period' && eb - ea > 4) el('rect', { class: 'evb', x: ea, y: G.t, width: eb - ea, height: ih }, s); else el('line', { class: 'evl', x1: ea, x2: ea, y1: G.t, y2: G.t + ih }, s); marks.push([e, n, ea]); }
    }
    aims.forEach((t) => el('line', { class: 'l2', x1: G.l, x2: G.l + iw, y1: y(t), y2: y(t) }, s));
    el('path', { class: 'l1', d: Site.linePath(P.map((p, i) => ({ ...p, i })).filter((p) => p.v != null).map((p) => ({ k: p.i, x: x(p.i), y: y(p.v) }))) }, s);
    P.forEach((p, i) => {
      if (p.v != null) el('circle', { class: 'pt', cx: x(i), cy: y(p.v), r: 4 }, s);
      const say = p.v == null ? (p.few ? 'too few records' : 'no records') : V(p.v) + (c.total ? ` a day, ${V(p.total)} in total` : ''), n = p.n != null && !c.total && p.v != null ? `${fmt.count(p.n)} ${c.counted || ''}`.trim() : '', ev = c.events.filter((e) => e.start.slice(0, 7) <= p.m && e.end.slice(0, 7) >= p.m);
      const h = el('rect', { class: 'hit', x: x(i) - step / 2, y: G.t, width: step, height: ih, tabindex: i === P.length - 1 ? 0 : -1, role: 'img', 'aria-label': `${fmt.month(p.m)}: ${say}${n ? ', ' + n : ''}` }, s);
      tip(h, () => `<b>${fmt.month(p.m)}</b><br>${esc(c.kpi.name)}: <b>${esc(say)}</b>${n ? `<br><span class="muted">${esc(n)}</span>` : ''}${events ? ev.map((e) => `<br><span class="muted">Event: ${esc(e.name)}</span>`).join('') : ''}`);
    });
    arrows(s);
    // markers in their own row; those that would overlap move to the right, or a second row when that would leave the chart
    let end = -99; for (const [e, n, ex] of marks) { const mx = Math.max(ex, end + 18); end = mx; const q = el('g', { class: 'ev', transform: `translate(${Math.min(mx, w - 10)},${G.t - 14})`, role: 'img', tabindex: 0, 'aria-label': `${n}. ${e.name}, ${fmt.date(e.start)}` }, s); el('circle', { r: 12, style: 'fill:transparent;stroke:none' }, q); el('circle', { r: 8 }, q); text(q, 0, 3.5, n); tip(q, () => `<b>${n}. ${esc(e.name)}</b><br>${fmt.date(e.start)}${e.end !== e.start ? ' – ' + fmt.date(e.end) : ''}${e.description ? `<br><span class="muted">${esc(e.description)}</span>` : ''}`); }
    const gaps = P.filter((p) => p.v == null).length, key = [aims.length ? `<span><svg width="22" height="10" aria-hidden="true"><line class="l2" x2="22" y1="5" y2="5"/></svg> Target ${esc(c.kpi.targetLabel)}</span>` : '', gaps ? `<span>${gaps === 1 ? '1 month is' : gaps + ' months are'} left out: too few records.</span>` : ''].join('');
    if (key) { const d = document.createElement('div'); d.className = 'ckey'; d.innerHTML = key; body.append(d); }
    Site.eventKey(body, marks.map(([e, n]) => ({ n, e })));
  }

  function bar(c, body, note) {
    note.hidden = true; const vs = c.rows.map((r) => r.v).filter((v) => v != null), aims = c.target == null ? [] : [].concat(c.target), lo = Math.min(0, ...vs, ...aims), hi = Math.max(0, ...vs, ...aims), pc = (v) => (v - lo) / (hi - lo || 1) * 100;
    body.innerHTML = `<ul class="bars">${c.rows.map((r) => `<li><span class="bn">${esc(r.name)}</span><span class="bt" aria-hidden="true">${r.v == null ? '' : `<i style="left:${pc(Math.min(0, r.v))}%;width:${Math.abs(pc(r.v) - pc(0))}%"></i>`}${lo < 0 ? `<s style="left:${pc(0)}%"></s>` : ''}${aims.map((t) => `<u style="left:${pc(t)}%"></u>`).join('')}</span><span class="bv">${r.few ? `<span class="muted">Too few records (${fmt.count(r.n)})</span>` : `<b>${esc(r.text)}</b>${r.share ? ` <span class="muted">${esc(r.share)}</span>` : ''}`}</span></li>`).join('')}</ul>${aims.length ? `<div class="ckey"><span><u class="tk" aria-hidden="true"></u> Target ${esc(c.kpi.targetLabel)}</span></div>` : ''}`;
  }

  const title = (c) => (c.kind === 'line' ? `${c.kpi.name} by month` : `${c.title || c.kpi.name} by ${c.by}`);
  function subtitle(c) {
    return [c.kind === 'line' ? 'Monthly' : c.groups > c.rows.length ? `${c.rows.length} of ${c.groups} shown, ${c.order}` : c.order.replace(/^./, (q) => q.toUpperCase()), c.period, ...c.filters, c.kind === 'line' && c.total ? 'average per day, because months differ in length' : '', c.target == null && c.kind === 'line' && c.kpi.target == null ? 'no target' : ''].filter(Boolean).join(' · ');
  }
  function cells(c) {
    if (c.kind === 'line') return { head: ['Month', ...(c.total ? [c.kpi.short || c.kpi.name, 'Average per day'] : [c.kpi.short || c.kpi.name]), ...(c.counted && !c.total ? ['Number of ' + c.counted] : [])], rows: c.pts.slice().reverse().map((p) => { const V = (v) => (p.v == null ? (p.few ? 'Too few records' : '–') : fmt.value(v, c.kpi.format, true)); return [fmt.month(p.m), ...(c.total ? [V(p.total), V(p.v)] : [V(p.v)]), ...(c.counted && !c.total ? [p.n == null ? '–' : fmt.count(p.n)] : [])]; }) };
    const share = c.rows.some((r) => r.share), n = !share && c.counted; return { head: [c.by.replace(/^./, (q) => q.toUpperCase()), c.title || c.kpi.short || c.kpi.name, ...(share ? ['Share'] : []), ...(n ? ['Number of ' + c.counted] : [])], rows: c.rows.map((r) => [r.name, r.few ? 'Too few records' : r.text, ...(share ? [r.share || '–'] : []), ...(n ? [r.n == null ? '–' : fmt.count(r.n)] : [])]) };
  }
  /* Adds a chart to a message. The message log is read aloud as it changes, so the chart itself is kept out of that. */
  function add(parent, c) {
    const f = document.createElement('section'); f.className = 'cht'; f.setAttribute('aria-label', 'Chart: ' + title(c)); f.setAttribute('aria-live', 'off'); let table = false;
    f.innerHTML = `<div class="chead"><div><h3>${esc(title(c))}</h3><div class="sub">${esc(subtitle(c))}</div></div><div class="ctools">${c.kind === 'line' && c.events.length ? `<label class="toggle"><input type="checkbox"${events ? ' checked' : ''}> Show events</label>` : ''}<button class="btn" type="button" data-a="csv">Download CSV</button><button class="btn" type="button" data-a="tbl">View as table</button></div></div><div class="axnote" hidden></div><div class="cbody"></div>`;
    parent.append(f); const body = f.querySelector('.cbody'), note = f.querySelector('.axnote'), box = f.querySelector('.toggle input'), tb = f.querySelector('[data-a=tbl]');
    const draw = () => {
      if (!f.isConnected) { shown.delete(draw); return; }
      const focus = body.contains(document.activeElement) ? [...body.querySelectorAll('[tabindex]')].indexOf(document.activeElement) : -1;
      body.innerHTML = ''; if (box) box.checked = events;
      if (table) { note.hidden = true; const t = cells(c); body.innerHTML = `<div class="tscroll"><table><thead><tr>${t.head.map((h) => `<th scope="col">${esc(h)}</th>`).join('')}</tr></thead><tbody>${t.rows.map((r) => `<tr>${r.map((v, i) => (i ? `<td>${esc(v)}</td>` : `<th scope="row">${esc(v)}</th>`)).join('')}</tr>`).join('')}</tbody></table></div>`; } else (c.kind === 'line' ? line : bar)(c, body, note);
      if (focus >= 0) { const q = body.querySelectorAll('[tabindex]')[focus]; if (q) q.focus({ preventScroll: true }); }
    };
    tb.addEventListener('click', () => { table = !table; tb.textContent = table ? 'View as chart' : 'View as table'; if (box) box.closest('label').hidden = table; draw(); });
    f.querySelector('[data-a=csv]').addEventListener('click', () => { const t = cells(c); Site.downloadCsv('chat-' + c.id, c.through, [title(c), subtitle(c)].join(' · '), t.head, t.rows); });
    if (box) box.addEventListener('change', () => { events = box.checked; shown.forEach((d) => d()); });
    shown.add(draw); draw();
  }
  window.addEventListener('resize', () => { const w = document.documentElement.clientWidth; if (w === width) return; width = w; shown.forEach((d) => d()); });
  root.ChatCharts = { add, title };
})(window);
