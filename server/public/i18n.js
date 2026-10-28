// English + Urdu text for the web pages
const I18N = {
  en: {
    appName: 'Masjid Live',
    enterId: 'Enter Mosque ID',
    connect: 'Connect',
    mosque: 'Mosque',
    live: 'LIVE',
    offline: 'Not live right now',
    listeners: 'listening',
    tapToListen: 'Tap to listen',
    connecting: 'Connecting…',
    waiting: 'Connected. Waiting for the lecture to start…',
    playing: 'Listening live',
    changeMosque: 'Change mosque',
    iAmBroadcaster: 'I am the lecturer → Broadcast',
    backToListen: '← Back to listening',
    broadcast: 'Broadcast',
    pin: 'Broadcaster PIN',
    goLive: 'Go Live',
    endLive: 'End broadcast',
    endConfirm: 'End the broadcast for everyone?',
    youAreLive: 'You are LIVE',
    reconnecting: 'Reconnecting…',
    ended: 'Broadcast ended',
    keepOpen: 'Keep this page open with the screen on. To broadcast with the screen off, use the Android app.',
    err_mic: 'Microphone permission was denied.',
    err_not_found: 'Mosque ID not found.',
    err_wrong_pin: 'Wrong PIN.',
    err_locked: 'Too many wrong tries. Please wait 10 minutes.',
    err_network: 'No internet connection, or the server is down.',
    err_error: 'Something went wrong. Please try again.',
  },
  ur: {
    appName: 'مسجد لائیو',
    enterId: 'مسجد کی آئی ڈی درج کریں',
    connect: 'جڑیں',
    mosque: 'مسجد',
    live: 'براہِ راست',
    offline: 'ابھی نشر نہیں ہو رہا',
    listeners: 'سامعین',
    tapToListen: 'سننے کے لیے دبائیں',
    connecting: 'جڑ رہا ہے…',
    waiting: 'جڑ گئے۔ درس شروع ہونے کا انتظار ہے…',
    playing: 'براہِ راست سن رہے ہیں',
    changeMosque: 'مسجد تبدیل کریں',
    iAmBroadcaster: 'میں درس دینے والا ہوں ← نشر کریں',
    backToListen: 'سننے پر واپس جائیں →',
    broadcast: 'نشر کریں',
    pin: 'براڈکاسٹر پن',
    goLive: 'نشر شروع کریں',
    endLive: 'نشر ختم کریں',
    endConfirm: 'کیا سب کے لیے نشر ختم کر دیں؟',
    youAreLive: 'آپ براہِ راست نشر ہو رہے ہیں',
    reconnecting: 'دوبارہ جڑ رہا ہے…',
    ended: 'نشر ختم ہو گئی',
    keepOpen: 'یہ صفحہ کھلا اور اسکرین روشن رکھیں۔ اسکرین بند کر کے نشر کے لیے اینڈرائیڈ ایپ استعمال کریں۔',
    err_mic: 'مائیک کی اجازت نہیں دی گئی۔',
    err_not_found: 'یہ مسجد آئی ڈی نہیں ملی۔',
    err_wrong_pin: 'غلط پن۔',
    err_locked: 'بہت زیادہ غلط کوششیں۔ براہِ کرم 10 منٹ انتظار کریں۔',
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
