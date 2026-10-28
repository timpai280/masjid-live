'use strict';
/**
 * Masjid Live - API server
 *
 * Jobs:
 *  - Keeps the list of mosques (ID, name, broadcaster PIN)
 *  - Hands out LiveKit tokens: listeners may only LISTEN, the broadcaster (PIN) may SPEAK
 *  - Reports whether a mosque is live right now and how many people are listening
 *  - Sends the "Tafseer is LIVE" push notification (Firebase) when the broadcaster goes live
 *  - Serves the web pages (listener, broadcaster, admin)
 *
 * The audio itself never passes through this program - it flows through LiveKit.
 */
const express = require('express');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
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
const NOTIFY_COOLDOWN_MS = 15 * 60 * 1000; // max one "LIVE" notification per mosque per 15 min

if (!LK_KEY || !LK_SECRET) {
  console.error('LIVEKIT_API_KEY and LIVEKIT_API_SECRET must be set');
  process.exit(1);
}

// ---------------------------------------------------------------- storage (simple JSON file)
fs.mkdirSync(DATA_DIR, { recursive: true });
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

// ---------------------------------------------------------------- helpers
const normId = (id) => String(id || '').trim().toUpperCase().replace(/[^A-Z0-9]/g, '');
const hashPin = (pin, salt) => crypto.scryptSync(String(pin), salt, 32).toString('hex');
const publicMosque = (m) => ({ id: m.id, name: m.name });

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

function createMosque({ id, name, pin }) {
  name = String(name || '').trim().slice(0, 80);
  if (!name) throw new Error('Name is required');
  pin = validatePin(pin);
  id = id ? normId(id) : newId();
  if (id.length < 3 || id.length > 12) throw new Error('ID must be 3-12 letters/numbers');
  if (db.mosques[id]) throw new Error('This ID already exists');
  const salt = crypto.randomBytes(16).toString('hex');
  const m = { id, name, salt, pinHash: hashPin(pin, salt), createdAt: new Date().toISOString() };
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

async function makeToken({ identity, name, room, publish }) {
  const at = new AccessToken(LK_KEY, LK_SECRET, { identity, name, ttl: '8h' });
  at.addGrant({
    roomJoin: true,
    room,
    canPublish: publish, // only the broadcaster can send audio
    canSubscribe: !publish, // listeners receive audio
    canPublishData: false,
  });
  return at.toJwt();
}

const statusCache = new Map();
async function roomStatus(id) {
  const c = statusCache.get(id);
  if (c && Date.now() - c.at < 3000) return c.v;
  let v = { live: false, listeners: 0 };
  try {
    const parts = await roomSvc.listParticipants(id);
    const b = parts.find((p) => p.identity === 'broadcaster');
    v = {
      live: !!(b && b.tracks && b.tracks.length > 0),
      listeners: parts.filter((p) => String(p.identity).startsWith('l-')).length,
    };
  } catch (_) {
    /* room does not exist yet = not live */
  }
  statusCache.set(id, { at: Date.now(), v });
  return v;
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

async function notifyLive(m) {
  if (!messaging) return 'disabled';
  const now = Date.now();
  if (m.lastNotified && now - m.lastNotified < NOTIFY_COOLDOWN_MS) return 'cooldown';
  m.lastNotified = now;
  save();
  await messaging.send({
    topic: `mosque_${m.id}`,
    notification: {
      title: `🔴 ${m.name} - LIVE`,
      body: 'Tafseer has started. Tap to listen.\nتفسیر شروع ہو گئی ہے۔ سننے کے لیے دبائیں۔',
    },
    data: { mosqueId: m.id, type: 'live' },
    android: { priority: 'high', notification: { tag: `live_${m.id}`, channelId: 'live' } },
  });
  return 'sent';
}

// ---------------------------------------------------------------- HTTP
const app = express();
app.set('trust proxy', 'loopback');
app.disable('x-powered-by');
app.use(express.json({ limit: '20kb' }));
app.use(express.static(path.join(__dirname, 'public'), { extensions: ['html'] }));

const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

app.get('/api/health', (req, res) => res.json({ ok: true }));

// Mosque info + live status (used by listeners to show the LIVE badge)
app.get(
  '/api/mosques/:id',
  wrap(async (req, res) => {
    const m = db.mosques[normId(req.params.id)];
    if (!m) return res.status(404).json({ code: 'not_found' });
    res.json({ ...publicMosque(m), ...(await roomStatus(m.id)) });
  })
);

// Listener token (listen-only)
app.post(
  '/api/listen',
  wrap(async (req, res) => {
    const m = db.mosques[normId(req.body && req.body.mosqueId)];
    if (!m) return res.status(404).json({ code: 'not_found' });
    const identity = 'l-' + crypto.randomBytes(5).toString('hex');
    const token = await makeToken({ identity, name: 'Listener', room: m.id, publish: false });
    res.json({ url: LK_PUBLIC_URL, token, mosque: publicMosque(m) });
  })
);

// Broadcaster token (needs PIN)
app.post(
  '/api/broadcast/token',
  wrap(async (req, res) => {
    const m = verifyBroadcaster(req, res);
    if (!m) return;
    const token = await makeToken({ identity: 'broadcaster', name: m.name, room: m.id, publish: true });
    res.json({ url: LK_PUBLIC_URL, token, mosque: publicMosque(m) });
  })
);

// Broadcaster tells us they are live -> send notification
app.post(
  '/api/broadcast/live',
  wrap(async (req, res) => {
    const m = verifyBroadcaster(req, res);
    if (!m) return;
    statusCache.delete(m.id);
    const push = await notifyLive(m).catch((e) => {
      console.error('Push failed:', e.message);
      return 'failed';
    });
    res.json({ ok: true, push });
  })
);

// ---- admin (add mosques, change PIN) - needs ADMIN_KEY
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

// Short share link:  https://yourmasjid.duckdns.org/m/TEST01
app.get('/m/:id', (req, res) => res.redirect('/?m=' + encodeURIComponent(normId(req.params.id))));

app.use('/api', (req, res) => res.status(404).json({ code: 'not_found' }));
app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ code: 'server_error' });
});

app.listen(PORT, HOST, () => {
  console.log(`Masjid Live API on http://${HOST}:${PORT}  (LiveKit public URL: ${LK_PUBLIC_URL})`);
  console.log(`Mosques: ${Object.keys(db.mosques).join(', ') || '(none yet)'}`);
});
