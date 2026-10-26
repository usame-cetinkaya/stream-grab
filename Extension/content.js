// StreamGrab: draws the "Download this video" button (with its quality menu) over the
// video playing in this frame, IDM-style.
(() => {
  if (window.__streamGrab) return;
  window.__streamGrab = true;

  let items = [];
  let target = null;      // the <video> the button is attached to
  let dismissedCount = -1; // item count when the user closed the button
  let menuOpen = false;
  let host, ui;

  // ---------- Finding videos ----------

  function allVideos(root = document, out = []) {
    for (const v of root.querySelectorAll('video')) out.push(v);
    // Players built from web components keep the <video> in a shadow root.
    for (const el of root.querySelectorAll('*')) if (el.shadowRoot) allVideos(el.shadowRoot, out);
    return out;
  }

  function bigEnough(r) { return r.width >= 200 && r.height >= 110; }

  function pickVideo() {
    let best = null, bestScore = 0;
    for (const v of allVideos()) {
      const r = v.getBoundingClientRect();
      if (!bigEnough(r) || r.bottom < 0 || r.right < 0 || r.top > innerHeight || r.left > innerWidth) continue;
      const score = r.width * r.height * (v.paused ? 1 : 4);
      if (score > bestScore) { best = v; bestScore = score; }
    }
    return best;
  }

  // ---------- Talking to the extension ----------

  let loadTimer;
  function load() {
    clearTimeout(loadTimer);
    loadTimer = setTimeout(async () => {
      const hasVideo = allVideos().some((v) => bigEnough(v.getBoundingClientRect()));
      let res = null;
      try { res = await chrome.runtime.sendMessage({ type: 'items', hasVideo }); } catch { /* extension reloaded */ }
      items = res?.items || [];
      render();
    }, 150);
  }

  chrome.runtime.onMessage.addListener((m) => { if (m.type === 'refresh') load(); });
  for (const ev of ['play', 'playing', 'loadedmetadata']) document.addEventListener(ev, load, true);
  load();

  // ---------- UI ----------

  const CSS = `
    :host { all: initial; }
    .wrap { position: fixed; z-index: 2147483647; display: flex; flex-direction: column; align-items: flex-end; gap: 6px;
      font: 13px/1.3 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; color: #fff;
      opacity: .6; transition: opacity .15s; pointer-events: auto; }
    .wrap.hot, .wrap.open { opacity: 1; }
    .bar { display: flex; border-radius: 8px; overflow: hidden; background: rgba(17,24,39,.92);
      box-shadow: 0 2px 10px rgba(0,0,0,.35); border: 1px solid rgba(255,255,255,.15); }
    button { all: unset; cursor: pointer; display: flex; align-items: center; gap: 6px; padding: 6px 10px; }
    button:hover { background: rgba(255,255,255,.12); }
    .main { font-weight: 600; }
    .main svg { width: 15px; height: 15px; flex: none; }
    .close { padding: 6px 8px; color: rgba(255,255,255,.65); border-left: 1px solid rgba(255,255,255,.15); }
    .menu { min-width: 230px; max-height: 320px; overflow-y: auto; border-radius: 8px; background: rgba(17,24,39,.96);
      box-shadow: 0 6px 24px rgba(0,0,0,.4); border: 1px solid rgba(255,255,255,.15); padding: 4px; }
    .menu .head { padding: 6px 10px 4px; font-size: 11px; text-transform: uppercase; letter-spacing: .04em; color: rgba(255,255,255,.55); }
    .menu button { display: flex; justify-content: space-between; gap: 18px; border-radius: 5px; width: 100%; box-sizing: border-box; }
    .menu button:hover { background: #2563eb; }
    .menu .q { font-weight: 600; }
    .menu .d { color: rgba(255,255,255,.65); font-variant-numeric: tabular-nums; }
    .menu button:hover .d { color: #fff; }
    .menu button[disabled] { cursor: default; opacity: .5; }
    .menu button[disabled]:hover { background: none; }
    .toast { max-width: 300px; padding: 7px 10px; border-radius: 8px; background: rgba(17,24,39,.96);
      border: 1px solid rgba(255,255,255,.15); box-shadow: 0 2px 10px rgba(0,0,0,.35); }
    .toast.ok { border-color: #16a34a; } .toast.err { border-color: #dc2626; }
    .chip { padding: 1px 6px; border-radius: 4px; background: #2563eb; font-size: 11px; }
    [hidden] { display: none !important; }`;

  const ARROW = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M8 2v9M4 7.5 8 11.5l4-4M3 14h10"/></svg>';

  function build() {
    host = document.createElement('streamgrab-button');
    const shadow = host.attachShadow({ mode: 'open' });
    shadow.innerHTML = `<style>${CSS}</style>
      <div class="wrap">
        <div class="bar"><button class="main"></button><button class="close" title="Hide">✕</button></div>
        <div class="menu" hidden></div>
        <div class="toast" hidden></div>
      </div>`;
    ui = {
      wrap: shadow.querySelector('.wrap'), main: shadow.querySelector('.main'), close: shadow.querySelector('.close'),
      menu: shadow.querySelector('.menu'), toast: shadow.querySelector('.toast'),
    };
    // Keep the page from reacting to clicks on our button (e.g. pausing the video).
    for (const ev of ['click', 'mousedown', 'mouseup', 'pointerdown', 'pointerup', 'dblclick', 'touchstart']) {
      host.addEventListener(ev, (e) => e.stopPropagation());
    }
    ui.main.addEventListener('click', () => {
      const rows = menuRows();
      if (rows.length === 1 && !rows[0].disabled) return start(rows[0]);
      menuOpen = !menuOpen;
      render();
    });
    ui.close.addEventListener('click', () => { dismissedCount = items.length; menuOpen = false; render(); });
    document.addEventListener('click', () => { if (menuOpen) { menuOpen = false; render(); } });
    document.addEventListener('mousemove', (e) => {
      if (!target || !ui) return;
      const r = target.getBoundingClientRect();
      ui.wrap.classList.toggle('hot', e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom);
    }, { passive: true });
    addEventListener('scroll', position, { passive: true, capture: true });
    addEventListener('resize', position, { passive: true });
    document.addEventListener('fullscreenchange', position);
    setInterval(() => { if (items.length) { target = pickVideo() || target; position(); } }, 500);
  }

  function qualityLabel(item, q) {
    if (q.label) return q.label;
    const v = allVideos().find((v) => v.currentSrc === q.url) || (items.length === 1 ? target : null);
    return v?.videoHeight ? `${v.videoHeight}p` : 'Original quality';
  }

  function menuRows() {
    const rows = [];
    // Streams with several qualities first, then single files (largest first).
    const sorted = [...items].sort((a, b) => b.qualities.length - a.qualities.length);
    for (const item of sorted) {
      item.qualities.forEach((q, index) => rows.push({
        item, index, label: qualityLabel(item, q),
        detail: item.drm ? 'DRM-protected' : q.detail || '',
        disabled: !!item.drm,
      }));
    }
    return rows;
  }

  function render() {
    target = pickVideo();
    const visible = items.length > 0 && target && dismissedCount !== items.length;
    if (!visible) { if (host) host.remove(); menuOpen = false; return; }
    if (!host) build();

    const rows = menuRows();
    const single = rows.length === 1 ? rows[0] : null;
    ui.main.innerHTML = `${ARROW}<span>Download this video</span>` +
      (single ? `<span class="chip">${esc(single.label)}</span>` : '<span>▾</span>');
    ui.wrap.classList.toggle('open', menuOpen);
    ui.menu.hidden = !menuOpen;
    if (menuOpen) {
      ui.menu.innerHTML = '<div class="head">Choose quality</div>';
      for (const row of rows) {
        const b = document.createElement('button');
        b.innerHTML = `<span class="q">${esc(row.label)}</span><span class="d">${esc(row.detail)}</span>`;
        if (row.disabled) b.setAttribute('disabled', '');
        else b.addEventListener('click', () => start(row));
        ui.menu.append(b);
      }
    }
    position();
  }

  async function start(row) {
    menuOpen = false;
    render();
    toast('Sending to StreamGrab…');
    let res;
    try {
      res = await chrome.runtime.sendMessage({ type: 'download', itemId: row.item.id, quality: row.index, label: row.label });
    } catch {
      res = { ok: false, error: 'The extension was updated. Reload this page.' };
    }
    if (res?.ok) toast(`✓ Downloading ${row.label} in StreamGrab`, 'ok');
    else toast(`⚠ ${res?.error || 'Couldn’t reach StreamGrab.'}`, 'err', 7000);
  }

  let toastTimer;
  function toast(text, kind = '', ms = 4000) {
    if (!ui) return;
    ui.toast.textContent = text;
    ui.toast.className = `toast ${kind}`;
    ui.toast.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { ui.toast.hidden = true; }, ms);
    position();
  }

  function position() {
    if (!host || !target) return;
    // In fullscreen only the fullscreen element's subtree is drawn.
    const fs = document.fullscreenElement;
    const parent = fs && fs.tagName !== 'VIDEO' ? fs : document.documentElement;
    if (host.parentNode !== parent) parent.append(host);
    const r = target.getBoundingClientRect();
    const onScreen = bigEnough(r) && r.bottom > 30 && r.top < innerHeight - 30 && r.right > 0 && r.left < innerWidth;
    ui.wrap.hidden = !onScreen;
    if (!onScreen) return;
    const w = ui.wrap.offsetWidth;
    ui.wrap.style.left = `${Math.max(4, Math.min(r.right, innerWidth) - w - 10)}px`;
    ui.wrap.style.top = `${Math.max(4, r.top + 10)}px`;
  }

  function esc(s) {
    return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  }
})();
