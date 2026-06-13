# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-06-13

### Added

- **Core service** — FastAPI app on `127.0.0.1:3002` with a Firecrawl-compatible API
- **`POST /v2/scrape`** — extract a single URL; returns clean Markdown via Mozilla Readability.js
- **`POST /v2/batch`** — extract up to 10 URLs in parallel
- **`GET /health`** — service status: browser state, cache size, version
- **`DELETE /cache`** — clear the in-memory cache
- **Single persistent Chromium** — browser starts once at launch via Playwright, no cold start per request
- **Page pool** — up to 10 concurrent pages via `asyncio.Semaphore`
- **In-memory cache** — TTLCache: 5-minute TTL, up to 1000 entries, automatic eviction
- **Mozilla Readability.js** — Firefox Reader Mode algorithm for clean content extraction
- **URL validation** — Pydantic `HttpUrl` rejects `file://`, `javascript:` and malformed URLs on all endpoints
- **Install scripts** — automated setup for Linux/macOS (`install.sh`) and Windows (`install.ps1`):
  - Creates virtualenv, installs dependencies, installs Playwright Chromium
  - Configures Hermes Agent (Firecrawl backend + env vars)
  - Sets up auto-start: systemd (Linux), launchd (macOS), Task Scheduler (Windows)
  - Idempotent: re-running the script updates the service instead of reinstalling from scratch
