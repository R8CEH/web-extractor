"""
extractor.py — Self-hosted Firecrawl-compatible web extractor
- Playwright Chromium with browser pool (10 concurrent pages)
- Mozilla Readability.js for clean content extraction
- Firecrawl API compatible (/v2/scrape endpoint)
- 5-minute cache for repeat requests

Install:
    pip install fastapi uvicorn markdownify playwright cachetools

Run:
    python extractor.py

Hermes config:
    hermes config set web.extract_backend firecrawl
    hermes config set FIRECRAWL_API_URL http://127.0.0.1:3002
    hermes config set FIRECRAWL_API_KEY local
"""

import asyncio
import copy
import itertools
import logging
import os
from contextlib import asynccontextmanager
from typing import Optional

from cachetools import TTLCache

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, HttpUrl
from playwright.async_api import async_playwright, Browser, BrowserContext
from markdownify import markdownify as md

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ─── Configuration ────────────────────────────────────────────────────────────

__version__ = "0.1.0"

MAX_CONCURRENT = 10          # max concurrent pages
CACHE_TTL = 300              # cache TTL: 5 minutes
CACHE_MAX_SIZE = 1000        # max cache entries
REQUEST_TIMEOUT = 30_000     # page load timeout (ms)
NETWORK_IDLE_TIMEOUT = 5_000 # ms, max wait for network idle
EVALUATE_TIMEOUT_S = 10.0    # seconds, max wait for Readability.js in browser
MARKDOWN_LINE_LIMIT = 2000   # max lines in output markdown
HOST = "127.0.0.1"
PORT = 3002
READABILITY_JS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Readability.js")

_playwright = None
_browser: Optional[Browser] = None
_browser_lock = asyncio.Lock()
_semaphore = asyncio.Semaphore(MAX_CONCURRENT)
_cache = TTLCache(maxsize=CACHE_MAX_SIZE, ttl=CACHE_TTL)
_READABILITY_JS: str = ""


async def get_browser() -> Browser:
    global _playwright, _browser
    async with _browser_lock:
        if _browser is None or not _browser.is_connected():
            if _browser is not None:
                try:
                    await _browser.close()
                except Exception:
                    pass
            if _playwright is not None:
                try:
                    await _playwright.stop()
                except Exception:
                    pass
            _playwright = await async_playwright().start()
            _browser = await _playwright.chromium.launch(
                args=[
                    "--no-sandbox",
                    "--disable-dev-shm-usage",
                    "--disable-gpu",
                    "--blink-settings=imagesEnabled=false",
                ]
            )
            logger.info("Browser started")
    return _browser


async def new_context(browser: Browser) -> BrowserContext:
    return await browser.new_context(
        user_agent=(
            "Mozilla/5.0 (X11; Linux x86_64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/124.0.0.0 Safari/537.36"
        ),
        viewport={"width": 1280, "height": 800},
        java_script_enabled=True,
        bypass_csp=True,  # required to inject Readability.js on CSP-protected pages
    )


def _build_result(title: str, html: str, url: str) -> dict:
    """HTML → markdown → final response dict."""
    markdown = md(
        html,
        heading_style="ATX",
        bullets="-",
        convert=["p", "h1", "h2", "h3", "h4", "h5", "h6",
                 "ul", "ol", "li", "blockquote", "code", "pre",
                 "strong", "em", "a", "table", "tr", "td", "th"]
    )

    # Collapse consecutive blank lines, keep all content lines
    grouped = itertools.groupby(markdown.splitlines(), key=lambda l: bool(l.strip()))
    lines = []
    for has_content, group in grouped:
        if has_content:
            lines.extend(group)
        else:
            lines.append("")
    clean = "\n".join(lines[:MARKDOWN_LINE_LIMIT])

    return {
        "data": {
            "markdown": f"# {title}\n\nSource: {url}\n\n{clean}",
            "metadata": {
                "title": title,
                "url": url,
                "statusCode": 200
            }
        },
        "success": True
    }


