FROM python:3.12-slim

# deno = runtime de JavaScript que yt-dlp necesita para resolver el challenge nsig de YouTube
COPY --from=denoland/deno:bin /deno /usr/local/bin/deno

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    curl \
    bash \
    imagemagick \
    && rm -rf /var/lib/apt/lists/*

# yt-dlp + plugin proveedor de PO Token (habla con el contenedor pot-provider vía HTTP)
RUN pip install --no-cache-dir yt-dlp bgutil-ytdlp-pot-provider

WORKDIR /app

COPY youtube/scripts/ /app/scripts/

RUN chmod +x /app/scripts/*.sh

RUN mkdir -p /app/state/logs /app/config

CMD ["bash", "/app/scripts/download.sh"]
