#!/usr/bin/env python3
"""
YouTube Streaming Proxy for Plex

Plex plays .strm files that point to this proxy. When requested, the proxy
fetches the direct YouTube CDN URL via yt-dlp and proxies the stream to Plex.
After streaming completes, downloads the full video to disk for future plays.

Endpoints:
  GET  /stream/:id — Stream a YouTube video (used by .strm files in Plex)
  POST /webhook    — Plex webhook receiver (media.play triggers background download)
  GET  /health     — Health check

Usage: python3 stream-proxy.py [--port 9090]
"""

import http.server
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.parse
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

# Track in-progress downloads to avoid duplicates
_downloading = set()
_downloading_lock = threading.Lock()

# Cache resolved CDN URLs (video_id -> (url, timestamp))
_url_cache = {}
_url_cache_lock = threading.Lock()
URL_CACHE_TTL = 300  # YouTube CDN URLs expire; cache for 5 min


def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


def get_stream_url(video_id):
    """Get direct CDN URL for a YouTube video via yt-dlp."""
    # Check cache first
    with _url_cache_lock:
        cached = _url_cache.get(video_id)
        if cached and time.time() - cached[1] < URL_CACHE_TTL:
            return cached[0]

    url = f"https://www.youtube.com/watch?v={video_id}"
    cmd = [
        "yt-dlp",
        "--get-url",
        "-f", "best[ext=mp4]/best",
        "--no-playlist",
    ]
    if COOKIES_FILE.exists():
        cmd += ["--cookies", str(COOKIES_FILE)]
    cmd.append(url)

    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        urls = [u.strip() for u in proc.stdout.strip().split("\n") if u.strip()]
        if urls:
            stream_url = urls[0]  # Single combined URL
            with _url_cache_lock:
                _url_cache[video_id] = (stream_url, time.time())
            return stream_url
        log(f"get_stream_url failed for {video_id}: {proc.stderr[-300:]}")
    except Exception as e:
        log(f"get_stream_url error for {video_id}: {e}")
    return None


def proxy_stream(handler, video_id, head_only=False):
    """Proxy a YouTube CDN stream to the client, forwarding Range headers."""
    stream_url = get_stream_url(video_id)
    if not stream_url:
        handler.send_error(502, "Could not resolve YouTube stream URL")
        return

    # Build request to YouTube CDN, forwarding Range header if present
    headers = {}
    range_header = handler.headers.get("Range")
    if range_header:
        headers["Range"] = range_header

    try:
        req = urllib.request.Request(stream_url, headers=headers)
        with urllib.request.urlopen(req, timeout=30) as resp:
            # Forward status code
            status = resp.status
            handler.send_response(status)

            # Forward relevant headers
            for hdr in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"]:
                val = resp.headers.get(hdr)
                if val:
                    handler.send_header(hdr, val)
            if not resp.headers.get("Content-Type"):
                handler.send_header("Content-Type", "video/mp4")
            if not resp.headers.get("Accept-Ranges"):
                handler.send_header("Accept-Ranges", "bytes")
            handler.end_headers()

            if head_only:
                return

            # Stream the data
            while True:
                chunk = resp.read(131072)  # 128KB chunks
                if not chunk:
                    break
                try:
                    handler.wfile.write(chunk)
                except BrokenPipeError:
                    break
    except urllib.error.HTTPError as e:
        log(f"CDN proxy error for {video_id}: HTTP {e.code}")
        handler.send_error(502, f"CDN returned {e.code}")
    except Exception as e:
        log(f"CDN proxy error for {video_id}: {e}")
        try:
            handler.send_error(502, "Stream proxy error")
        except Exception:
            pass


