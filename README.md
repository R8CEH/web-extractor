# Web Extractor for Hermes Agent

Self-hosted service for extracting text content from web pages. Returns clean Markdown via a Firecrawl-compatible API. Single Chromium instance, page pool, cache — fast, local, free.

[![Python](https://img.shields.io/badge/Python-3.10%2B-blue)](https://www.python.org/)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

## Quick Start

```bash
# 1. Download and run the install script
curl -sSL https://raw.githubusercontent.com/r8ceh/web-extractor/main/install.sh | bash

# 2. Verify the service is running
curl http://127.0.0.1:3002/health
```

Windows:

```powershell
# Run PowerShell as Administrator
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/r8ceh/web-extractor/main/install.ps1" -OutFile "install.ps1"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
./install.ps1
```

## What is Web Extractor

AI assistants (e.g. Hermes Agent) can search the web, but finding a URL is not the same as reading the page. Extracting content requires a separate tool. Common options:

| Service | Downsides |
|---|---|
| **Firecrawl Cloud** | Paid, data goes to third-party servers |
| **Jina Reader** | Free with limits, data goes to Jina AI (now Elastic) |
| **Browser Playwright** | Each request launches a new Chromium — slow, eats RAM |

**Web Extractor** solves this locally: one persistent browser, a pool of up to 10 concurrent pages, a 5-minute cache, clean Markdown output. No data ever leaves your machine.

## How It Works

```
Client (Hermes Agent, curl, your script)
    │
    │ POST /v2/scrape {"url": "https://example.com/article"}
    ▼
Web Extractor (FastAPI, port 3002)
    │
    │ ① Cache? — if URL was recently extracted, return instantly
    │ ② asyncio.Semaphore(10) — max 10 concurrent requests
    ▼
Playwright Chromium (single instance, images disabled)
    │
    │ ③ goto(url) — load the page (domcontentloaded)
    │ ④ wait_for_load_state("networkidle") — wait for readiness (up to 5s)
    │ ⑤ Mozilla Readability.js — strip navigation, ads, footer
    ▼
HTML → markdownify → clean Markdown
    │
    │ ⑥ Save to cache (TTLCache: 5 min / 1000 entries)
    ▼
{"success": true, "data": {"markdown": "...", "metadata": {...}}}
```

## Features

- **Mozilla Readability.js** — the gold-standard Firefox Reader Mode algorithm. Scores paragraphs and containers, auto-detects article vs list layout, removes sidebars, navigation, cookie banners
- **In-memory cache** — repeated requests for the same URL return instantly (< 50ms). TTLCache: 5 min TTL, up to 1000 entries, automatic eviction
- **Page pool** — up to 10 concurrent requests via `asyncio.Semaphore`. The 11th waits in queue
- **Firecrawl-compatible API** — any tool that works with Firecrawl works with Web Extractor unchanged
- **Images disabled** — Chromium launches with `--disable-images`, pages load faster
- **Single browser** — Chromium starts once at service launch and stays alive. No cold start per request
- **URL validation** — Pydantic `HttpUrl` rejects `file://`, `javascript:`, and garbage at the schema level

## API

The service listens on `http://127.0.0.1:3002`.

### `POST /v2/scrape` — extract a page

```bash
curl -s -X POST http://127.0.0.1:3002/v2/scrape \
  -H "Content-Type: application/json" \
  -d '{"url": "https://example.com"}'
```

Response:

```json
{
  "success": true,
  "data": {
    "markdown": "# Example Domain\n\nSource: https://example.com/\n\n...",
    "metadata": {
      "title": "Example Domain",
      "url": "https://example.com/",
      "statusCode": 200
    }
  }
}
```

### `POST /v2/batch` — extract multiple pages

```bash
curl -s -X POST http://127.0.0.1:3002/v2/batch \
  -H "Content-Type: application/json" \
  -d '{"urls": ["https://example.com", "https://httpbin.org/html"]}'
```

Up to 10 URLs in parallel. If one fails, the rest continue.

### `GET /health` — service status

```bash
curl http://127.0.0.1:3002/health
# {"status": "ok", "browser": true, "cache_size": 42, "max_concurrent": 10}
```

### `DELETE /cache` — clear cache

```bash
curl -s -X DELETE http://127.0.0.1:3002/cache
# {"cleared": true}
```

## Installation

### Automatic (recommended)

**Linux / macOS:**

```bash
curl -sSL https://raw.githubusercontent.com/r8ceh/web-extractor/main/install.sh | bash
```

The script checks Python and Hermes, downloads files, creates a venv, installs Chromium, configures Hermes (Firecrawl backend + env vars), sets up systemd (Linux) or launchd (macOS), and starts the service.

**Windows:**

```powershell
# Run PowerShell as Administrator
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/r8ceh/web-extractor/main/install.ps1" -OutFile "install.ps1"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
./install.ps1
```

The script does the same and sets up Task Scheduler to auto-start the service on system boot.

### Manual

```bash
# 1. Python dependencies
pip install fastapi uvicorn markdownify playwright cachetools

# 2. Chromium
python3 -m playwright install chromium

# 3. Download extractor.py and Readability.js into ~/web-extractor/

# 4. Run the service
python3 ~/web-extractor/extractor.py

# 5. Configure Hermes Agent to use the local service
pip install firecrawl
hermes config set web.extract_backend firecrawl
hermes config set FIRECRAWL_API_URL http://127.0.0.1:3002
hermes config set FIRECRAWL_API_KEY local
```

> **Note:** Step 5 is only needed if you use Hermes Agent. `hermes config set` safely updates existing values in `.env` without creating duplicates.

## Updating

Run the same install command — the script detects an existing installation and only updates the service files, refreshes Python dependencies, and restarts the service. Chromium and Hermes configuration are not touched.

**Linux / macOS:**

```bash
curl -sSL https://raw.githubusercontent.com/r8ceh/web-extractor/main/install.sh | bash
```

**Windows:**

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/r8ceh/web-extractor/main/install.ps1" -OutFile "install.ps1"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
./install.ps1
```

## Requirements

| Component | Minimum |
|---|---|
| Python | 3.10+ |
| Disk | ~500 MB (Chromium + dependencies) |
| RAM | 2+ GB (10 concurrent pages ≈ 500 MB–1 GB) |
| OS | Linux (systemd), macOS (launchd), Windows (Task Scheduler) |

## Limitations

| Limitation | Description |
|---|---|
| **Anti-bot protection** | Cloudflare, Imperva, DDoS-Guard block Playwright requests |
| **JS-heavy SPAs** | React/Vue/Angular may not finish rendering within the `networkidle` timeout (5s) |
| **Authentication** | Pages behind login are inaccessible — no session/cookie management |
| **Local access only** | Service listens on `127.0.0.1` only — not reachable externally (by design) |
| **Cache** | In-memory only, no persistence — cleared on restart |
| **Timeout** | 30 seconds per page load |

## Performance

Benchmarks on a Beelink MINI S (Intel N100, 16 GB RAM):

| Scenario | Time |
|---|---|
| First request (cold browser start) | 3–6s |
| Repeat request (cache hit) | < 50ms |
| 10 concurrent pages | 5–10s |
| Static page (no JS) | 1–2s |
| Heavy SPA | 5–15s |

## License

MIT — do whatever you want, just keep the copyright notice.
