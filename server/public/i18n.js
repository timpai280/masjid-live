// English + Urdu text for the web pages
const I18N = {
  en: {
    appName: 'Masjid Live',
    enterId: 'Enter Mosque ID',
    connect: 'Connect',
    mosque: 'Mosque',
    live: 'LIVE',
    paused: 'Paused',
    endedShort: 'Lesson ended',
    offline: 'Not live right now',
    listeners: 'listening',
    tapToListen: 'Tap to listen',
    connecting: 'Connecting…',
    waiting: 'Connected. Waiting for the lesson to start…',
    playing: 'Listening live',
    pausedListener: '⏸ Paused – the lesson will resume shortly. Stay connected.',
    endedNote: 'The lesson has ended. JazakAllah khair. The recording will appear in Past sessions in a few minutes.',
    changeMosque: 'Change mosque',
    iAmBroadcaster: 'I am the lecturer → Broadcast',
    backToListen: '← Back to listening',
    broadcast: 'Broadcast',
    pin: 'Broadcaster PIN',
    goLive: 'Go Live',
    pause: 'Pause',
    resume: 'Resume',
    endLive: 'End lesson',
    endConfirm: 'End the lesson for everyone?',
    youAreLive: 'You are LIVE',
    youArePaused: 'PAUSED – listeners are waiting',
    reconnecting: 'Reconnecting…',
    ended: 'Lesson ended',
    keepOpen: 'Keep this page open with the screen on. To broadcast with the screen off, use the Android app.',
    schedule: 'Schedule',
    askQuestion: '✍️ Ask a question',
    askHint: 'The lecturer will read your question after the lesson. Your name is optional.',
    yourName: 'Your name (optional)',
    yourQuestion: 'Your question',
    send: 'Send',
    cancel: 'Cancel',
    questionSent: 'JazakAllah khair – your question was sent.',
    pastSessions: '🎧 Past sessions',
    noRecordings: 'No recordings yet.',
    processing: 'The latest lesson is being prepared – check again in a few minutes.',
    keptFor: 'Recordings are kept for {n} days.',
    min: 'min',
    err_mic: 'Microphone permission was denied.',
    err_not_found: 'Mosque ID not found.',
    err_wrong_pin: 'Wrong PIN.',
    err_locked: 'Too many wrong tries. Please wait 10 minutes.',
    err_too_many: 'You have sent several questions. Please wait a few minutes.',
    err_empty: 'Please type your question.',
    err_network: 'No internet connection, or the server is down.',
    err_error: 'Something went wrong. Please try again.',
  },
  ur: {
    appName: 'مسجد لائیو',
    enterId: 'مسجد کی آئی ڈی درج کریں',
    connect: 'جڑیں',
    mosque: 'مسجد',
    live: 'براہِ راست',
    paused: 'وقفہ',
    endedShort: 'درس ختم ہو گیا',
    offline: 'ابھی نشر نہیں ہو رہا',
    listeners: 'سامعین',
    tapToListen: 'سننے کے لیے دبائیں',
    connecting: 'جڑ رہا ہے…',
    waiting: 'جڑ گئے۔ درس شروع ہونے کا انتظار ہے…',
    playing: 'براہِ راست سن رہے ہیں',
    pausedListener: '⏸ وقفہ – درس تھوڑی دیر میں دوبارہ شروع ہوگا۔ جڑے رہیں۔',
    endedNote: 'درس ختم ہو گیا۔ جزاک اللہ خیر۔ ریکارڈنگ چند منٹ میں پچھلے دروس میں آ جائے گی۔',
    changeMosque: 'مسجد تبدیل کریں',
    iAmBroadcaster: 'میں درس دینے والا ہوں ← نشر کریں',
    backToListen: 'سننے پر واپس جائیں →',
    broadcast: 'نشر کریں',
    pin: 'براڈکاسٹر پن',
    goLive: 'نشر شروع کریں',
    pause: 'وقفہ',
    resume: 'دوبارہ شروع کریں',
    endLive: 'درس ختم کریں',
    endConfirm: 'کیا سب کے لیے درس ختم کر دیں؟',
    youAreLive: 'آپ براہِ راست نشر ہو رہے ہیں',
    youArePaused: 'وقفہ – سامعین انتظار کر رہے ہیں',
    reconnecting: 'دوبارہ جڑ رہا ہے…',
    ended: 'درس ختم ہو گیا',
    keepOpen: 'یہ صفحہ کھلا اور اسکرین روشن رکھیں۔ اسکرین بند کر کے نشر کے لیے اینڈرائیڈ ایپ استعمال کریں۔',
    schedule: 'شیڈول',
    askQuestion: '✍️ سوال پوچھیں',
    askHint: 'درس دینے والے درس کے بعد آپ کا سوال پڑھیں گے۔ نام لکھنا ضروری نہیں۔',
    yourName: 'آپ کا نام (اختیاری)',
    yourQuestion: 'آپ کا سوال',
    send: 'بھیجیں',
    cancel: 'منسوخ',
    questionSent: 'جزاک اللہ خیر – آپ کا سوال بھیج دیا گیا۔',
    pastSessions: '🎧 پچھلے دروس',
    noRecordings: 'ابھی کوئی ریکارڈنگ نہیں۔',
    processing: 'تازہ درس تیار ہو رہا ہے – چند منٹ بعد دوبارہ دیکھیں۔',
    keptFor: 'ریکارڈنگ {n} دن تک محفوظ رہتی ہے۔',
    min: 'منٹ',
    err_mic: 'مائیک کی اجازت نہیں دی گئی۔',
    err_not_found: 'یہ مسجد آئی ڈی نہیں ملی۔',
    err_wrong_pin: 'غلط پن۔',
    err_locked: 'بہت زیادہ غلط کوششیں۔ براہِ کرم 10 منٹ انتظار کریں۔',
    err_too_many: 'آپ نے کئی سوال بھیجے ہیں۔ براہِ کرم چند منٹ انتظار کریں۔',
    err_empty: 'براہِ کرم اپنا سوال لکھیں۔',
    err_network: 'انٹرنیٹ نہیں ہے یا سرور بند ہے۔',
    err_error: 'کچھ غلط ہو گیا۔ دوبارہ کوشش کریں۔',
  },
};

