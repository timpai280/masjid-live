'use strict';
/**
 * Masjid Live - API server
 *
 *  - Mosques (ID, name, broadcaster PIN), created by the setup script or the admin page
 *  - LiveKit tokens: listeners may only LISTEN, the broadcaster (PIN) may SPEAK
 *  - Session state per mosque: offline | live | paused | ended  (shown to every listener)
 *  - Schedule text set by the lecturer (shown on screen + notification)
 *  - Questions from listeners (name optional), read by the lecturer with the PIN
 *  - Recordings of each session (kept RECORDING_DAYS days, default 14)
 *  - Push notifications through Firebase (optional)
 *
 * The live audio itself flows through LiveKit, not through this program.
 */
const express = require('express');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawn, execFile } = require('child_process');
const { AccessToken, RoomServiceClient } = require('livekit-server-sdk');

// ---------------------------------------------------------------- config
const PORT = parseInt(process.env.PORT || '3000', 10);
const HOST = process.env.HOST || '127.0.0.1';
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
const LK_KEY = process.env.LIVEKIT_API_KEY;
const LK_SECRET = process.env.LIVEKIT_API_SECRET;
const LK_INTERNAL_URL = process.env.LIVEKIT_INTERNAL_URL || 'http://127.0.0.1:7880';
const LK_PUBLIC_URL =
  process.env.LIVEKIT_PUBLIC_URL || (process.env.DOMAIN ? `wss://${process.env.DOMAIN}` : 'ws://localhost:7880');
const ADMIN_KEY = process.env.ADMIN_KEY || '';
const RECORDINGS_ON = (process.env.RECORDINGS || 'on') !== 'off';
const RECORDING_DAYS = parseInt(process.env.RECORDING_DAYS || '14', 10);
const QUESTION_DAYS = parseInt(process.env.QUESTION_DAYS || '30', 10);
const MAX_RECORDING_MS = 4 * 60 * 60 * 1000; // safety cap: 4 hours per recording
const NOTIFY_COOLDOWN_MS = 15 * 60 * 1000; // max one "LIVE" notification per mosque per 15 min
const SCHEDULE_COOLDOWN_MS = 2 * 60 * 1000;
const ENDED_VISIBLE_MS = 3 * 60 * 60 * 1000; // show "ended" for 3 hours, then "not live"
const REC_DIR = path.join(DATA_DIR, 'recordings');
const REC_TMP = path.join(DATA_DIR, 'rec-tmp');

if (!LK_KEY || !LK_SECRET) {
  console.error('LIVEKIT_API_KEY and LIVEKIT_API_SECRET must be set');
  process.exit(1);
}

// ---------------------------------------------------------------- storage (simple JSON file)
fs.mkdirSync(DATA_DIR, { recursive: true });
fs.mkdirSync(REC_DIR, { recursive: true });
fs.mkdirSync(REC_TMP, { recursive: true });
const DB_FILE = path.join(DATA_DIR, 'mosques.json');
let db = { mosques: {} };
try {
  db = JSON.parse(fs.readFileSync(DB_FILE, 'utf8'));
  if (!db.mosques) db.mosques = {};
} catch (_) {
  /* first run */
}
function save() {
  const tmp = DB_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(db, null, 2));
  fs.renameSync(tmp, DB_FILE);
}
function migrate(m) {
  m.state = m.state || { status: 'offline' };
  m.schedule = m.schedule || { text: '', updatedAt: null };
  m.questions = m.questions || [];
  m.recordings = m.recordings || [];
}
Object.values(db.mosques).forEach(migrate);

