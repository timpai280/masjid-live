#!/bin/bash
# =====================================================================
#  Masjid Live - Oracle Cloud server setup (runs once, automatically)
#  Use image: Canonical Ubuntu 24.04 (NOT 20.04, NOT "Minimal").
#  Paste this whole file into: Create Instance -> Advanced options
#  -> Management -> "Paste cloud-init script".
#  Only edit the lines below.
# =====================================================================
REPO_URL="https://github.com/timpai280/masjid-live.git"
DUCKDNS_SUBDOMAIN="masjidlive"            # -> masjidlive.duckdns.org
DUCKDNS_TOKEN="PASTE-YOUR-DUCKDNS-TOKEN"
MOSQUE_NAME="Jama Masjid Family Mall"
MOSQUE_ID="JMFM"                          # what listeners type in the app (3-12 letters/numbers)
MOSQUE_PIN="1234"                         # lecturer's PIN (4-8 digits) - change it!
SCHEDULE="Weekly Qur'an Lesson - every Wednesday after Maghrib / ہفتہ وار درسِ قرآن - ہر بدھ بعد نمازِ مغرب"
RECORDING_DAYS="14"
# =====================================================================

set -euxo pipefail
exec > >(tee -a /var/log/masjid-live-setup.log) 2>&1
export DEBIAN_FRONTEND=noninteractive
DOMAIN="${DUCKDNS_SUBDOMAIN}.duckdns.org"
APP=/opt/masjid-live

# --- 1. Swap (small free servers have only 1 GB RAM)
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# --- 2. Packages + firewall
# Oracle's Ubuntu images block every port except SSH inside the server itself.
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
apt-get update -y
apt-get install -y git curl ca-certificates openssl iptables-persistent
iptables -I INPUT 1 -p tcp -m multiport --dports 80,443,7881 -j ACCEPT
iptables -I INPUT 1 -p udp --dport 50000:60000 -j ACCEPT
netfilter-persistent save

# --- 3. Docker (official repository; only the packages we need)
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  if curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc; then
    chmod a+r /etc/apt/keyrings/docker.asc
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -y
  fi
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin \
    || apt-get install -y docker.io docker-compose-v2
fi
systemctl enable --now docker
docker --version
docker compose version

# --- 4. Free web address (DuckDNS) - point it at this server, and keep it updated
DUCK_URL="https://www.duckdns.org/update?domains=${DUCKDNS_SUBDOMAIN}&token=${DUCKDNS_TOKEN}&ip="
curl -fsS "$DUCK_URL"; echo
echo "*/5 * * * * root curl -fsS '$DUCK_URL' >/dev/null 2>&1" > /etc/cron.d/duckdns

# --- 5. Download the code
if [ ! -d "$APP/.git" ]; then
  git clone "$REPO_URL" "$APP"
fi
cd "$APP/deploy"
mkdir -p data

# --- 6. Secret keys (created once, never stored on GitHub)
if [ ! -f .env ]; then
  LK_KEY="API$(openssl rand -hex 6)"
  LK_SECRET="$(openssl rand -hex 24)"
  ADMIN_KEY="$(openssl rand -hex 12)"
  cat > .env <<EOF
DOMAIN=$DOMAIN
LIVEKIT_API_KEY=$LK_KEY
LIVEKIT_API_SECRET=$LK_SECRET
LIVEKIT_PUBLIC_URL=wss://$DOMAIN
LIVEKIT_INTERNAL_URL=http://127.0.0.1:7880
ADMIN_KEY=$ADMIN_KEY
SEED_MOSQUE_ID=$MOSQUE_ID
SEED_MOSQUE_NAME=$MOSQUE_NAME
SEED_MOSQUE_PIN=$MOSQUE_PIN
SEED_SCHEDULE=$SCHEDULE
RECORDING_DAYS=$RECORDING_DAYS
FIREBASE_SERVICE_ACCOUNT_B64=
EOF
  chmod 600 .env
  cat > livekit.yaml <<EOF
port: 7880
rtc:
  tcp_port: 7881
  port_range_start: 50000
  port_range_end: 60000
  use_external_ip: true
keys:
  $LK_KEY: $LK_SECRET
logging:
  level: info
EOF
  chmod 600 livekit.yaml
fi

# --- 7. Start everything
docker compose up -d --build

# --- 8. Auto-update from GitHub every 5 minutes
chmod +x "$APP/deploy/update.sh"
echo "*/5 * * * * root bash $APP/deploy/update.sh >> /var/log/masjid-live-update.log 2>&1" > /etc/cron.d/masjid-live-update

# --- 9. Save the important info
ADMIN_KEY_NOW="$(grep '^ADMIN_KEY=' .env | cut -d= -f2)"
cat > /root/SETUP-INFO.txt <<EOF
Masjid Live is running!

Website (listeners):   https://$DOMAIN
Share link:            https://$DOMAIN/m/$MOSQUE_ID
Broadcast page:        https://$DOMAIN/broadcast
Admin page:            https://$DOMAIN/admin
Admin key:             $ADMIN_KEY_NOW

Mosque:     $MOSQUE_NAME
Mosque ID:  $MOSQUE_ID
PIN:        $MOSQUE_PIN   (change it from the admin page)
Recordings: kept $RECORDING_DAYS days in $APP/deploy/data/recordings

Logs:  sudo docker compose -f $APP/deploy/docker-compose.yml logs -f
EOF
cp /root/SETUP-INFO.txt /home/ubuntu/SETUP-INFO.txt 2>/dev/null && chown ubuntu:ubuntu /home/ubuntu/SETUP-INFO.txt || true
echo "=== Masjid Live setup finished ==="
