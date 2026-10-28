#!/bin/bash
# Runs every 5 minutes (cron). If there is new code on GitHub, download it and restart what changed.
# Live audio is handled by LiveKit, which is not restarted by normal code updates.
set -e
cd /opt/masjid-live
git fetch -q origin
if [ "$(git rev-parse HEAD)" != "$(git rev-parse '@{u}')" ]; then
  echo "$(date) - new version found, updating"
  git reset -q --hard '@{u}'
  cd deploy
  docker compose up -d --build --remove-orphans
  docker image prune -f >/dev/null
  echo "$(date) - update done"
fi