// ---------------------------------------------------------------- helpers
const normId = (id) => String(id || '').trim().toUpperCase().replace(/[^A-Z0-9]/g, '');
const hashPin = (pin, salt) => crypto.scryptSync(String(pin), salt, 32).toString('hex');
const publicMosque = (m) => ({ id: m.id, name: m.name });
const nowIso = () => new Date().toISOString();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function checkPin(m, pin) {
  if (!pin) return false;
  const a = Buffer.from(hashPin(String(pin).trim(), m.salt), 'hex');
  const b = Buffer.from(m.pinHash, 'hex');
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function newId() {
  let id;
  do id = 'MSJ' + crypto.randomInt(1000, 10000);
  while (db.mosques[id]);
  return id;
}

function validatePin(pin) {
  pin = String(pin || '').trim();
  if (!/^\d{4,8}$/.test(pin)) throw new Error('PIN must be 4-8 digits');
  return pin;
}

function createMosque({ id, name, pin, schedule }) {
  name = String(name || '').trim().slice(0, 80);
  if (!name) throw new Error('Name is required');
  pin = validatePin(pin);
  id = id ? normId(id) : newId();
  if (id.length < 3 || id.length > 12) throw new Error('ID must be 3-12 letters/numbers');
  if (db.mosques[id]) throw new Error('This ID already exists');
  const salt = crypto.randomBytes(16).toString('hex');
  const m = { id, name, salt, pinHash: hashPin(pin, salt), createdAt: nowIso() };
  migrate(m);
  if (schedule) m.schedule = { text: String(schedule).trim().slice(0, 300), updatedAt: nowIso() };
  db.mosques[id] = m;
  save();
  return m;
}

// First boot: create the mosque given in the environment (set by the Oracle setup script)
if (Object.keys(db.mosques).length === 0 && process.env.SEED_MOSQUE_PIN) {
  try {
    const m = createMosque({
      id: process.env.SEED_MOSQUE_ID,
      name: process.env.SEED_MOSQUE_NAME || 'Test Masjid',
      pin: process.env.SEED_MOSQUE_PIN,
      schedule: process.env.SEED_SCHEDULE || '',
    });
    console.log(`Created mosque "${m.name}" with ID ${m.id}`);
  } catch (e) {
    console.error('Could not create seed mosque:', e.message);
  }
}

// ---------------------------------------------------------------- PIN brute-force protection
const failures = new Map();
const isLocked = (k) => (failures.get(k)?.until || 0) > Date.now();
function recordFailure(k) {
  const f = failures.get(k) || { count: 0, until: 0 };
  f.count += 1;
  if (f.count >= 5) {
    f.until = Date.now() + 10 * 60 * 1000;
    f.count = 0;
  }
  failures.set(k, f);
}

function verifyBroadcaster(req, res) {
  const id = normId(req.body && req.body.mosqueId);
  const m = db.mosques[id];
  if (!m) {
    res.status(404).json({ code: 'not_found' });
    return null;
  }
  const key = `${req.ip}|${id}`;
  if (isLocked(key)) {
    res.status(429).json({ code: 'locked' });
    return null;
  }
  if (!checkPin(m, req.body.pin)) {
    recordFailure(key);
    res.status(401).json({ code: 'wrong_pin' });
    return null;
  }
  failures.delete(key);
  return m;
}

// ---------------------------------------------------------------- LiveKit
const roomSvc = new RoomServiceClient(LK_INTERNAL_URL, LK_KEY, LK_SECRET);

async function makeToken({ identity, name, room, publish, hidden = false }) {
  const at = new AccessToken(LK_KEY, LK_SECRET, { identity, name, ttl: '8h' });
  at.addGrant({
    roomJoin: true,
    room,
    canPublish: publish, // only the broadcaster can send audio
    canSubscribe: !publish, // listeners (and the recorder) receive audio
    canPublishData: false,
    hidden,
  });
  return at.toJwt();
}

const partsCache = new Map();
async function participants(id, fresh = false) {
  const c = partsCache.get(id);
  if (!fresh && c && Date.now() - c.at < 3000) return c.v;
  let v = [];
  try {
    v = await roomSvc.listParticipants(id);
  } catch (_) {
    /* room does not exist = nobody there */
  }
  partsCache.set(id, { at: Date.now(), v });
  return v;
}

function statusOf(m) {
  const s = m.state || {};
  if (s.status === 'live' || s.status === 'paused') return s.status;
  if (s.status === 'ended' && s.endedAt && Date.now() - Date.parse(s.endedAt) < ENDED_VISIBLE_MS) return 'ended';
  return 'offline';
}
const isOn = (m) => m.state.status === 'live' || m.state.status === 'paused';

function roomMetadata(m) {
  return JSON.stringify({ status: statusOf(m), sessionId: m.state.sessionId || null, schedule: m.schedule.text || '' });
}
// Pushes the status to everyone in the room instantly (listeners react to it)
async function pushMeta(m) {
  try {
    await roomSvc.updateRoomMetadata(m.id, roomMetadata(m));
  } catch (_) {
    /* room not created yet - listeners will read the status from the API */
  }
}

async function mosqueInfo(m) {
  const parts = await participants(m.id);
  const status = statusOf(m);
  return {
    ...publicMosque(m),
    status,
    live: status === 'live' || status === 'paused',
    listeners: parts.filter((p) => String(p.identity).startsWith('l-')).length,
    schedule: m.schedule,
    session: status === 'offline' ? null : { id: m.state.sessionId, startedAt: m.state.startedAt, endedAt: m.state.endedAt || null },
  };
}

// ---------------------------------------------------------------- push notifications (optional)
let messaging = null;
if (process.env.FIREBASE_SERVICE_ACCOUNT_B64) {
  try {
    const admin = require('firebase-admin');
    const sa = JSON.parse(Buffer.from(process.env.FIREBASE_SERVICE_ACCOUNT_B64, 'base64').toString('utf8'));
    admin.initializeApp({ credential: admin.credential.cert(sa) });
    messaging = admin.messaging();
    console.log('Push notifications: enabled');
  } catch (e) {
    console.error('Push notifications: Firebase init failed -', e.message);
  }
} else {
  console.log('Push notifications: disabled (FIREBASE_SERVICE_ACCOUNT_B64 not set)');
}

async function sendPush(m, { title, body, type, tag }) {
  if (!messaging) return 'disabled';
  await messaging.send({
    topic: `mosque_${m.id}`,
    notification: { title, body },
    data: { mosqueId: m.id, type },
    android: { priority: 'high', notification: { tag, channelId: 'live' } },
  });
  return 'sent';
}

async function notifyLive(m) {
  const now = Date.now();
  if (m.lastNotified && now - m.lastNotified < NOTIFY_COOLDOWN_MS) return 'cooldown';
  m.lastNotified = now;
  save();
  return sendPush(m, {
    title: `🔴 ${m.name} - LIVE`,
    body: 'The lesson has started. Tap to listen.\nدرس شروع ہو گیا ہے۔ سننے کے لیے دبائیں۔',
    type: 'live',
    tag: `live_${m.id}`,
  });
}

async function notifySchedule(m) {
  const now = Date.now();
  if (m.lastScheduleNotified && now - m.lastScheduleNotified < SCHEDULE_COOLDOWN_MS) return 'cooldown';
  m.lastScheduleNotified = now;
  save();
  return sendPush(m, {
    title: `📅 ${m.name} - Schedule / شیڈول`,
    body: m.schedule.text,
    type: 'schedule',
    tag: `schedule_${m.id}`,
  });
}

// ---------------------------------------------------------------- sessions
async function startSession(m) {
  if (isOn(m)) {
    // Broadcaster reconnected or pressed Go Live again: same session continues
    if (m.state.status === 'paused') {
      m.state.status = 'live';
      save();
    }
    await pushMeta(m);
    if (RECORDINGS_ON && !recorders.has(m.id)) startRecording(m);
    return { isNew: false, push: 'skipped' };
  }
  m.state = { status: 'live', sessionId: crypto.randomBytes(4).toString('hex'), startedAt: nowIso(), endedAt: null };
  save();
  partsCache.delete(m.id);
  await pushMeta(m);
  if (RECORDINGS_ON) startRecording(m);
  const push = await notifyLive(m).catch((e) => {
    console.error('Push failed:', e.message);
    return 'failed';
  });
  console.log(`[${m.id}] session ${m.state.sessionId} started`);
  return { isNew: true, push };
}

async function setPaused(m, paused) {
  if (!isOn(m)) return false;
  m.state.status = paused ? 'paused' : 'live';
  save();
  await pushMeta(m);
  console.log(`[${m.id}] ${paused ? 'paused' : 'resumed'}`);
  return true;
}

async function endSession(m, reason) {
  if (!isOn(m)) return false;
  m.state.status = 'ended';
  m.state.endedAt = nowIso();
  save();
  await pushMeta(m);
  console.log(`[${m.id}] session ${m.state.sessionId} ended (${reason})`);
  stopRecording(m.id);
  return true;
}

// If the lecturer's phone disappears (battery died, app swiped away) end the session after ~2 minutes
const misses = new Map();
setInterval(async () => {
  for (const m of Object.values(db.mosques)) {
    if (!isOn(m)) {
      misses.delete(m.id);
      continue;
    }
    const parts = await participants(m.id, true);
    if (parts.some((p) => p.identity === 'broadcaster')) {
      misses.delete(m.id);
      continue;
    }
    const n = (misses.get(m.id) || 0) + 1;
    misses.set(m.id, n);
    if (n >= 4) {
      misses.delete(m.id);
      await endSession(m, 'lecturer disconnected');
    }
  }
}, 30 * 1000);

// ---------------------------------------------------------------- recordings
// A hidden "recorder" joins the room, takes the lecturer's audio and saves it with ffmpeg.
// Recording: Opus/Ogg while live -> converted to M4A (plays on Android, iPhone and browsers) when it ends.
const recorders = new Map();
let rtcLib = null;
async function loadRtc() {
  if (!rtcLib) rtcLib = await import('@livekit/rtc-node');
  return rtcLib;
}
const stamp = (d) => d.toISOString().slice(0, 19).replace(/[-:]/g, '').replace('T', '_');

async function startRecording(m) {
  if (recorders.has(m.id)) return;
  const startedAt = new Date();
  const base = `${m.id}_${stamp(startedAt)}`;
  const tmp = path.join(REC_TMP, base + '.ogg');
  const entry = { id: crypto.randomBytes(5).toString('hex'), base, sessionId: m.state.sessionId, startedAt: startedAt.toISOString(), status: 'recording' };
  m.recordings.push(entry);
  save();
  const rec = { entry, tmp, ffmpeg: null, room: null, stopped: false, gen: 0, done: Promise.resolve(), timer: null };
  recorders.set(m.id, rec);
  try {
    rec.ffmpeg = spawn(
      'ffmpeg',
      ['-hide_banner', '-loglevel', 'error', '-f', 's16le', '-ar', '48000', '-ac', '1', '-i', 'pipe:0',
        '-c:a', 'libopus', '-b:a', '32k', '-application', 'voip', '-y', tmp],
      { stdio: ['pipe', 'ignore', 'inherit'] }
    );
    rec.ffmpeg.on('error', (e) => console.error('ffmpeg error:', e.message));
    rec.ffmpeg.stdin.on('error', () => {});
    rec.done = new Promise((r) => rec.ffmpeg.on('close', r));

    const { Room, RoomEvent, TrackKind, AudioStream } = await loadRtc();
    const room = new Room();
    rec.room = room;
    room.on(RoomEvent.TrackSubscribed, (track, _pub, participant) => {
      if (!participant || participant.identity !== 'broadcaster' || track.kind !== TrackKind.KIND_AUDIO) return;
      pipeTrack(rec, track, AudioStream).catch((e) => console.error('recording stream:', e.message));
    });
    const token = await makeToken({ identity: 'recorder', name: 'Recorder', room: m.id, publish: false, hidden: true });
    await room.connect(LK_INTERNAL_URL.replace(/^http/, 'ws'), token, { autoSubscribe: true, dynacast: false });
    rec.timer = setTimeout(() => stopRecording(m.id), MAX_RECORDING_MS);
    console.log(`[${m.id}] recording ${base}`);
  } catch (e) {
    console.error(`[${m.id}] recording could not start:`, e.message);
    stopRecording(m.id);
  }
}

async function pipeTrack(rec, track, AudioStream) {
  const my = ++rec.gen;
  const stream = new AudioStream(track, 48000, 1);
  for await (const frame of stream) {
    if (rec.stopped || my !== rec.gen) break;
    const d = frame.data;
    const buf = Buffer.from(d.buffer, d.byteOffset, d.byteLength);
    if (!rec.ffmpeg || rec.ffmpeg.exitCode !== null) break;
    if (!rec.ffmpeg.stdin.write(buf)) {
      await Promise.race([new Promise((r) => rec.ffmpeg.stdin.once('drain', r)), sleep(2000)]);
    }
  }
}

async function stopRecording(id) {
  const rec = recorders.get(id);
  if (!rec) return;
  recorders.delete(id);
  rec.stopped = true;
  clearTimeout(rec.timer);
  try {
    if (rec.room) await rec.room.disconnect();
  } catch (_) {}
  try {
    if (rec.ffmpeg) rec.ffmpeg.stdin.end();
  } catch (_) {}
  await Promise.race([rec.done, sleep(15000)]);
  await finalize(id, rec.entry, rec.tmp);
}

function run(cmd, args) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, { timeout: 30 * 60 * 1000 }, (err, stdout) => (err ? reject(err) : resolve(String(stdout))));
  });
}