async def _fetch_page(url: str) -> dict:
    """Browser extraction without cache."""
    browser = await get_browser()
    context = None
    try:
        context = await new_context(browser)
        page = await context.new_page()

        await page.goto(
            url,
            wait_until="domcontentloaded",
            timeout=REQUEST_TIMEOUT
        )

        # Wait for network idle, no more than 5 seconds
        try:
            await page.wait_for_load_state("networkidle", timeout=NETWORK_IDLE_TIMEOUT)
        except Exception:
            pass  # networkidle not reached — continue with what we have

        await page.add_script_tag(content=_READABILITY_JS)

        # Parse with Readability
        try:
            extracted = await asyncio.wait_for(
                page.evaluate("""
                    () => {
                        const reader = new Readability(document);
                        const result = reader.parse();
                        if (!result) return null;
                        return {
                            title: result.title || document.title,
                            html: result.content || '',
                            text: result.textContent || ''
                        };
                    }
                """),
                timeout=EVALUATE_TIMEOUT_S
            )
        except asyncio.TimeoutError:
            raise HTTPException(status_code=504, detail="Content extraction timed out")

        if not extracted or not extracted.get("html"):
            raise HTTPException(status_code=422, detail="No content extracted")

        logger.info(f"Readability: html={len(extracted['html'])} chars, text={len(extracted.get('text', ''))} chars")

        return _build_result(extracted["title"], extracted["html"], url)

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error extracting {url}: {e!r}", exc_info=True)
        raise HTTPException(status_code=500, detail="Extraction failed")
    finally:
        if context:
            try:
                await context.close()
            except Exception:
                logger.warning("Failed to close browser context", exc_info=True)


async def extract_page(url: str) -> dict:
    """Extract page content. Returns dict with markdown, title, url."""

    # Check cache
    result = _cache.get(url)
    if result is not None:
        logger.info(f"Cache hit: {url}")
        return copy.deepcopy(result)

    async with _semaphore:
        result = await _fetch_page(url)

    _cache[url] = result
    return result


# ─── FastAPI ──────────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Load Readability.js into memory
    global _READABILITY_JS
    with open(READABILITY_JS_PATH, encoding="utf-8") as f:
        _READABILITY_JS = f.read()

    # Warm up the browser on startup
    await get_browser()
    logger.info(f"Extractor ready. Max concurrent: {MAX_CONCURRENT}")
    yield
    # Shutdown
    global _browser, _playwright
    async with _browser_lock:
        if _browser:
            await _browser.close()
            _browser = None
        if _playwright:
            await _playwright.stop()
            _playwright = None
    logger.info("Browser stopped")


app = FastAPI(
    title="Web Extractor",
    description="Self-hosted Firecrawl-compatible web extractor",
    lifespan=lifespan
)


class ScrapeRequest(BaseModel):
    url: HttpUrl


class BatchRequest(BaseModel):
    urls: list[HttpUrl]


def _format_batch_error(exc: Exception) -> dict:
    if isinstance(exc, HTTPException):
        return {"error": exc.detail, "success": False}
    logger.error(f"Unexpected error in batch: {exc!r}", exc_info=True)
    return {"error": "Internal error", "success": False}


@app.post("/v2/scrape")
async def scrape(req: ScrapeRequest):
    """Firecrawl-compatible scrape endpoint."""
    return await extract_page(str(req.url))


@app.post("/v2/batch")
async def batch_scrape(req: BatchRequest):
    """Extract multiple URLs in parallel."""
    if len(req.urls) > MAX_CONCURRENT:
        raise HTTPException(
            status_code=400,
            detail=f"Max {MAX_CONCURRENT} URLs per batch"
        )
    results = await asyncio.gather(
        *[extract_page(str(url)) for url in req.urls],
        return_exceptions=True
    )
    return {
        "results": [
            r if not isinstance(r, Exception) else _format_batch_error(r)
            for r in results
        ]
    }


@app.get("/health")
async def health():
    connected = _browser is not None and _browser.is_connected()
    return {
        "status": "ok",
        "version": __version__,
        "browser": connected,
        "cache_size": len(_cache),
        "max_concurrent": MAX_CONCURRENT
    }


@app.delete("/cache")
async def clear_cache():
    _cache.clear()
    return {"cleared": True}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "extractor:app",
        host=HOST,
        port=PORT,
        log_level="info"
    )
