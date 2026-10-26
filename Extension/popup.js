const $ = (s) => document.querySelector(s);

(async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });

  chrome.runtime.sendMessage({ type: 'ping' }).then((res) => {
    $('#status').textContent = res?.ok ? `App connected${res.ffmpeg ? '' : ' (no ffmpeg)'}` : 'App not found';
    $('#status').className = res?.ok ? 'ok' : 'bad';
  });
  $('#open').onclick = () => chrome.runtime.sendMessage({ type: 'show' });

  const { items = [] } = (await chrome.runtime.sendMessage({ type: 'items', tabId: tab.id })) || {};
  const list = $('#list');
  if (!items.length) {
    list.innerHTML = '<div class="empty">No videos found on this page yet.<br>Start playing one.</div>';
    return;
  }
  for (const item of [...items].reverse()) {
    const group = document.createElement('div');
    group.className = 'group';
    group.textContent = `${item.kind === 'hls' ? 'Stream' : 'File'} · ${new URL(item.url).hostname}`;
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
        $('#msg').textContent = res?.ok ? `✓ Downloading ${label}` : `⚠ ${res?.error || 'Failed'}`;
      };
      list.append(b);
    });
  }
})();