async function finalize(mosqueId, entry, tmp) {
  const m = db.mosques[mosqueId];
  entry.status = 'processing';
  save();
  try {
    if (!fs.existsSync(tmp) || fs.statSync(tmp).size < 2000) throw new Error('no audio');
    const dir = path.join(REC_DIR, mosqueId);
    fs.mkdirSync(dir, { recursive: true });
    const file = entry.base + '.m4a';
    const out = path.join(dir, file);
    await run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-i', tmp, '-c:a', 'aac', '-b:a', '48k', '-ac', '1', '-movflags', '+faststart', out]);
    const dur = parseFloat(await run('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', out])) || 0;
    if (dur < 10) {
      fs.rmSync(out, { force: true });
      throw new Error('shorter than 10 seconds');
    }
    Object.assign(entry, { status: 'ready', file, durationSec: Math.round(dur), size: fs.statSync(out).size });
    console.log(`[${mosqueId}] recording saved: ${file} (${Math.round(dur / 60)} min)`);
  } catch (e) {
    console.log(`[${mosqueId}] recording dropped: ${e.message}`);
    if (m) m.recordings = m.recordings.filter((r) => r !== entry);
  } finally {
    fs.rmSync(tmp, { force: true });
    save();
  }
}

// Startup: finish recordings that were cut by a restart, and restart the recorder for running sessions
setTimeout(() => {
  for (const m of Object.values(db.mosques)) {
    for (const r of [...m.recordings]) {
      if (r.status !== 'ready') finalize(m.id, r, path.join(REC_TMP, r.base + '.ogg'));
    }
    if (isOn(m) && RECORDINGS_ON) startRecording(m);
  }
}, 5000);

