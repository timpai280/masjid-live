// Listener web page
const { Room, RoomEvent, Track } = LivekitClient;
const $ = (id) => document.getElementById(id);

let mosque = null;
let info = { live: false, listeners: 0 };
let room = null;
let state = 'idle'; // idle | connecting | waiting | playing
let pollTimer = null;

function render() {
  if (!mosque) return;
  $('mname').textContent = `${mosque.name} (${mosque.id})`;
  $('badge').textContent = info.live ? '● ' + t('live') : t('offline');
  $('badge').className = 'badge' + (info.live ? ' live' : '');
  $('count').textContent = info.live ? `${info.listeners} ${t('listeners')}` : '';
  $('playBtn').textContent = state === 'idle' ? '▶' : '■';
  $('playBtn').className = 'btn big' + (state === 'idle' ? '' : ' red');
  $('stateText').textContent =
    state === 'idle' ? t('tapToListen') :
    state === 'connecting' ? t('connecting') :
    state === 'waiting' ? t('waiting') : t('playing');
}
window.onLangChange = render;

function setState(s) {
  state = s;
  render();
}

async function refresh() {
  if (!mosque) return;
  try {
    const j = await api('/api/mosques/' + encodeURIComponent(mosque.id));
    info = { live: j.live, listeners: j.listeners };
    mosque.name = j.name;
    render();
  } catch (_) {}
}

async function join(id) {
  $('joinErr').textContent = '';
  id = (id || '').trim().toUpperCase();
  if (!id) return;
  try {
    const j = await api('/api/mosques/' + encodeURIComponent(id));
    mosque = { id: j.id, name: j.name };
    info = { live: j.live, listeners: j.listeners };
    localStorage.setItem('mosqueId', j.id);
    $('join').classList.add('hidden');
    $('player').classList.remove('hidden');
    render();
    clearInterval(pollTimer);
    pollTimer = setInterval(refresh, 10000);
  } catch (e) {
    $('joinErr').textContent = errMsg(e);
  }
}

async function start() {
  $('playErr').textContent = '';
  setState('connecting');
  try {
    const { url, token } = await api('/api/listen', { mosqueId: mosque.id });
    room = new Room({ adaptiveStream: false, dynacast: false });
    room.on(RoomEvent.TrackSubscribed, (track) => {
      if (track.kind === Track.Kind.Audio) {
        $('audio').appendChild(track.attach());
        setState('playing');
        refresh();
      }
    });
    room.on(RoomEvent.TrackUnsubscribed, (track) => {
      track.detach().forEach((el) => el.remove());
      setState('waiting');
      refresh();
    });
    room.on(RoomEvent.Disconnected, () => {
      room = null;
      $('audio').innerHTML = '';
      setState('idle');
    });
    await room.connect(url, token);
    await room.startAudio(); // allowed because the user tapped the button
    if (state === 'connecting') setState('waiting');
  } catch (e) {
    if (room) room.disconnect();
    room = null;
    setState('idle');
    $('playErr').textContent = errMsg(e);
  }
}

async function stop() {
  if (room) await room.disconnect();
  room = null;
  setState('idle');
}

$('joinBtn').onclick = () => join($('mid').value);
$('mid').addEventListener('keydown', (e) => { if (e.key === 'Enter') join($('mid').value); });
$('playBtn').onclick = () => (state === 'idle' ? start() : stop());
$('changeBtn').onclick = async () => {
  await stop();
  clearInterval(pollTimer);
  mosque = null;
  localStorage.removeItem('mosqueId');
  $('player').classList.add('hidden');
  $('join').classList.remove('hidden');
};

applyI18n();
const fromLink = new URLSearchParams(location.search).get('m');
const saved = fromLink || localStorage.getItem('mosqueId');
if (saved) {
  $('mid').value = saved;
  join(saved);
}
