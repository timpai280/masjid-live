// Broadcaster web page (for testing from a PC/phone browser; the Android app is better for real use)
const { Room, RoomEvent } = LivekitClient;
const $ = (id) => document.getElementById(id);

let room = null, creds = null, startedAt = 0, tick = null, poll = null, wakeLock = null, listeners = 0, paused = false;

const two = (n) => String(n).padStart(2, '0');
function updTimer() {
  const s = Math.floor((Date.now() - startedAt) / 1000);
  $('timer').textContent = `${two(Math.floor(s / 3600))}:${two(Math.floor(s / 60) % 60)}:${two(s % 60)}`;
}
function updUi() {
  $('count').textContent = `${listeners} ${t('listeners')}`;
  $('liveBadge').textContent = paused ? '⏸ ' + t('youArePaused') : t('youAreLive');
  $('liveBadge').className = 'badge ' + (paused ? 'paused' : 'live');
  $('pauseBtn').textContent = paused ? t('resume') : t('pause');
}
window.onLangChange = updUi;

async function pollCount() {
  try {
    const j = await api('/api/mosques/' + encodeURIComponent(creds.mosqueId));
    listeners = j.listeners;
    updUi();
  } catch (_) {}
}

async function goLive() {
  const mosqueId = $('mid').value.trim().toUpperCase();
  const pin = $('pin').value.trim();
  if (!mosqueId || !pin) return;
  $('goBtn').disabled = true;
  $('err').textContent = '';
  try {
    const { url, token, mosque } = await api('/api/broadcast/token', { mosqueId, pin });
    creds = { mosqueId, pin };
    localStorage.setItem('bMosqueId', mosqueId);
    const r = new Room({
      audioCaptureDefaults: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    });
    room = r;
    r.on(RoomEvent.Disconnected, () => {
      if (room === r) ended();
    });
    r.on(RoomEvent.Reconnecting, () => ($('status').textContent = t('reconnecting')));
    r.on(RoomEvent.Reconnected, () => ($('status').textContent = ''));
    await r.connect(url, token);
    try {
      await r.localParticipant.setMicrophoneEnabled(true);
    } catch (e) {
      throw new Error('mic');
    }
    await api('/api/broadcast/state', { ...creds, state: 'live' }).catch(() => {});
    paused = false;
    $('mname').textContent = mosque.name;
    $('login').classList.add('hidden');
    $('liveBox').classList.remove('hidden');
    startedAt = Date.now();
    updTimer();
    updUi();
    tick = setInterval(updTimer, 1000);
    poll = setInterval(pollCount, 10000);
    try { wakeLock = navigator.wakeLock ? await navigator.wakeLock.request('screen') : null; } catch (_) {}
  } catch (e) {
    const r = room;
    room = null;
    if (r) r.disconnect();
    $('err').textContent = errMsg(e);
  } finally {
    $('goBtn').disabled = false;
  }
}

async function togglePause() {
  if (!room) return;
  $('pauseBtn').disabled = true;
  try {
    const next = !paused;
    await room.localParticipant.setMicrophoneEnabled(!next);
    await api('/api/broadcast/state', { ...creds, state: next ? 'paused' : 'resumed' });
    paused = next;
    updUi();
  } catch (e) {
    $('status').textContent = errMsg(e);
  } finally {
    $('pauseBtn').disabled = false;
  }
}

function ended() {
  clearInterval(tick);
  clearInterval(poll);
  room = null;
  if (wakeLock) { wakeLock.release().catch(() => {}); wakeLock = null; }
  $('liveBox').classList.add('hidden');
  $('login').classList.remove('hidden');
  $('err').textContent = t('ended');
}

$('goBtn').onclick = goLive;
$('pauseBtn').onclick = togglePause;
$('endBtn').onclick = async () => {
  if (!confirm(t('endConfirm'))) return;
  await api('/api/broadcast/state', { ...creds, state: 'ended' }).catch(() => {});
  const r = room;
  room = null;
  if (r) await r.disconnect();
  ended();
};

applyI18n();
$('mid').value = localStorage.getItem('bMosqueId') || '';
