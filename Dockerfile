FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    curl \
    bash \
    imagemagick \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir yt-dlp

WORKDIR /app

COPY youtube/scripts/ /app/scripts/

RUN chmod +x /app/scripts/*.sh

RUN mkdir -p /app/state/logs /app/config

CMD ["bash", "/app/scripts/download.sh"]
