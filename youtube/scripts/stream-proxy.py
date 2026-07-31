#!/usr/bin/env python3
"""
YouTube Webhook Proxy for Plex

Receives Plex webhook events. When a placeholder video is played, triggers
a background download of the real video, replacing the placeholder.

Endpoints:
  POST /webhook    — Plex webhook receiver (media.play triggers background download)
  GET  /health     — Health check (shows active downloads)

Usage: python3 stream-proxy.py [--port 9090]
"""

import glob as _glob
import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

PORT = int(sys.argv[sys.argv.index("--port") + 1]) if "--port" in sys.argv else 9090

BASE_DIR = Path(__file__).resolve().parent.parent
COOKIES_FILE = BASE_DIR / "config" / "cookies.txt"

# All tunables from environment (set via .env / docker-compose)
MEDIA_DIR = Path(os.environ.get("MEDIA_DIR", "/media/youtube"))
ARCHIVE_FILE = BASE_DIR / "state" / "archive.txt"
LOG_FILE = BASE_DIR / "state" / "logs" / "stream-proxy.log"
OUTPUT_TEMPLATE = str(MEDIA_DIR) + "/%(uploader)s/Season %(upload_date>%Y)s/%(uploader)s - S%(upload_date>%Y)sE%(upload_date>%m%d)s01 - %(title)s [%(id)s].%(ext)s"

PLEX_URL = os.environ.get("PLEX_URL", "")
PLEX_TOKEN = os.environ.get("PLEX_TOKEN", "")
PLEX_SECTION = os.environ.get("PLEX_SECTION", "9")
# Plex returns file paths using its own OS's separator (e.g. Z:\youtube\... on Windows).
# PLEX_MEDIA_PREFIX is that prefix; we replace it with MEDIA_DIR to get the container path.
PLEX_MEDIA_PREFIX = os.environ.get("PLEX_MEDIA_PREFIX", r"Z:\youtube")

DISK_LIMIT_PCT = 90

_downloading = set()
_downloading_lock = threading.Lock()


def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


def plex_path_to_local(container_path: str) -> str:
    """Map a Plex-returned file path (may use backslashes) to the container's local path."""
    normalized = container_path.replace("\\", "/")
    prefix_normalized = PLEX_MEDIA_PREFIX.replace("\\", "/")
    if normalized.startswith(prefix_normalized):
        return str(MEDIA_DIR) + normalized[len(prefix_normalized):]
    return normalized


# ── Disk management ──────────────────────────────────────────────────────────

def get_disk_usage_pct():
    try:
        usage = shutil.disk_usage(str(MEDIA_DIR))
        return int(usage.used * 100 / usage.total)
    except Exception as e:
        log(f"Error checking disk usage: {e}")
        return 0


def get_watched_videos():
    watched = []
    try:
        url = (f"{PLEX_URL}/library/sections/{PLEX_SECTION}/allLeaves"
               f"?X-Plex-Token={PLEX_TOKEN}")
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())

        for ep in data.get("MediaContainer", {}).get("Metadata", []):
            if ep.get("viewCount", 0) >= 1:
                for media in ep.get("Media", []):
                    for part in media.get("Part", []):
                        container_path = part.get("file", "")
                        local_path = plex_path_to_local(container_path)
                        if os.path.exists(local_path):
                            ph = Path(local_path).with_suffix(".placeholder")
                            if not ph.exists():
                                mtime = os.path.getmtime(local_path)
                                watched.append((mtime, local_path))
    except Exception as e:
        log(f"Error fetching watched videos: {e}")

    watched.sort()
    return [path for _, path in watched]


def get_oldest_videos():
    videos = []
    for mp4 in MEDIA_DIR.rglob("*.mp4"):
        if mp4.with_suffix(".placeholder").exists():
            continue
        videos.append((mp4.stat().st_mtime, str(mp4)))
    videos.sort()
    return [path for _, path in videos]


