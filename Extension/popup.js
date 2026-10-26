const $ = (s) => document.querySelector(s);

(async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });

  // Whether the app is open: checked now, every 2 s while the popup is open, and right after
  // "Open StreamGrab" (which starts the app if needed).
  const refreshStatus = () => chrome.runtime.sendMessage({ type: 'ping' }).then((res) => {
    const running = res?.ok && res.appRunning;
    $('#status').textContent = !res?.ok ? 'App not installed' : running ? `App running${res.ffmpeg ? '' : ' (no ffmpeg)'}` : 'App not running';
    $('#status').className = running ? 'ok' : 'bad';
  });
  refreshStatus();
  setInterval(refreshStatus, 2000);
  $('#open').onclick = async () => {
    $('#status').textContent = 'Opening…';
    $('#status').className = '';
    await chrome.runtime.sendMessage({ type: 'show' });
    refreshStatus();
  };

  const { items = [] } = (await chrome.runtime.sendMessage({ type: 'items', tabId: tab.id })) || {};
  const list = $('#list');
  if (!items.length) {
    list.innerHTML = '<div class="empty">No videos found on this page yet.<br>Start playing one.</div>';
    return;
  }
  for (const item of [...items].reverse()) {
    const group = document.createElement('div');
    group.className = 'group';
    group.textContent = `${item.kind === 'direct' ? 'File' : 'Stream'} · ${new URL(item.url).hostname}`;
    list.append(group);
    item.qualities.forEach((q, index) => {
      const b = document.createElement('button');
      b.className = 'row';
      const label = q.label || 'Original quality';
      b.innerHTML = '<span class="q"></span><span class="d"></span>';
      b.querySelector('.q').textContent = label;
      b.querySelector('.d').textContent = item.drm ? 'DRM-protected' : q.detail || '';
      b.disabled = !!item.drm;
      b.onclick = async () => {
        $('#msg').textContent = 'Sending…';
        const res = await chrome.runtime.sendMessage({ type: 'download', tabId: tab.id, itemId: item.id, quality: index, label: q.label });
        $('#msg').textContent = res?.ok ? `✓ Downloading ${label}${res.warning ? ` (${res.warning})` : ''}` : `⚠ ${res?.error || 'Failed'}`;
      };
      list.append(b);
    });
  }
})();
