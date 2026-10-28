# 🕌 Masjid Live — live tafseer from one phone to many phones

The lecturer taps **Go Live** on their phone. Everyone who follows the mosque gets a
**"🔴 Tafseer is LIVE"** notification and hears the lecture on their phone speaker,
even with the screen locked. The delay is about 1 second. No mixer is needed.

English + اردو. Free to run (Oracle Cloud free tier).

---

## How it works

```
 LECTURER'S PHONE                ORACLE SERVER (free)                  LISTENERS' PHONES
┌──────────────────┐   audio    ┌──────────────────────────┐   audio   ┌─────────────────┐
│ Masjid Live app  │ ─────────▶ │ LiveKit  (audio engine)  │ ────────▶ │ 📱 Listener 1   │
│ → Broadcast      │            │ api      (IDs, PIN, LIVE)│ ────────▶ │ 📱 Listener 2   │
│ → PIN → Go Live  │            │ caddy    (HTTPS)         │ ────────▶ │ 📱 Listener 3…  │
└──────────────────┘            └────────────┬─────────────┘           └─────────────────┘
                                             │ "LIVE" push (Firebase)          ▲
                                             └─────────────────────────────────┘
```

1. The lecturer opens the app → **Broadcast** → enters the Mosque ID + PIN → **Go Live**.
2. The phone sends **one** audio stream (about 30 MB per hour) to the server.
3. The server copies it to every listener and sends the LIVE notification.
4. Listeners tap the notification (or ▶) and the audio plays on the loudspeaker.
5. Listeners only need to enter the **Mosque ID** once, e.g. `TEST01`.

| Folder | What's inside |
|---|---|
| `server/` | Small Node.js server + web pages (listener `/`, lecturer `/broadcast`, admin `/admin`) |
| `deploy/` | Oracle setup script, Docker setup, HTTPS config, auto-update |
| `app/` | Android app (Flutter): Listen + Broadcast modes, background audio, notifications |
| `.github/` | GitHub Actions: builds the APK automatically and publishes it as a Release |

---

## Setup (one time)

### 1. GitHub
1. Create a **public** repository called `masjid-live` and upload all these files.
2. **Settings → Secrets and variables → Actions → Variables** → add `SERVER_URL` = `https://yourmasjid.duckdns.org`
3. The **Actions** tab builds the APK in about 10 minutes. You can download it at
   `https://github.com/<you>/masjid-live/releases/latest/download/MasjidLive.apk`

### 2. DuckDNS (free web address)
1. Sign in at https://www.duckdns.org (Google login works).
2. Create a subdomain, e.g. `yourmasjid`, and copy the **token**.

### 3. Oracle Cloud (free server)
1. Sign up at https://cloud.oracle.com (free tier; a card is used for verification only).
2. **Create a compute instance**:
   - Image: **Ubuntu 22.04** (or 24.04)
   - Shape: **VM.Standard.A1.Flex** (1 OCPU, 6 GB) or **VM.Standard.E2.1.Micro**. Both are "Always Free".
   - Keep "Assign a public IPv4 address" ON.
   - **Advanced options → Management → Paste cloud-init script**: paste `deploy/oracle-setup.sh`
     after editing the 6 lines at the top (repo URL, DuckDNS name + token, mosque name/ID/PIN).
3. **Open ports**: Networking → Virtual cloud network → Default Security List → **Add Ingress Rules**
   (Source CIDR `0.0.0.0/0`):

   | Protocol | Port(s) | Why |
   |---|---|---|
   | TCP | 80 | HTTPS certificate |
   | TCP | 443 | Website + app |
   | TCP | 7881 | Audio fallback |
   | UDP | 50000-60000 | Audio |

4. Wait about 10 minutes, then open `https://yourmasjid.duckdns.org`. You should see the listener page.
   The admin key is in `SETUP-INFO.txt` on the server (`cat ~/SETUP-INFO.txt`).

### 4. Firebase (LIVE notifications) — optional, the audio works without it
1. https://console.firebase.google.com → **Add project**.
2. **Add app → Android**, package name **`com.masjidlive.masjid_live`** → download `google-services.json`.
   In GitHub add a **secret** `GOOGLE_SERVICES_JSON` and paste the whole file content as its value.
3. **Project settings → Service accounts → Generate new private key** → convert the file to base64 →
   put it in `FIREBASE_SERVICE_ACCOUNT_B64=` in `/opt/masjid-live/deploy/.env` on the server, then run
   `cd /opt/masjid-live/deploy && sudo docker compose up -d`.

### 5. (Optional) Fixed signing key
Without it, every new APK has a different signature, so you must **uninstall the old app before installing
an update**. To fix this, add a secret `ANDROID_KEYSTORE_B64` (a base64 Android keystore with the standard
debug passwords).

---

## Testing at home (2+ phones)
1. Install the APK on both phones. Android will ask to allow "Install unknown apps" — allow it.
2. **Phone A** → "I am the lecturer → Broadcast" → `TEST01` + PIN → **Go Live** → allow the microphone.
3. **Phone B** → enter `TEST01` → **Connect** → ▶. You should hear phone A within about 1 second.
4. Add more receivers: other phones, or a browser at `https://yourmasjid.duckdns.org/m/TEST01`.
5. ⚠️ Put the phones in **different rooms** or use earphones on the receivers, otherwise you will get echo.
6. Lock both screens. The audio should continue.

## Daily use
- Lecturer: open the app → Broadcast → Go Live → put the phone 1-2 feet from the mouth (shirt pocket or stand).
- Listeners: tap the notification. Share this link on WhatsApp so people can install the app:
  `https://github.com/<you>/masjid-live/releases/latest/download/MasjidLive.apk`
- iPhone users: open `https://yourmasjid.duckdns.org/m/TEST01` in Safari and keep the page open.

## Admin
`https://yourmasjid.duckdns.org/admin` → paste the admin key → add mosques or change a name or PIN.

## Updating
Change code on GitHub and two things happen automatically:
- `app/` changes → a new APK is built and published as the latest Release.
- `server/` or `deploy/` changes → the Oracle server downloads them within 5 minutes and restarts.

## Troubleshooting
| Problem | Fix |
|---|---|
| Website doesn't open | Wait 10 min after creating the server; check the 4 ingress rules; `sudo cat /var/log/masjid-live-setup.log` |
| "Connected, waiting…" but no sound | The lecturer is not live yet, or UDP ports 50000-60000 are not open |
| Echo / whistling | Phones too close to each other; use earphones on the receiver |
| Audio stops when screen locks | Settings → Apps → Masjid Live → Battery → **Unrestricted** (needed on Xiaomi/Oppo/Vivo/Samsung) |
| No notifications | Firebase not set up yet (step 4), or notifications are blocked for the app |
| Update won't install | Uninstall the old app first (or set up step 5) |
| Server stopped after weeks | Oracle may reclaim idle free servers; upgrading to "Pay As You Go" prevents it, and it stays free within the limits |

## Not in version 1 (planned)
- Recording and "Past sessions" (listen later)
- iPhone app (iPhone users can use the website for now)
