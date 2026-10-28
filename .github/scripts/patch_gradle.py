"""Small fixes to the Android project that `flutter create` generates (run by GitHub Actions).

- minSdk 23 (needed by Firebase / WebRTC)
- turn off code shrinking (it can break WebRTC in release builds)
- Kotlin >= 2.1 if the template is older
- add the Google Services plugin when google-services.json is present (push notifications)
"""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])  # .../app/android
app = next(p for p in [root / "app/build.gradle.kts", root / "app/build.gradle"] if p.exists())
kts = app.suffix == ".kts"
gms = (root / "app/google-services.json").exists()

s = app.read_text()
s, n = re.subn(r"minSdk(?:Version)?\s*=?\s*flutter\.minSdkVersion", "minSdk = 23", s)
print("minSdk patched:", n)

if kts:
    s, n = re.subn(r'(signingConfig\s*=\s*signingConfigs\.getByName\("debug"\))',
                   r'\1\n            isMinifyEnabled = false\n            isShrinkResources = false', s, count=1)
else:
    s, n = re.subn(r'(signingConfig\s*=?\s*signingConfigs\.debug)',
                   r'\1\n            minifyEnabled false\n            shrinkResources false', s, count=1)
print("shrinking disabled:", n)

if gms and "com.google.gms.google-services" not in s:
    if kts:
        s, n = re.subn(r'(id\("dev\.flutter\.flutter-gradle-plugin"\))', r'\1\n    id("com.google.gms.google-services")', s, count=1)
    else:
        s, n = re.subn(r'(id\s+"dev\.flutter\.flutter-gradle-plugin")', r'\1\n    id "com.google.gms.google-services"', s, count=1)
    print("google-services plugin (app):", n)
app.write_text(s)

settings = next(p for p in [root / "settings.gradle.kts", root / "settings.gradle"] if p.exists())
t = settings.read_text()

def bump_kotlin(m):
    major = int(m.group(2).split(".")[0])
    return m.group(1) + ("2.1.0" if major < 2 else m.group(2)) + m.group(3)

t = re.sub(r'(org\.jetbrains\.kotlin\.android"\)?\s+version\s+")([0-9.]+)(")', bump_kotlin, t)

if gms and "com.google.gms.google-services" not in t:
    if kts:
        t, n = re.subn(r'(id\("dev\.flutter\.flutter-plugin-loader"\)\s+version\s+"[^"]+")',
                       r'\1\n    id("com.google.gms.google-services") version "4.4.2" apply false', t, count=1)
    else:
        t, n = re.subn(r'(id\s+"dev\.flutter\.flutter-plugin-loader"\s+version\s+"[^"]+")',
                       r'\1\n    id "com.google.gms.google-services" version "4.4.2" apply false', t, count=1)
    print("google-services plugin (settings):", n)
settings.write_text(t)

print("----", app.name, "----\n" + s)
print("----", settings.name, "----\n" + t)