def download_video_background(video_id):
    """Download a YouTube video to disk in the background (for future offline plays)."""
    with _downloading_lock:
        if video_id in _downloading:
            return
        _downloading.add(video_id)

    try:
        url = f"https://www.youtube.com/watch?v={video_id}"
        cmd = [
            "yt-dlp",
            "-f", "bestvideo[vcodec^=avc1][ext=mp4]+bestaudio[ext=m4a]/bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
            "-o", OUTPUT_TEMPLATE,
            "--embed-thumbnail", "--embed-metadata",
            "--write-info-json", "--write-thumbnail", "--convert-thumbnails", "jpg",
            "--no-overwrites", "--no-playlist",
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
            # Remove .strm file if it exists alongside the downloaded video
            cleanup_strm_for_video(video_id)
            trigger_plex_scan()
        else:
            log(f"Background download may have failed for {video_id}: rc={proc.returncode}")
    except Exception as e:
        log(f"Background download error for {video_id}: {e}")
    finally:
        with _downloading_lock:
            _downloading.discard(video_id)


def cleanup_strm_for_video(video_id):
    """Remove .strm and .placeholder files for a video that's been downloaded."""
    for strm_file in MEDIA_DIR.rglob("*.strm"):
        try:
            content = strm_file.read_text().strip()
            if video_id in content:
                strm_file.unlink()
                log(f"Removed .strm: {strm_file.name}")
                # Also remove .placeholder sidecar if it exists
                placeholder = strm_file.with_suffix(".placeholder")
                if placeholder.exists():
                    placeholder.unlink()
                    log(f"Removed .placeholder: {placeholder.name}")
                break
        except Exception:
            continue


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


class WebhookHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress default logging

    def do_HEAD(self):
        self.do_GET(head_only=True)

    def do_GET(self, head_only=False):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            if not head_only:
                status = {"status": "ok", "downloading": list(_downloading)}
                self.wfile.write(json.dumps(status).encode())
            return

        # /stream/<video_id> — streaming endpoint (used by .strm files)
        stream_match = re.match(r"^/stream/([A-Za-z0-9_-]{11})$", self.path)
        if stream_match:
            video_id = stream_match.group(1)
            log(f"Stream request: {video_id} (Range: {self.headers.get('Range', 'none')})")

            # Check if we already have the file on disk
            local_file = find_local_file(video_id)
            if local_file:
                log(f"Serving from disk: {local_file.name}")
                self.serve_file(local_file, head_only)
                return

            # Stream from YouTube CDN
            log(f"Streaming from YouTube: {video_id}")
            proxy_stream(self, video_id, head_only)

            # Trigger background download for future plays (only on first request, not Range)
            if not self.headers.get("Range"):
                t = threading.Thread(
                    target=download_video_background,
                    args=(video_id,),
                    daemon=True,
                )
                t.start()
            return

        # Legacy /play endpoint
        play_match = re.match(r"^/play/([A-Za-z0-9_-]{11})$", self.path)
        if play_match:
            video_id = play_match.group(1)
            log(f"Request: {self.command} /play/{video_id}")
            local_file = find_local_file(video_id)
            if not local_file:
                # Download and serve
                download_video_background(video_id)
                local_file = find_local_file(video_id)
            if not local_file:
                self.send_error(503, "Download failed")
                return
            self.serve_file(local_file, head_only)
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

    def serve_file(self, file_path, head_only=False):
        file_size = file_path.stat().st_size

        range_header = self.headers.get("Range")
        if range_header:
            match = re.match(r"bytes=(\d+)-(\d*)", range_header)
            if match:
                start = int(match.group(1))
                end = int(match.group(2)) if match.group(2) else file_size - 1
                end = min(end, file_size - 1)
                length = end - start + 1

                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
                self.send_header("Content-Length", str(length))
                self.send_header("Content-Type", "video/mp4")
                self.send_header("Accept-Ranges", "bytes")
                self.end_headers()

                if not head_only:
                    with open(file_path, "rb") as f:
                        f.seek(start)
                        remaining = length
                        while remaining > 0:
                            chunk = min(65536, remaining)
                            data = f.read(chunk)
                            if not data:
                                break
                            try:
                                self.wfile.write(data)
                            except BrokenPipeError:
                                break
                            remaining -= len(data)
                return

        self.send_response(200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(file_size))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()

        if not head_only:
            with open(file_path, "rb") as f:
                while True:
                    data = f.read(65536)
                    if not data:
                        break
                    try:
                        self.wfile.write(data)
                    except BrokenPipeError:
                        break


def find_local_file(video_id):
    """Check if a video is already downloaded locally."""
    for info_file in MEDIA_DIR.rglob("*.info.json"):
        try:
            data = json.loads(info_file.read_text())
            if data.get("id") == video_id:
                mp4 = info_file.with_suffix(".mp4")
                if mp4.exists():
                    return mp4
        except Exception:
            continue
    return None


def main():
    os.makedirs(LOG_FILE.parent, exist_ok=True)
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), WebhookHandler)
    log(f"Streaming proxy starting on port {PORT}")
    log(f"  GET  /stream/:id — Stream YouTube video (for .strm files)")
    log(f"  POST /webhook    — Plex webhook receiver")
    log(f"  GET  /health     — Health check")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("Shutting down")
        server.server_close()


if __name__ == "__main__":
    main()