let LANG = localStorage.getItem('lang') || 'en';
function t(k) {
  return (I18N[LANG] && I18N[LANG][k]) || I18N.en[k] || k;
}
function errMsg(e) {
  const k = 'err_' + (e && e.message);
  const s = t(k);
  return s === k ? t('err_error') : s;
}
function applyI18n() {
  document.documentElement.lang = LANG;
  document.documentElement.dir = LANG === 'ur' ? 'rtl' : 'ltr';
  document.querySelectorAll('[data-i18n]').forEach((el) => (el.textContent = t(el.dataset.i18n)));
  document.querySelectorAll('[data-i18n-ph]').forEach((el) => (el.placeholder = t(el.dataset.i18nPh)));
  const b = document.getElementById('langBtn');
  if (b) b.textContent = LANG === 'en' ? 'اردو' : 'English';
}
function toggleLang() {
  LANG = LANG === 'en' ? 'ur' : 'en';
  localStorage.setItem('lang', LANG);
  applyI18n();
  if (window.onLangChange) window.onLangChange();
}
async function api(path, body) {
  const opts = body
    ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }
    : {};
  let r;
  try {
    r = await fetch(path, opts);
  } catch (_) {
    throw new Error('network');
  }
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.code || 'error');
  return j;
}
function parseStatus(metadata) {
  try {
    const j = JSON.parse(metadata || '');
    return (j && typeof j.status === 'string') ? j.status : '';
  } catch (_) {
    return '';
  }
}
function fmtWhen(iso) {
  const d = new Date(iso);
  if (isNaN(d)) return '';
  return d.toLocaleString('en-IN', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric', hour: 'numeric', minute: '2-digit' });
}
function esc(s) {
  return String(s || '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
