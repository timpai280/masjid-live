# Debian (not Alpine): the recorder library ships prebuilt binaries for glibc on x86 and ARM
FROM node:20-bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force
COPY . .
ENV NODE_ENV=production
CMD ["node", "index.js"]