// Delete old recordings / questions
function cleanup() {
  const recCut = Date.now() - RECORDING_DAYS * 864e5;
  const qCut = Date.now() - QUESTION_DAYS * 864e5;
  let changed = false;
  for (const m of Object.values(db.mosques)) {
    const keep = [];
    for (const r of m.recordings) {
      if (r.status === 'ready' && Date.parse(r.startedAt) < recCut) {
        fs.rmSync(path.join(REC_DIR, m.id, r.file), { force: true });
        console.log(`[${m.id}] deleted old recording ${r.file}`);
        changed = true;
      } else keep.push(r);
    }
    m.recordings = keep;
    const before = m.questions.length;
    m.questions = m.questions.filter((q) => Date.parse(q.at) >= qCut);
    if (m.questions.length !== before) changed = true;
  }
  if (changed) save();
}
setInterval(cleanup, 60 * 60 * 1000);
setTimeout(cleanup, 60 * 1000);

// ---------------------------------------------------------------- HTTP
const app = express();
app.set('trust proxy', 'loopback');
app.disable('x-powered-by');
app.use(express.json({ limit: '20kb' }));
app.use(express.static(path.join(__dirname, 'public'), { extensions: ['html'] }));
app.use('/recordings', express.static(REC_DIR, { maxAge: '7d' }));

