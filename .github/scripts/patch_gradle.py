"""Small fixes to the Android project that `flutter create` generates (run by GitHub Actions).

- minSdk 23 (needed by Firebase / WebRTC)
- compileSdk 36 + Android Gradle Plugin >= 8.9.1 + Gradle >= 8.11.1
  (newer androidx libraries refuse to build with older versions)
- turn off code shrinking (it can break WebRTC in release builds)
- Kotlin >= 2.1 if the template is older
- add the Google Services plugin when google-services.json is present (push notifications)
"""
import pathlib
import re
import sys

MIN_AGP = "8.9.1"
MIN_GRADLE = "8.11.1"
MIN_KOTLIN = "2.1.0"
COMPILE_SDK = 36

root = pathlib.Path(sys.argv[1])  # .../app/android
app = next(p for p in [root / "app/build.gradle.kts", root / "app/build.gradle"] if p.exists())
kts = app.suffix == ".kts"
gms = (root / "app/google-services.json").exists()


def ver(v):
    return tuple(int(x) for x in re.findall(r"\d+", v)[:3])


def at_least(current, minimum):
    return current if ver(current) >= ver(minimum) else minimum


# ---------------------------------------------------------------- app/build.gradle(.kts)
s = app.read_text()
s, n = re.subn(r"minSdk(?:Version)?\s*=?\s*flutter\.minSdkVersion", "minSdk = 23", s)
print("minSdk patched:", n)
s, n = re.subn(r"compileSdk(?:Version)?\s*=?\s*(?:flutter\.compileSdkVersion|\d+)", f"compileSdk = {COMPILE_SDK}", s)
print("compileSdk patched:", n)

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

# ---------------------------------------------------------------- settings.gradle(.kts)
settings = next(p for p in [root / "settings.gradle.kts", root / "settings.gradle"] if p.exists())
t = settings.read_text()


def bump(minimum, label):
    def repl(m):
        new = at_least(m.group(2), minimum)
        print(f"{label}: {m.group(2)} -> {new}")
        return m.group(1) + new + m.group(3)
    return repl


t = re.sub(r'(com\.android\.application"\)?\s+version\s+")([0-9.]+)(")', bump(MIN_AGP, "Android Gradle Plugin"), t)
t = re.sub(r'(org\.jetbrains\.kotlin\.android"\)?\s+version\s+")([0-9.]+)(")', bump(MIN_KOTLIN, "Kotlin"), t)

if gms and "com.google.gms.google-services" not in t:
    if kts:
        t, n = re.subn(r'(id\("dev\.flutter\.flutter-plugin-loader"\)\s+version\s+"[^"]+")',
                       r'\1\n    id("com.google.gms.google-services") version "4.4.2" apply false', t, count=1)
    else:
        t, n = re.subn(r'(id\s+"dev\.flutter\.flutter-plugin-loader"\s+version\s+"[^"]+")',
                       r'\1\n    id "com.google.gms.google-services" version "4.4.2" apply false', t, count=1)
    print("google-services plugin (settings):", n)
settings.write_text(t)

# ---------------------------------------------------------------- gradle wrapper
wrapper = root / "gradle/wrapper/gradle-wrapper.properties"
if wrapper.exists():
    w = wrapper.read_text()

    def bump_gradle(m):
        new = at_least(m.group(2), MIN_GRADLE)
        print(f"Gradle: {m.group(2)} -> {new}")
        return m.group(1) + new + m.group(3)

    w = re.sub(r"(gradle-)([0-9.]+)(-(?:all|bin)\.zip)", bump_gradle, w)
    wrapper.write_text(w)
    print("----", wrapper.name, "----\n" + w)

print("----", app.name, "----\n" + s)
print("----", settings.name, "----\n" + t)
