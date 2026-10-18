# Aux artwork origin

An image-only service on the existing Coolify server. Public reads use
`https://artwork.zaydkrunz.com/covers/<sha256>.jpg`. The SHA-256 is calculated
from the exact sanitized JPEG bytes served. Cloudflare terminates HTTPS and the
existing `pickleballs` tunnel forwards the hostname to Coolify's HTTP proxy.
No R2, Catbox, Apple credentials, or shared client secret is required.

## Coolify settings

- Public repository: `https://github.com/ShrootBuck/aux`, branch `main`.
- Build pack: Dockerfile. Base directory: `/server/artwork`. Dockerfile: `/Dockerfile`.
- Container port: `8080`. Domain: `http://artwork.zaydkrunz.com` (Cloudflare provides external HTTPS).
- Persistent named volume mounted at `/data`. This directory must be writable by UID 10001.
- Runtime variables: `PUBLIC_URL=https://artwork.zaydkrunz.com`, `TRUST_CLOUDFLARE=1`.
- Memory limit: 256 MB. CPU limit: 0.5 CPU. One Gunicorn worker, four threads.
- Health: `GET /health`, HTTP 200. Do not expose port 8080 directly to the Internet.
- Tunnel published application: `artwork.zaydkrunz.com` -> `http://localhost:80`.
- No Cloudflare Access login or browser challenge on this hostname. Only image GET/HEAD responses are publicly cacheable; API/health/error responses are `no-store`.
- A Cloudflare Configuration Rule matching `(http.host eq "artwork.zaydkrunz.com")` sets Browser Integrity Check to **Off**, so non-browser image clients are not rejected with error 1010. Keep the exception scoped to this hostname; upload authentication and server quotas still apply.

Only enable `TRUST_CLOUDFLARE=1` when requests reach the origin through the
Cloudflare Tunnel; otherwise forged CF-Connecting-IP headers could bypass IP
limits. IPv6 client addresses are grouped by /64. Salted hashes are retained
for rate limiting; logs omit client addresses, bearer tokens and payloads.

## API and limits

`POST /v1/installations` (empty body) issues a random installation token. This
is anonymous enrollment, not a user account or proof of identity. Tokens are
stored as SHA-256 digests server-side; the app saves its token in an owner-only
local file. Registration allows 5 per client address/hour, 200 globally/hour,
and at most 20,000 installations. There is no automatic registration after a
token is revoked.

`POST /v1/artwork` takes `Authorization: Bearer <token>` and an `image/jpeg`
body no larger than 250,000 bytes or 700 pixels on either axis. The server
decodes and re-encodes pixels into a fresh JPEG, then stores it atomically under
its hash. A repeat upload returns the existing URL. No filenames or external
URLs are accepted. Limits include failed image submissions: 60 per token/hour,
200 per token/day, 300 per address/hour, 2,000 globally/hour and 10,000 globally/day.
Limits survive restart. HTTP 429 includes Retry-After.

`GET` and `HEAD /covers/<hash>.jpg` need no authentication and support ETag,
conditional requests and immutable one-year cache headers. Storage defaults to
10 GiB (10,737,418,240 bytes); override `MAX_STORAGE_BYTES` explicitly if needed.
When a new image would exceed that cap, the service purges **all stored covers**,
then saves the incoming image as the first cover in the fresh store. Installation
credentials, rate-limit history, and service settings survive the purge. Reusing
an existing image adds no bytes and does not trigger a purge. Purging happens on
new uploads, not on a timer or merely when the cap is reached exactly.

The service stages the new image before purging and preserves in-flight reads.
It rejects uploads with HTTP 507 without purging if an image cannot fit by
itself or the disk lacks the 512 MiB free-space headroom needed to stage it.
The old directory is retired atomically, the incoming image is published, and
the retired files are deleted outside the upload lock. Startup finishes cleanup
if a crash or filesystem error interrupts disk reclamation. Failed publication
restores the old store before returning an error.

Purged image URLs return 404 at the origin until the same image is uploaded
again; Cloudflare and Discord may continue serving cached copies. The uncached
`GET /v1/artwork/<sha256>/status` endpoint returns `{"exists":true}` or
`{"exists":false}` with `Cache-Control: no-store` and `CDN-Cache-Control: no-store`.
Updated Aux clients check this endpoint whenever a cached URL is reused, such as
on a song change, then reupload missing artwork. Successfully resolved artwork
does not schedule periodic availability checks. Unknown status or network failures
retain the URL and retry on the next reuse.
Older app versions keep their previous 30-day cache behavior until updated.

## Operations and recovery

The persistent volume contains `covers/` and `artwork.sqlite` (plus WAL files
while running). Container replacement must retain this volume. Do not scale
onto a different host without moving the same storage.

Back up the entire volume with the service stopped, or use SQLite's backup API
for the database plus a copy of the immutable covers. No remote backup provider
is configured by this service. A volume protects against redeployment, not host
disk loss. Restore both components to `/data`, preserving UID 10001 ownership.
Startup reconciles image files written immediately before a database rollback.

For an abused credential, set `installations.revoked=1` for its digest using
the server's SQLite database. Do not print tokens in terminal history or logs.
For immediate manual removal of a cover, purge Cloudflare's cached URL as well,
and remember Discord may retain its own cached copy. Automatic capacity purging
removes origin files only. Turning off sharing in Aux does not delete previously
hosted covers.

## Validation

```sh
python3 -m venv /tmp/aux-artwork-tests
/tmp/aux-artwork-tests/bin/pip install -r server/artwork/requirements.txt
cd server/artwork
/tmp/aux-artwork-tests/bin/python -m unittest -q
```

Before claiming a deployment works: check `/health`, upload and fetch a JPEG,
verify the bytes match the URL hash, repeat to verify reuse, restart and check
the same URL, then confirm the image through Discord's media proxy and profile.