const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

app.get('/api/health', (req, res) => res.json({ ok: true, recordings: RECORDINGS_ON }));

// Mosque info + live status (listeners poll this)
app.get(
  '/api/mosques/:id',
  wrap(async (req, res) => {
    const m = db.mosques[normId(req.params.id)];
    if (!m) return res.status(404).json({ code: 'not_found' });
    res.json(await mosqueInfo(m));
  })
);

// Past sessions
app.get('/api/mosques/:id/recordings', (req, res) => {
  const m = db.mosques[normId(req.params.id)];
  if (!m) return res.status(404).json({ code: 'not_found' });
  const list = m.recordings
    .filter((r) => r.status === 'ready')
    .sort((a, b) => Date.parse(b.startedAt) - Date.parse(a.startedAt))
    .map((r) => ({
      id: r.id,
      startedAt: r.startedAt,
      durationSec: r.durationSec,
      size: r.size,
      url: `/recordings/${m.id}/${encodeURIComponent(r.file)}`,
    }));
  const processing = m.recordings.some((r) => r.status !== 'ready');
  res.json({ recordings: list, processing, keepDays: RECORDING_DAYS });
});

// Listener token (listen-only)
app.post(
  '/api/listen',
  wrap(async (req, res) => {
    const m = db.mosques[normId(req.body && req.body.mosqueId)];
    if (!m) return res.status(404).json({ code: 'not_found' });
    const identity = 'l-' + crypto.randomBytes(5).toString('hex');
    const token = await makeToken({ identity, name: 'Listener', room: m.id, publish: false });
    res.json({ url: LK_PUBLIC_URL, token, mosque: publicMosque(m), status: statusOf(m) });
  })
);

