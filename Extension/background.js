// StreamGrab: watches network traffic for video streams (HLS playlists and video files),
// asks the StreamGrab app for the available qualities, and tells the page's content
// script so it can show the "Download this video" button.

const HOST = 'com.streamgrab.host';
const MIN_DIRECT_SIZE = 1 << 20; // ignore tiny clips (previews, ads)
const KEEP_HEADER = /^(user-agent|referer|origin|cookie|authorization|accept|accept-language|x-[\w-]+)$/i;

/** tabId -> { items: Item[], videoFrames: number[] } */
let tabs = {};
const requestHeaders = new Map(); // requestId -> headers (short-lived)
const probes = new Map();         // playlist URL -> Promise of the app's probe result
const seen = new Set();           // "tabId url" pairs already handled since the tab's last navigation
const childUrls = new Set();      // variant playlists of a known master: not shown on their own

const ready = chrome.storage.session.get('tabs').then((s) => { tabs = s.tabs || {}; });
let saveTimer;
function save() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => chrome.storage.session.set({ tabs }), 300);
}

function tabState(tabId) {
  return (tabs[tabId] ||= { items: [], videoFrames: [] });
}

// ---------- Native app ----------

function native(message) {
  return chrome.runtime.sendNativeMessage(HOST, message).catch((e) => ({
    ok: false,
    noApp: /not found|forbidden|exited/i.test(e.message || ''),
    error: e.message || String(e),
  }));
}

// ---------- Network sniffing ----------

const FILTER = { urls: ['<all_urls>'], types: ['media', 'xmlhttprequest', 'other', 'object'] };

chrome.webRequest.onSendHeaders.addListener((d) => {
  if (d.tabId < 0) return;
  const h = {};
  for (const { name, value } of d.requestHeaders || []) if (KEEP_HEADER.test(name) && value) h[name] = value;
  requestHeaders.set(d.requestId, h);
  if (requestHeaders.size > 500) requestHeaders.delete(requestHeaders.keys().next().value);
}, FILTER, ['requestHeaders', 'extraHeaders']);

chrome.webRequest.onErrorOccurred.addListener((d) => requestHeaders.delete(d.requestId), FILTER);

chrome.webRequest.onHeadersReceived.addListener((d) => {
  const headers = requestHeaders.get(d.requestId) || {};
  requestHeaders.delete(d.requestId);
  if (d.tabId < 0 || d.statusCode >= 400 || d.statusCode < 200) return;
  const get = (n) => (d.responseHeaders || []).find((h) => h.name.toLowerCase() === n)?.value || '';
  const kind = classify(d.url, get('content-type'));
  if (!kind) return;
  ready.then(() => {
    if (kind === 'hls') onPlaylist(d, headers);
    else onDirect(d, headers, get('content-range'), get('content-length'), get('content-type'));
  });
}, FILTER, ['responseHeaders']);

function classify(url, contentType) {
  let u;
  try { u = new URL(url); } catch { return null; }
  if (!/^https?:$/.test(u.protocol)) return null;
  if (/(^|\.)googlevideo\.com$/.test(u.hostname)) return null; // YouTube's chunked streams
  const path = u.pathname.toLowerCase();
  const ct = contentType.toLowerCase().split(';')[0].trim();
  if (ct.includes('mpegurl') || path.endsWith('.m3u8')) return 'hls';
  if (/\.(ts|m4s|aac|m4a|mp3|vtt|webvtt|key|cmfv|cmfa)$/.test(path)) return null;
  if (ct === 'video/mp2t' || ct === 'video/iso.segment') return null;
  if (ct.startsWith('video/') || /\.(mp4|webm|mov|m4v|mkv|flv)$/.test(path)) return 'direct';
  return null;
}

async function onPlaylist(d, headers) {
  const url = d.url;
  const key = `${d.tabId} ${url}`;
  if (childUrls.has(url) || seen.has(key)) return;
  seen.add(key);
  if (!probes.has(url)) {
    probes.set(url, native({ type: 'probe', url, headers }));
    if (probes.size > 200) probes.delete(probes.keys().next().value);
  }
  const res = await probes.get(url);
  if (!res.ok) probes.delete(url);
  if (!res.ok && !res.noApp) { seen.delete(key); return; } // not a playlist / fetch failed
  if (res.ok && res.live) return; // live streams aren't supported
  if (childUrls.has(url) || tabState(d.tabId).items.some((i) => i.url === url)) return;

  const item = { id: crypto.randomUUID(), kind: 'hls', url, frameId: d.frameId, headers, added: Date.now() };
  if (!res.ok) {
    // Without the app we can't read the playlist; offer one entry that explains what's missing.
    if (tabState(d.tabId).items.some((i) => i.noApp)) return;
    item.noApp = true;
    item.qualities = [{ label: 'Video stream', detail: 'needs the StreamGrab app', url }];
  } else if (res.kind === 'master') {
    for (const v of res.variants) { childUrls.add(v.url); if (v.audioUrl) childUrls.add(v.audioUrl); }
    const s = tabState(d.tabId);
    s.items = s.items.filter((i) => !childUrls.has(i.url)); // drop variants we already listed alone
    item.drm = !!res.drm;
    item.qualities = res.variants.map((v) => ({
      label: v.height ? `${v.height}p${v.frameRate > 31 ? Math.round(v.frameRate) : ''}` : `${Math.round(v.bandwidth / 1000)} kbps`,
      detail: res.duration ? `~${formatSize((v.bandwidth * res.duration) / 8)}` : '',
      url: v.url,
      audioUrl: v.audioUrl,
      height: v.height,
    }));
  } else {
    item.drm = !!res.drm;
    item.qualities = [{ label: '', detail: res.duration ? formatDuration(res.duration) : '', url }];
  }
  addItem(d.tabId, item);
}