def cleanup_disk():
    pct = get_disk_usage_pct()
    if pct < DISK_LIMIT_PCT:
        return True

    log(f"Disk at {pct}% (limit {DISK_LIMIT_PCT}%), starting cleanup...")

    for path in get_watched_videos():
        if get_disk_usage_pct() < DISK_LIMIT_PCT:
            log("Disk cleanup complete (watched videos)")
            return True
        try:
            size = os.path.getsize(path)
            os.unlink(path)
            base = Path(path).with_suffix("")
            for ext in [".info.json", ".jpg", ".png", ".webp"]:
                sidecar = Path(str(base) + ext)
                if sidecar.exists():
                    sidecar.unlink()
            log(f"Deleted watched: {Path(path).name} ({size // 1024 // 1024}MB)")
        except Exception as e:
            log(f"Error deleting {path}: {e}")

    for path in get_oldest_videos():
        if get_disk_usage_pct() < DISK_LIMIT_PCT:
            log("Disk cleanup complete (oldest videos)")
            return True
        try:
            size = os.path.getsize(path)
            os.unlink(path)
            base = Path(path).with_suffix("")
            for ext in [".info.json", ".jpg", ".png", ".webp"]:
                sidecar = Path(str(base) + ext)
                if sidecar.exists():
                    sidecar.unlink()
            log(f"Deleted oldest: {Path(path).name} ({size // 1024 // 1024}MB)")
        except Exception as e:
            log(f"Error deleting {path}: {e}")

    final_pct = get_disk_usage_pct()
    if final_pct >= DISK_LIMIT_PCT:
        log(f"WARNING: Disk still at {final_pct}% after cleanup")
        return False

    return True


# ── Plex helpers ─────────────────────────────────────────────────────────────

def find_placeholder_by_file(file_path):
    p = Path(file_path)
    placeholder = p.with_suffix(".placeholder")
    if placeholder.exists():
        video_id = placeholder.read_text().strip()
        if video_id:
            return video_id, placeholder
    return None, None


def find_placeholder_by_plex_key(rating_key):
    try:
        url = f"{PLEX_URL}/library/metadata/{rating_key}?X-Plex-Token={PLEX_TOKEN}"
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())

        metadata = data.get("MediaContainer", {}).get("Metadata", [{}])[0]
        media_list = metadata.get("Media", [])
        for media in media_list:
            for part in media.get("Part", []):
                container_path = part.get("file", "")
                local_path = plex_path_to_local(container_path)
                video_id, placeholder_file = find_placeholder_by_file(local_path)
                if video_id:
                    return video_id, placeholder_file, local_path
    except Exception as e:
        log(f"Error looking up ratingKey {rating_key}: {e}")
    return None, None, None


def trigger_plex_scan():
    try:
        url = f"{PLEX_URL}/library/sections/{PLEX_SECTION}/refresh?X-Plex-Token={PLEX_TOKEN}"
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=10):
            pass
        log("Plex library scan triggered")
    except Exception as e:
        log(f"Failed to trigger Plex scan: {e}")


# ── Background download ─────────────────────────────────────────────────────

def find_all_placeholder_files(video_id):
    results = []
    for ph_file in MEDIA_DIR.rglob("*.placeholder"):
        try:
            content = ph_file.read_text().strip()
            if content == video_id:
                placeholder_mp4 = ph_file.with_suffix(".mp4")
                results.append((ph_file, placeholder_mp4 if placeholder_mp4.exists() else None))
        except Exception:
            continue
    return results


def cleanup_placeholder_for_video(video_id):
    matches = find_all_placeholder_files(video_id)
    for ph_file, placeholder_mp4 in matches:
        if placeholder_mp4 and placeholder_mp4.exists() and placeholder_mp4.stat().st_size < 100000:
            placeholder_mp4.unlink()
            log(f"Removed placeholder MP4: {placeholder_mp4.name}")
        if ph_file.exists():
            ph_file.unlink()
            log(f"Removed .placeholder: {ph_file.name}")
    if matches:
        log(f"Cleaned up {len(matches)} placeholder(s) for {video_id}")


