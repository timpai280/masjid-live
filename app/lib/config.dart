/// Values baked into the APK at build time by GitHub Actions (repository variables).
/// SERVER_URL e.g. https://masjidlive.duckdns.org  (can be changed in the app: menu ⋮ -> Server address)
const String kServerUrl = String.fromEnvironment('SERVER_URL');

/// DEFAULT_MOSQUE_ID e.g. JMFM - listeners are connected to this mosque automatically,
/// nobody has to type an ID. They can still change it with "Change mosque".
const String kDefaultMosqueId = String.fromEnvironment('DEFAULT_MOSQUE_ID');
