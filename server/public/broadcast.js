// Broadcaster web page (for testing from a PC/phone browser; the Android app is better for real use)
const { Room, RoomEvent } = LivekitClient;
const $ = (id) => document.getElementById(id);

let room = null, creds = null, startedAt = 0, tick = null, poll = null, wakeLock = null, listeners = 0;

const two = (n) => String(n).padStart(2, '0');
function updTimer() {
  const s = Math.floor((Date.now() - startedAt) / 1000);
  $('timer').textContent = `${two(Math.floor(s / 3600))}:${two(Math.floor(s / 60) % 60)}:${two(s % 60)}`;
}
function updCount() {
  $('count').textContent = `${listeners} ${t('listeners')}`;
}
window.onLangChange = updCount;

async function pollCount() {
  try {
    const j = await api('/api/mosques/' + encodeURIComponent(creds.mosqueId));
    listeners = j.listeners;
    updCount();
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
    room = new Room({
      audioCaptureDefaults: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    });
    room.on(RoomEvent.Disconnected, ended);
    room.on(RoomEvent.Reconnecting, () => ($('status').textContent = t('reconnecting')));
    room.on(RoomEvent.Reconnected, () => ($('status').textContent = ''));
    await room.connect(url, token);
    try {
      await room.localParticipant.setMicrophoneEnabled(true);
    } catch (e) {
      throw new Error('mic');
    }
    api('/api/broadcast/live', creds).catch(() => {});
    $('mname').textContent = mosque.name;
    $('login').classList.add('hidden');
    $('liveBox').classList.remove('hidden');
    startedAt = Date.now();
    updTimer();
    updCount();
    tick = setInterval(updTimer, 1000);
    poll = setInterval(pollCount, 10000);
    try { wakeLock = navigator.wakeLock ? await navigator.wakeLock.request('screen') : null; } catch (_) {}
  } catch (e) {
    if (room) room.disconnect();
    room = null;
    $('err').textContent = errMsg(e);
  } finally {
    $('goBtn').disabled = false;
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
$('endBtn').onclick = async () => {
  if (!confirm(t('endConfirm'))) return;
  if (room) await room.disconnect();
  else ended();
};

applyI18n();
$('mid').value = localStorage.getItem('bMosqueId') || '';
