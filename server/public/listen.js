// Listener web page
const { Room, RoomEvent, Track } = LivekitClient;
const $ = (id) => document.getElementById(id);

let mosque = null;
let info = { status: 'offline', listeners: 0, schedule: '' };
let room = null;
let state = 'idle'; // idle | connecting | waiting | playing
let pollTimer = null;

const isOnAir = (s) => s === 'live' || s === 'paused';

function render() {
  if (!mosque) return;
  $('mname').textContent = `${mosque.name} (${mosque.id})`;
  const s = info.status;
  $('badge').textContent = s === 'live' ? '● ' + t('live') : s === 'paused' ? '⏸ ' + t('paused') : s === 'ended' ? t('endedShort') : t('offline');
  $('badge').className = 'badge' + (s === 'live' ? ' live' : s === 'paused' ? ' paused' : '');
  $('count').textContent = isOnAir(s) ? `${info.listeners} ${t('listeners')}` : '';
  $('scheduleBox').classList.toggle('hidden', !info.schedule);
  $('scheduleText').textContent = info.schedule || '';
  $('playBtn').textContent = state === 'idle' ? '▶' : '■';
  $('playBtn').className = 'btn big' + (state === 'idle' ? '' : ' red');
  $('stateText').textContent =
    state === 'idle' ? t('tapToListen') :
    state === 'connecting' ? t('connecting') :
    state === 'waiting' ? t('waiting') :
    s === 'paused' ? t('pausedListener') : t('playing');
}
window.onLangChange = () => {
  render();
  if (!$('pastBox').classList.contains('hidden')) loadRecordings();
};

function setState(s) {
  state = s;
  render();
}

// When the lecturer ends the lesson, everyone is disconnected and sees "ended"
function applyStatus(s) {
  if (!s) return;
  const prev = info.status;
  info.status = s;
  if (s === 'ended' && isOnAir(prev) && state !== 'idle') {
    stop(t('endedNote'));
    return;
  }
  render();
}

async function refresh() {
  if (!mosque) return;
  try {
    const j = await api('/api/mosques/' + encodeURIComponent(mosque.id));
    mosque.name = j.name;
    info.listeners = j.listeners;
    info.schedule = (j.schedule && j.schedule.text) || '';
    applyStatus(j.status || (j.live ? 'live' : 'offline'));
  } catch (_) {}
}

async function join(id) {
  $('joinErr').textContent = '';
  id = (id || '').trim().toUpperCase();
  if (!id) return;
  try {
    const j = await api('/api/mosques/' + encodeURIComponent(id));
    mosque = { id: j.id, name: j.name };
    info = { status: j.status || (j.live ? 'live' : 'offline'), listeners: j.listeners, schedule: (j.schedule && j.schedule.text) || '' };
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
  $('note').textContent = '';
  setState('connecting');
  try {
    const { url, token } = await api('/api/listen', { mosqueId: mosque.id });
    const r = new Room({ adaptiveStream: false, dynacast: false });
    room = r;
    r.on(RoomEvent.TrackSubscribed, (track) => {
      if (track.kind === Track.Kind.Audio) {
        $('audio').appendChild(track.attach());
        setState('playing');
        refresh();
      }
    });
    r.on(RoomEvent.TrackUnsubscribed, (track) => {
      track.detach().forEach((el) => el.remove());
      if (state !== 'idle') setState('waiting');
    });
    r.on(RoomEvent.RoomMetadataChanged, (md) => applyStatus(parseStatus(md)));
    r.on(RoomEvent.Disconnected, () => {
      if (room === r) stop();
    });
    await r.connect(url, token);
    await r.startAudio(); // allowed because the user tapped the button
    if (state === 'connecting') setState('waiting');
    const s = parseStatus(r.metadata);
    if (s) {
      info.status = s;
      render();
    }
  } catch (e) {
    await stop();
    $('playErr').textContent = errMsg(e);
  }
}

async function stop(note) {
  const r = room;
  room = null;
  $('audio').innerHTML = '';
  setState('idle');
  if (note) $('note').textContent = note;
  if (r) await r.disconnect();
}

// ---- questions
$('askBtn').onclick = () => {
  $('qErr').textContent = '';
  $('qName').value = localStorage.getItem('qName') || '';
  $('askBox').classList.remove('hidden');
  $('pastBox').classList.add('hidden');
  $('qText').focus();
};
$('qCancel').onclick = () => $('askBox').classList.add('hidden');
$('qSend').onclick = async () => {
  const text = $('qText').value.trim();
  if (text.length < 2) {
    $('qErr').textContent = t('err_empty');
    return;
  }
  $('qSend').disabled = true;
  try {
    await api('/api/questions', { mosqueId: mosque.id, name: $('qName').value.trim(), text });
    localStorage.setItem('qName', $('qName').value.trim());
    $('qText').value = '';
    $('askBox').classList.add('hidden');
    $('note').textContent = t('questionSent');
  } catch (e) {
    $('qErr').textContent = errMsg(e);
  } finally {
    $('qSend').disabled = false;
  }
};

// ---- past sessions
async function loadRecordings() {
  const list = $('recList');
  list.innerHTML = '';
  try {
    const j = await api('/api/mosques/' + encodeURIComponent(mosque.id) + '/recordings');
    $('keptFor').textContent = t('keptFor').replace('{n}', j.keepDays || 14);
    $('processing').textContent = j.processing ? t('processing') : '';
    if (!j.recordings.length) {
      list.innerHTML = `<p class="muted">${esc(t('noRecordings'))}</p>`;
      return;
    }
    list.innerHTML = j.recordings
      .map((r) => `<div class="rec"><div><b>${esc(fmtWhen(r.startedAt))}</b> · ${Math.round((r.durationSec || 0) / 60)} ${esc(t('min'))}</div>
        <audio controls preload="none" src="${esc(r.url)}"></audio></div>`)
      .join('');
  } catch (e) {
    list.innerHTML = `<p class="err">${esc(errMsg(e))}</p>`;
  }
}
$('pastBtn').onclick = async () => {
  const box = $('pastBox');
  if (!box.classList.contains('hidden')) {
    box.classList.add('hidden');
    return;
  }
  if (state !== 'idle') await stop();
  $('askBox').classList.add('hidden');
  box.classList.remove('hidden');
  loadRecordings();
};

$('joinBtn').onclick = () => join($('mid').value);
$('mid').addEventListener('keydown', (e) => { if (e.key === 'Enter') join($('mid').value); });
$('playBtn').onclick = () => (state === 'idle' ? start() : stop());
$('changeBtn').onclick = async () => {
  await stop();
  clearInterval(pollTimer);
  mosque = null;
  localStorage.removeItem('mosqueId');
  ['player', 'askBox', 'pastBox'].forEach((id) => $(id).classList.add('hidden'));
  $('join').classList.remove('hidden');
};

applyI18n();
const fromLink = new URLSearchParams(location.search).get('m');
const saved = fromLink || localStorage.getItem('mosqueId');
if (saved) {
  $('mid').value = saved;
  join(saved);
}