function onDirect(d, headers, contentRange, contentLength, contentType) {
  const total = Number((contentRange.split('/')[1]) || contentLength || 0);
  if (total && total < MIN_DIRECT_SIZE) return;
  const s = tabState(d.tabId);
  if (s.items.some((i) => i.url === d.url)) return;
  const hint = d.url.match(/[^\d](\d{3,4})p[^\w]/i);
  addItem(d.tabId, {
    id: crypto.randomUUID(), kind: 'direct', url: d.url, frameId: d.frameId, headers, added: Date.now(),
    qualities: [{
      label: hint ? `${hint[1]}p` : '',
      detail: [total ? formatSize(total) : '', (contentType.split('/')[1] || '').split(';')[0].toUpperCase()].filter(Boolean).join(' · '),
      url: d.url,
    }],
  });
}

function addItem(tabId, item) {
  const s = tabState(tabId);
  s.items.push(item);
  if (s.items.length > 30) s.items.shift();
  save();
  refresh(tabId);
}

function refresh(tabId) {
  const n = tabs[tabId]?.items.length || 0;
  chrome.action.setBadgeText({ tabId, text: n ? String(n) : '' }).catch(() => {});
  chrome.action.setBadgeBackgroundColor({ tabId, color: '#2563eb' }).catch(() => {});
  chrome.tabs.sendMessage(tabId, { type: 'refresh' }).catch(() => {});
}

// ---------- Page lifecycle ----------

chrome.webNavigation.onCommitted.addListener(async (d) => {
  if (d.frameId !== 0) return;
  await ready;
  for (const k of seen) if (k.startsWith(`${d.tabId} `)) seen.delete(k);
  delete tabs[d.tabId];
  save();
  refresh(d.tabId);
});
chrome.tabs.onRemoved.addListener(async (tabId) => { await ready; delete tabs[tabId]; save(); });

// ---------- Messages from content scripts and the popup ----------

/** Items a given frame should offer: its own, or (if the frames that loaded media have no video) all. */
function itemsForFrame(tabId, frameId) {
  const s = tabs[tabId];
  if (!s) return [];
  const own = s.items.filter((i) => i.frameId === frameId);
  if (own.length) return own;
  const videoFramesWithItems = s.items.some((i) => s.videoFrames.includes(i.frameId));
  return videoFramesWithItems ? [] : s.items;
}

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  (async () => {
    await ready;
    const tabId = msg.tabId ?? sender.tab?.id;
    switch (msg.type) {
      case 'items': {
        if (sender.tab && msg.hasVideo) {
          const s = tabState(tabId);
          if (!s.videoFrames.includes(sender.frameId)) { s.videoFrames.push(sender.frameId); save(); }
        }
        const items = sender.tab ? itemsForFrame(tabId, sender.frameId) : tabs[tabId]?.items || [];
        return reply({ items: items.map(publicItem) });
      }
      case 'download': return reply(await download(tabId, msg.itemId, msg.quality, msg.label));
      case 'ping': return reply(await native({ type: 'ping' }));
      case 'show': return reply(await native({ type: 'show' }));
    }
  })();
  return true;
});

/** What pages get to see: no cookies or other request headers. */
function publicItem(i) {
  return { id: i.id, kind: i.kind, url: i.url, drm: i.drm, noApp: i.noApp, qualities: i.qualities };
}

async function download(tabId, itemId, index, label) {
  const item = tabs[tabId]?.items.find((i) => i.id === itemId);
  const q = item?.qualities[index];
  if (!q) return { ok: false, error: 'This video is no longer available. Reload the page.' };
  if (item.drm) return { ok: false, error: 'This video is DRM-protected and can’t be downloaded.' };
  const tab = await chrome.tabs.get(tabId).catch(() => null);
  const job = {
    kind: item.kind,
    url: q.url,
    audioURL: q.audioUrl || null,
    title: cleanTitle(tab?.title) || new URL(q.url).hostname,
    quality: label || q.label || null,
    pageURL: tab?.url || null,
    headers: item.headers || {},
  };
  const res = await native({ type: 'download', job });
  if (res.noApp) res.error = 'The StreamGrab app isn’t installed (or hasn’t been opened once yet).';
  return res;
}

function cleanTitle(t) {
  return (t || '').replace(/^\(\d+\)\s*/, '').trim();
}

function formatSize(bytes) {
  if (!bytes) return '';
  const units = ['B', 'KB', 'MB', 'GB'];
  let i = 0;
  while (bytes >= 1000 && i < units.length - 1) { bytes /= 1000; i++; }
  return `${bytes >= 100 || i === 0 ? Math.round(bytes) : bytes.toFixed(1)} ${units[i]}`;
}

function formatDuration(sec) {
  sec = Math.round(sec);
  const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
  return h ? `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}` : `${m}:${String(s).padStart(2, '0')}`;
}
