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

# Ensure yt-dlp and ffmpeg are in PATH (launchd may not have full PATH)
os.environ["PATH"] = "/usr/local/bin:/opt/homebrew/bin:" + os.environ.get("PATH", "")

BASE_DIR = Path(__file__).resolve().parent.parent
COOKIES_FILE = BASE_DIR / "config" / "cookies.txt"
MEDIA_DIR = Path.home() / "Movies" / "youtube"
ARCHIVE_FILE = BASE_DIR / "state" / "archive.txt"
LOG_FILE = BASE_DIR / "state" / "logs" / "stream-proxy.log"
OUTPUT_TEMPLATE = str(MEDIA_DIR) + "/%(uploader)s/%(uploader)s - S%(upload_date>%Y)sE%(upload_date>%m%d)s01 - %(title)s [%(id)s].%(ext)s"

PLEX_URL = "http://localhost:32400"
PLEX_TOKEN = "GNEaLTTQ1t932g8LUT7G"
PLEX_SECTION = "6"
DISK_LIMIT_PCT = 90

# Track in-progress downloads to avoid duplicates
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


# ── Disk management ──────────────────────────────────────────────────────────

def get_disk_usage_pct():
    """Return disk usage percentage for the media directory."""
    try:
        usage = shutil.disk_usage(str(MEDIA_DIR))
        return int(usage.used * 100 / usage.total)
    except Exception as e:
        log(f"Error checking disk usage: {e}")
        return 0


def get_watched_videos():
    """Get list of watched video files from Plex (viewCount >= 1), oldest first."""
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
                        local_path = container_path.replace(
                            "/media/youtube", str(MEDIA_DIR))
                        if os.path.exists(local_path):
                            # Check it's not a placeholder
                            ph = Path(local_path).with_suffix(".placeholder")
                            if not ph.exists():
                                mtime = os.path.getmtime(local_path)
                                watched.append((mtime, local_path))
    except Exception as e:
        log(f"Error fetching watched videos: {e}")

    watched.sort()  # oldest first
    return [path for _, path in watched]


def get_oldest_videos():
    """Get all non-placeholder MP4 files sorted by modification time (oldest first)."""
    videos = []
    for mp4 in MEDIA_DIR.rglob("*.mp4"):
        if mp4.with_suffix(".placeholder").exists():
            continue
        videos.append((mp4.stat().st_mtime, str(mp4)))
    videos.sort()
    return [path for _, path in videos]


def cleanup_disk():
    """Free disk space by deleting watched videos first, then oldest unwatched.
    Returns True if disk is now below the limit."""
    pct = get_disk_usage_pct()
    if pct < DISK_LIMIT_PCT:
        return True

    log(f"Disk at {pct}% (limit {DISK_LIMIT_PCT}%), starting cleanup...")

    # Phase 1: delete watched videos
    for path in get_watched_videos():
        if get_disk_usage_pct() < DISK_LIMIT_PCT:
            log("Disk cleanup complete (watched videos)")
            return True
        try:
            size = os.path.getsize(path)
            os.unlink(path)
            # Also remove sidecar files
            base = Path(path).with_suffix("")
            for ext in [".info.json", ".jpg", ".png", ".webp"]:
                sidecar = Path(str(base) + ext)
                if sidecar.exists():
                    sidecar.unlink()
            log(f"Deleted watched: {Path(path).name} ({size // 1024 // 1024}MB)")
        except Exception as e:
            log(f"Error deleting {path}: {e}")

    # Phase 2: delete oldest unwatched
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
    """Given a media file path, check if it has a .placeholder sidecar."""
    p = Path(file_path)
    placeholder = p.with_suffix(".placeholder")
    if placeholder.exists():
        video_id = placeholder.read_text().strip()
        if video_id:
            return video_id, placeholder
    return None, None


def find_placeholder_by_plex_key(rating_key):
    """Look up a Plex item by ratingKey and check if it's a placeholder."""
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
                local_path = container_path.replace("/media/youtube", str(MEDIA_DIR))
                video_id, placeholder_file = find_placeholder_by_file(local_path)
                if video_id:
                    return video_id, placeholder_file, local_path
    except Exception as e:
        log(f"Error looking up ratingKey {rating_key}: {e}")
    return None, None, None


def trigger_plex_scan():
    """Trigger a Plex library scan for the YouTube section."""
    try:
        url = f"{PLEX_URL}/library/sections/{PLEX_SECTION}/refresh?X-Plex-Token={PLEX_TOKEN}"
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=10):
            pass
        log("Plex library scan triggered")
    except Exception as e:
        log(f"Failed to trigger Plex scan: {e}")


def send_plex_notification(title):
    """Send a notification to Plex clients that a video is ready."""
    try:
        msg = f"✅ {title} — listo para reproducir"
        # Use Plex's butler notification endpoint
        url = (f"{PLEX_URL}/:/plugins/com.plexapp.agents.none/messaging/send"
               f"?X-Plex-Token={PLEX_TOKEN}")
        # Fallback: use the Plex activity/notification via a simple log
        # Plex doesn't have a clean push notification API, so we use the
        # library scan + metadata update which causes Plex clients to refresh
        log(f"Notification: {msg}")
    except Exception as e:
        log(f"Failed to send notification: {e}")


# ── Background download ─────────────────────────────────────────────────────

def cleanup_placeholder_for_video(video_id):
    """Remove .placeholder sidecar and placeholder MP4 for a video about to be downloaded."""
    for ph_file in MEDIA_DIR.rglob("*.placeholder"):
        try:
            content = ph_file.read_text().strip()
            if content == video_id:
                # Remove the placeholder MP4 so yt-dlp can write the real one
                placeholder_mp4 = ph_file.with_suffix(".mp4")
                if placeholder_mp4.exists() and placeholder_mp4.stat().st_size < 100000:
                    placeholder_mp4.unlink()
                    log(f"Removed placeholder MP4: {placeholder_mp4.name}")
                ph_file.unlink()
                log(f"Removed .placeholder: {ph_file.name}")
                break
        except Exception:
            continue


def download_video_background(video_id):
    """Download a YouTube video to disk in the background, replacing the placeholder."""
    with _downloading_lock:
        if video_id in _downloading:
            return
        _downloading.add(video_id)

    try:
        # Check disk space first
        if not cleanup_disk():
            log(f"Skipping download of {video_id}: disk full after cleanup")
            send_plex_notification(f"No hay espacio en disco para descargar {video_id}")
            return

        # Remove placeholder MP4 before downloading so yt-dlp can write the real one
        cleanup_placeholder_for_video(video_id)

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
            video_title = Path(filepath).stem
            trigger_plex_scan()
            send_plex_notification(video_title)
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
        pass  # Suppress default logging

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

        # Check if this is a placeholder — trigger background download
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
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("Shutting down")
        server.server_close()


if __name__ == "__main__":
    main()