def download_video_background(video_id):
    with _downloading_lock:
        if video_id in _downloading:
            return
        _downloading.add(video_id)

    try:
        if not cleanup_disk():
            log(f"Skipping download of {video_id}: disk full after cleanup")
            return

        url = f"https://www.youtube.com/watch?v={video_id}"
        cmd = [
            "yt-dlp",
            "-f", "bestvideo[vcodec^=avc1][ext=mp4]+bestaudio[ext=m4a]/bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
            "-o", OUTPUT_TEMPLATE,
            "--embed-thumbnail", "--embed-metadata",
            "--write-info-json", "--write-thumbnail", "--convert-thumbnails", "jpg",
            "--no-playlist",
            "--download-archive", str(ARCHIVE_FILE),
            "--print", "after_move:filepath",
        ]
        if COOKIES_FILE.exists():
            cmd += ["--cookies", str(COOKIES_FILE)]
        cmd.append(url)

        log(f"Background download starting: {video_id}")
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        filepath = proc.stdout.strip().split("\n")[-1] if proc.stdout.strip() else ""

        if filepath and os.path.exists(filepath):
            log(f"Background download complete: {filepath}")
            cleanup_placeholder_for_video(video_id)
            trigger_plex_scan()
        else:
            log(f"Background download may have failed for {video_id}: rc={proc.returncode}")
    except Exception as e:
        log(f"Background download error for {video_id}: {e}")
    finally:
        with _downloading_lock:
            _downloading.discard(video_id)


# ── HTTP handler ─────────────────────────────────────────────────────────────

class WebhookHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            status = {
                "status": "ok",
                "downloading": list(_downloading),
                "disk_usage_pct": get_disk_usage_pct(),
            }
            self.wfile.write(json.dumps(status).encode())
            return
        self.send_error(404)

    def do_POST(self):
        if self.path != "/webhook":
            self.send_error(404)
            return

        content_type = self.headers.get("Content-Type", "")
        content_length = int(self.headers.get("Content-Length", 0))

        payload = None
        try:
            body = self.rfile.read(content_length)
            if "multipart/form-data" in content_type:
                boundary = None
                for part in content_type.split(";"):
                    part = part.strip()
                    if part.startswith("boundary="):
                        boundary = part[len("boundary="):]
                        break
                if boundary:
                    boundary_bytes = f"--{boundary}".encode()
                    parts = body.split(boundary_bytes)
                    for part in parts:
                        if b'name="payload"' in part:
                            sep = part.find(b"\r\n\r\n")
                            if sep != -1:
                                payload_body = part[sep + 4:]
                                payload_body = payload_body.rstrip(b"\r\n-")
                                payload = json.loads(payload_body)
                                break
            else:
                payload = json.loads(body)
        except Exception as e:
            log(f"Webhook parse error: {e}")
            self.send_error(400, "Invalid payload")
            return

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"received":true}')

        if not payload:
            return

        event = payload.get("event", "")
        log(f"Webhook event: {event}")

        if event != "media.play":
            return

        metadata = payload.get("Metadata", {})
        rating_key = metadata.get("ratingKey")
        title = metadata.get("title", "unknown")

        if not rating_key:
            log("Webhook media.play but no ratingKey found")
            return

        log(f"media.play: '{title}' (ratingKey={rating_key})")

        video_id, placeholder_file, mp4_path = find_placeholder_by_plex_key(rating_key)

        if not video_id:
            log(f"Not a placeholder (ratingKey={rating_key}), ignoring")
            return

        log(f"Placeholder detected! video_id={video_id}, triggering background download...")
        t = threading.Thread(
            target=download_video_background,
            args=(video_id,),
            daemon=True,
        )
        t.start()


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    os.makedirs(LOG_FILE.parent, exist_ok=True)
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), WebhookHandler)
    log(f"Webhook proxy starting on port {PORT}")
    log(f"  POST /webhook — Plex webhook receiver")
    log(f"  GET  /health  — Health check")
    log(f"  MEDIA_DIR={MEDIA_DIR}")
    log(f"  PLEX_URL={PLEX_URL}  section={PLEX_SECTION}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("Shutting down")
        server.server_close()


if __name__ == "__main__":
    main()
