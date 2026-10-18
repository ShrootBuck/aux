"""Aux's image-only origin. One Gunicorn worker, bounded threads, persistent SQLite + files."""
import hashlib
from contextlib import contextmanager
import io
import ipaddress
import logging
import os
from pathlib import Path
import re
import secrets
import shutil
import sqlite3
import tempfile
import threading
import time

from flask import Flask, abort, jsonify, request, send_file
from PIL import Image, UnidentifiedImageError
from werkzeug.exceptions import HTTPException

Image.MAX_IMAGE_PIXELS = 700 * 700


def create_app(config=None):
    app = Flask(__name__)
    app.config.update(
        MAX_CONTENT_LENGTH=250_000,
        DATA_DIR=os.environ.get("DATA_DIR", "/data"),
        PUBLIC_URL=os.environ.get("PUBLIC_URL", "https://artwork.zaydkrunz.com").rstrip("/"),
        TRUST_CLOUDFLARE=os.environ.get("TRUST_CLOUDFLARE", "0") == "1",
        MAX_STORAGE_BYTES=int(os.environ.get("MAX_STORAGE_BYTES", 10 * 1024**3)),
        MIN_FREE_BYTES=512 * 1024**2,
        MAX_INSTALLATIONS=20_000,
        RELEASE=os.environ.get("SOURCE_COMMIT", "development"),
    )
    if config:
        app.config.update(config)
    root = Path(app.config["DATA_DIR"])
    root.mkdir(parents=True, exist_ok=True)
    images = root / "covers"
    images.mkdir(exist_ok=True)
    lock = threading.Lock()

    def reclaim_purged(directory):
        try:
            shutil.rmtree(directory)
        except OSError:
            # A crash or filesystem error must not make retired images public
            # again. Startup retries reclaiming their disk space.
            app.logger.exception("Could not reclaim purged artwork")

    for directory in root.glob(".purged-*"):
        if directory.is_dir():
            reclaim_purged(directory)

    @contextmanager
    def database():
        db = sqlite3.connect(root / "artwork.sqlite", timeout=10)
        try:
            db.execute("PRAGMA journal_mode=WAL")
            with db:
                db.execute("BEGIN IMMEDIATE")
                yield db
        finally:
            db.close()

    with database() as db:
        db.executescript("""
            CREATE TABLE IF NOT EXISTS installations (digest TEXT PRIMARY KEY, created REAL NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS objects (hash TEXT PRIMARY KEY, bytes INTEGER NOT NULL, created REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS events (scope TEXT NOT NULL, at REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS event_lookup ON events(scope, at);
            CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """)
        if "created" not in {row[1] for row in db.execute("PRAGMA table_info(objects)")}:
            db.execute("ALTER TABLE objects ADD COLUMN created REAL NOT NULL DEFAULT 0")
        db.execute("CREATE INDEX IF NOT EXISTS object_age ON objects(created,hash)")
        db.execute("INSERT OR IGNORE INTO metadata VALUES ('ip_salt', ?)", (secrets.token_hex(32),))
        salt = db.execute("SELECT value FROM metadata WHERE key='ip_salt'").fetchone()[0]
        # Reconcile publication/eviction interrupted by a crash or DB rollback.
        for (key,) in db.execute("SELECT hash FROM objects").fetchall():
            if not (images / f"{key}.jpg").is_file():
                db.execute("DELETE FROM objects WHERE hash=?", (key,))
        for path in images.glob("*.jpg"):
            if re.fullmatch(r"[a-f0-9]{64}\.jpg", path.name):
                stat = path.stat()
                db.execute("INSERT OR IGNORE INTO objects (hash,bytes,created) VALUES (?,?,?)",
                           (path.stem, stat.st_size, stat.st_mtime))
                # Existing installations use original file time for upload age.
                db.execute("UPDATE objects SET created=? WHERE hash=? AND created=0", (stat.st_mtime, path.stem))

    def client_key():
        # Only enable behind the existing Cloudflare Tunnel. No public host port.
        value = request.headers.get("CF-Connecting-IP") if app.config["TRUST_CLOUDFLARE"] else request.remote_addr
        try:
            address = ipaddress.ip_address(value or "")
            # Group IPv6 by /64 so rotating privacy addresses doesn't evade limits.
            value = str(ipaddress.ip_network(f"{address}/64", strict=False)) if address.version == 6 else str(address)
        except ValueError:
            abort(400, "Missing client address")
        return hashlib.sha256((salt + value).encode()).hexdigest()

    def reserve(db, limits):
        now = time.time()
        db.execute("DELETE FROM events WHERE at < ?", (now - 86400,))
        retry = 0
        for scope, count, window in limits:
            n, oldest = db.execute("SELECT COUNT(*), MIN(at) FROM events WHERE scope=? AND at>?", (scope, now-window)).fetchone()
            if n >= count:
                retry = max(retry, int(oldest + window - now) + 1)
        if retry:
            response = jsonify(error="Rate limit reached", retry_after=retry)
            response.status_code = 429
            response.headers["Retry-After"] = str(retry)
            abort(response)
        for scope in set(scope for scope, _, _ in limits):
            db.execute("INSERT INTO events VALUES (?,?)", (scope, now))

    @app.after_request
    def headers(response):
        response.headers["X-Content-Type-Options"] = "nosniff"
        if "Cache-Control" not in response.headers:
            response.headers["Cache-Control"] = "no-store"
        # Do not log bearer tokens, IP addresses, song names, or request bodies.
        app.logger.info("%s %s %s", request.method, request.path[:100], response.status_code)
        return response

    @app.errorhandler(HTTPException)
    def error(error):
        if error.response is not None:
            return error.response
        return jsonify(error=error.description), error.code

    @app.get("/health")
    def health():
        with database() as db:
            db.execute("SELECT 1").fetchone()
        return jsonify(status="ok", release=app.config["RELEASE"])

    @app.post("/v1/installations")
    def register():
        if request.content_length not in (None, 0):
            abort(400, "No registration payload is required")
        ip = client_key()
        token = secrets.token_urlsafe(32)
        digest = hashlib.sha256(token.encode()).hexdigest()
        with lock, database() as db:
            reserve(db, [("register:"+ip, 5, 3600), ("register:global", 200, 3600)])
            if db.execute("SELECT COUNT(*) FROM installations").fetchone()[0] >= app.config["MAX_INSTALLATIONS"]:
                abort(503, "Registration capacity reached")
            db.execute("INSERT INTO installations(digest,created) VALUES (?,?)", (digest, time.time()))
        return jsonify(token=token), 201

    @app.post("/v1/artwork")
    def upload():
        auth = request.headers.get("Authorization", "")
        if not re.fullmatch(r"Bearer [A-Za-z0-9_-]{43}", auth):
            abort(401, "Installation credential required")
        digest = hashlib.sha256(auth[7:].encode()).hexdigest()
        ip = client_key()
        with lock, database() as db:
            if not db.execute("SELECT 1 FROM installations WHERE digest=? AND revoked=0", (digest,)).fetchone():
                abort(401, "Installation credential is invalid or revoked")
            reserve(db, [("upload:"+digest, 60, 3600), ("upload:"+digest, 200, 86400),
                         ("upload-ip:"+ip, 300, 3600), ("upload:global", 2000, 3600), ("upload:global", 10000, 86400)])
        if request.mimetype != "image/jpeg":
            abort(415, "Only JPEG artwork is accepted")
        raw = request.get_data()
        try:
            with Image.open(io.BytesIO(raw), formats=["JPEG"]) as source:
                if max(source.size) > 700 or min(source.size) < 1:
                    abort(422, "Artwork must be at most 700 pixels on each side")
                source.load()
                # Copy pixels into a fresh image; never carry EXIF, comments or ICC metadata.
                clean = Image.new("RGB", source.size)
                clean.paste(source.convert("RGB"))
                output = io.BytesIO()
                clean.save(output, format="JPEG", quality=85, optimize=True)
                data = output.getvalue()
        except (UnidentifiedImageError, OSError, ValueError, Image.DecompressionBombError):
            abort(422, "Invalid JPEG artwork")
        if len(data) > 250_000:
            abort(422, "Encoded artwork exceeds 250 KB")
        key = hashlib.sha256(data).hexdigest()
        target = images / f"{key}.jpg"
        created = False
        retired = None
        with lock, database() as db:
            if not target.exists():
                used = db.execute("SELECT COALESCE(SUM(bytes),0) FROM objects").fetchone()[0]
                if len(data) > app.config["MAX_STORAGE_BYTES"] or shutil.disk_usage(root).free < app.config["MIN_FREE_BYTES"] + len(data):
                    response = jsonify(error="Not enough storage for this upload; existing covers remain available")
                    response.status_code = 507
                    abort(response)
                # Atomic publication: readers can never receive a partial image.
                fd, temporary = tempfile.mkstemp(prefix=".upload-", dir=root)
                try:
                    with os.fdopen(fd, "wb") as stream:
                        stream.write(data)
                        stream.flush()
                        os.fsync(stream.fileno())
                    # Retire the whole store at once, so a crash cannot leave a
                    # partially purged collection public. Stage outside covers/.
                    if used + len(data) > app.config["MAX_STORAGE_BYTES"]:
                        retired = root / f".purged-{secrets.token_hex(16)}"
                        images.rename(retired)
                        try:
                            images.mkdir()
                            os.replace(temporary, target)
                        except OSError:
                            if images.exists():
                                images.rmdir()
                            retired.rename(images)
                            raise
                        db.execute("DELETE FROM objects")
                    else:
                        os.replace(temporary, target)
                finally:
                    if os.path.exists(temporary):
                        os.unlink(temporary)
                created = True
            db.execute("INSERT OR IGNORE INTO objects (hash,bytes,created) VALUES (?,?,?)", (key, len(data), time.time()))
        if retired is not None:
            # Readers and later uploads can continue while disk space is freed.
            reclaim_purged(retired)
        return jsonify(url=f"{app.config['PUBLIC_URL']}/covers/{key}.jpg", sha256=key), 201 if created else 200

    @app.get("/v1/artwork/<key>/status")
    def artwork_status(key):
        if not re.fullmatch(r"[a-f0-9]{64}", key):
            abort(404)
        with lock:
            exists = (images / f"{key}.jpg").is_file()
        # Unlike immutable image URLs, this answer must always reach the origin.
        response = jsonify(exists=exists)
        response.headers["Cache-Control"] = "no-store"
        response.headers["CDN-Cache-Control"] = "no-store"
        return response

    @app.route("/covers/<filename>", methods=["GET", "HEAD"])
    def cover(filename):
        if not re.fullmatch(r"[a-f0-9]{64}\.jpg", filename):
            abort(404)
        # Open the file before an upload can evict it; an in-flight reader keeps
        # its file descriptor even after the directory entry is removed.
        with lock:
            if not (images / filename).is_file():
                abort(404)
            response = send_file(images / filename, mimetype="image/jpeg", conditional=True, etag=filename[:-4], max_age=31536000)
        response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
        return response

    app.logger.setLevel(logging.INFO)
    return app