// Questions from listeners (name optional)
const qLimits = new Map();
app.post('/api/questions', (req, res) => {
  const m = db.mosques[normId(req.body && req.body.mosqueId)];
  if (!m) return res.status(404).json({ code: 'not_found' });
  const text = String(req.body.text || '').trim().slice(0, 500);
  if (text.length < 2) return res.status(400).json({ code: 'empty' });
  const name = String(req.body.name || '').trim().slice(0, 40);
  const now = Date.now();
  const recent = (qLimits.get(req.ip) || []).filter((t) => now - t < 10 * 60 * 1000);
  if (recent.length >= 5) return res.status(429).json({ code: 'too_many' });
  recent.push(now);
  qLimits.set(req.ip, recent);
  m.questions.unshift({
    id: crypto.randomBytes(5).toString('hex'),
    name,
    text,
    at: nowIso(),
    sessionId: isOn(m) ? m.state.sessionId : null,
  });
  if (m.questions.length > 500) m.questions.length = 500;
  save();
  res.json({ ok: true });
});

// ---- lecturer (all need Mosque ID + PIN)
app.post('/api/broadcast/login', (req, res) => {
  const m = verifyBroadcaster(req, res);
  if (!m) return;
  res.json({ mosque: publicMosque(m), status: statusOf(m), schedule: m.schedule, questions: m.questions.length });
});

app.post(
  '/api/broadcast/token',
  wrap(async (req, res) => {
    const m = verifyBroadcaster(req, res);
    if (!m) return;
    const token = await makeToken({ identity: 'broadcaster', name: m.name, room: m.id, publish: true });
    res.json({ url: LK_PUBLIC_URL, token, mosque: publicMosque(m), status: statusOf(m) });
  })
);

