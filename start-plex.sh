#!/bin/bash
# Detects current local IP and starts/restarts Plex with the correct ADVERTISE_IP

export HOST_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "127.0.0.1")

echo "Starting Plex with ADVERTISE_IP=http://${HOST_IP}:32400"

cd "$(dirname "$0")"
docker compose up -d plex
