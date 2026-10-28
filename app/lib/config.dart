/// Server address baked into the APK at build time by GitHub Actions
/// (repository variable SERVER_URL, e.g. https://yourmasjid.duckdns.org).
/// Can be overridden inside the app: menu (⋮) -> Server address.
const String kServerUrl = String.fromEnvironment('SERVER_URL');