// state: live | paused | resumed | ended
app.post(
  '/api/broadcast/state',
  wrap(async (req, res) => {
    const m = verifyBroadcaster(req, res);
    if (!m) return;
    const state = String(req.body.state || '');
    let result = {};
    if (state === 'live') result = await startSession(m);
    else if (state === 'paused') result.ok = await setPaused(m, true);
    else if (state === 'resumed') result.ok = await setPaused(m, false);
    else if (state === 'ended') result.ok = await endSession(m, 'lecturer ended');
    else return res.status(400).json({ code: 'bad_state' });
    res.json({ ok: true, status: statusOf(m), ...result });
  })
);

// Older app versions call this when going live
app.post(
  '/api/broadcast/live',
  wrap(async (req, res) => {
    const m = verifyBroadcaster(req, res);
    if (!m) return;
    const r = await startSession(m);
    res.json({ ok: true, push: r.push });
  })
);

app.post(
  '/api/broadcast/schedule',
  wrap(async (req, res) => {
    const m = verifyBroadcaster(req, res);
    if (!m) return;
    const text = String(req.body.text || '').trim().slice(0, 300);
    m.schedule = { text, updatedAt: nowIso() };
    save();
    await pushMeta(m);
    let push = 'skipped';
    if (text) {
      push = await notifySchedule(m).catch((e) => {
        console.error('Push failed:', e.message);
        return 'failed';
      });
    }
    res.json({ ok: true, schedule: m.schedule, push });
  })
);

app.post('/api/broadcast/questions', (req, res) => {
  const m = verifyBroadcaster(req, res);
  if (!m) return;
  res.json({ questions: m.questions });
});

app.post('/api/broadcast/questions/delete', (req, res) => {
  const m = verifyBroadcaster(req, res);
  if (!m) return;
  const before = m.questions.length;
  m.questions = m.questions.filter((q) => q.id !== String(req.body.id || ''));
  save();
  res.json({ ok: true, deleted: before - m.questions.length });
});

// ---- admin (add mosques, change name / PIN) - needs ADMIN_KEY
function requireAdmin(req, res, next) {
  const given = Buffer.from(req.get('x-admin-key') || '');
  const real = Buffer.from(ADMIN_KEY);
  if (!ADMIN_KEY || given.length !== real.length || !crypto.timingSafeEqual(given, real)) {
    return res.status(401).json({ code: 'unauthorized' });
  }
  next();
}
app.get('/api/admin/mosques', requireAdmin, (req, res) => res.json(Object.values(db.mosques).map(publicMosque)));
app.post('/api/admin/mosques', requireAdmin, (req, res) => {
  try {
    res.json(publicMosque(createMosque(req.body || {})));
  } catch (e) {
    res.status(400).json({ code: 'bad_request', message: e.message });
  }
});
app.post('/api/admin/mosques/:id', requireAdmin, (req, res) => {
  const m = db.mosques[normId(req.params.id)];
  if (!m) return res.status(404).json({ code: 'not_found' });
  try {
    if (req.body.name) m.name = String(req.body.name).trim().slice(0, 80);
    if (req.body.pin) {
      m.salt = crypto.randomBytes(16).toString('hex');
      m.pinHash = hashPin(validatePin(req.body.pin), m.salt);
    }
    save();
    res.json(publicMosque(m));
  } catch (e) {
    res.status(400).json({ code: 'bad_request', message: e.message });
  }
});

// Short share link:  https://masjidlive.duckdns.org/m/JMFM
app.get('/m/:id', (req, res) => res.redirect('/?m=' + encodeURIComponent(normId(req.params.id))));

app.use('/api', (req, res) => res.status(404).json({ code: 'not_found' }));
app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ code: 'server_error' });
});

app.listen(PORT, HOST, () => {
  console.log(`Masjid Live API on http://${HOST}:${PORT}  (LiveKit public URL: ${LK_PUBLIC_URL})`);
  console.log(`Mosques: ${Object.keys(db.mosques).join(', ') || '(none yet)'}  |  recordings: ${RECORDINGS_ON ? RECORDING_DAYS + ' days' : 'off'}`);
});
