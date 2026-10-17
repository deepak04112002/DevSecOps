# Smoke Test

A lightweight HTTP smoke test that verifies a staging URL returns a 2xx or 3xx response.

## Two ways to run

### 1. Shell script (direct)

```bash
export STAGING_BASE_URL=https://your-staging-url.example.com
bash tests/smoke.sh
```

### 2. Docker Compose service (no local curl required)

```bash
# Set STAGING_BASE_URL in .env first, then:
task smoke

# Or directly:
docker compose --profile tools run --rm smoke
```

## How it works

`tests/smoke.sh`:
1. Requires `STAGING_BASE_URL` to be set (fails immediately if not)
2. Sends a `GET` request to `$STAGING_BASE_URL/` with a 15-second timeout
3. Exits 0 on HTTP 2xx or 3xx
4. Exits 1 on any other status

The Docker `smoke` service uses `curlimages/curl:8.10.1` and runs the same logic inline, so no local `curl` installation is needed.

## Configuration

Set `STAGING_BASE_URL` in `.env`:

```env
STAGING_BASE_URL=https://your-staging-url.example.com
```

Leave it empty to skip smoke tests (the Docker service will exit with an error message rather than silently succeed).

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Smoke test passed (2xx or 3xx) |
| 1 | Smoke test failed (unexpected HTTP status) |
| 2 | `STAGING_BASE_URL` not set |
