from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
import hashlib
import hmac
import os
from pathlib import Path
import secrets
from typing import Callable
from urllib.parse import parse_qs, quote, urlsplit

from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

from . import __version__
from .audio import AudioManager, AudioUnavailable, DeviceNotFound
from .config import verify_password

STATIC_DIR = Path(__file__).with_name("static")
audio_manager = AudioManager()
shutdown_handler: Callable[[], None] | None = None
password_hash = os.environ.get("MICLISTEN_PASSWORD_HASH", "")
session_secret = secrets.token_bytes(32)


def configure_authentication(encoded_password: str) -> None:
    global password_hash
    password_hash = encoded_password


def _session_token() -> str:
    return hmac.new(session_secret, password_hash.encode(), hashlib.sha256).hexdigest()


def _has_valid_session(request: Request) -> bool:
    if not password_hash:
        return True
    provided = request.cookies.get("miclisten_session", "")
    return hmac.compare_digest(provided, _session_token())


def set_shutdown_handler(handler: Callable[[], None] | None) -> None:
    global shutdown_handler
    shutdown_handler = handler


@asynccontextmanager
async def lifespan(app: FastAPI):
    audio_manager.start()
    yield
    await audio_manager.close()


app = FastAPI(title="MicListen", version=__version__, lifespan=lifespan)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


@app.middleware("http")
async def require_authentication(request: Request, call_next):
    if not password_hash or request.url.path == "/login":
        return await call_next(request)
    if _has_valid_session(request):
        return await call_next(request)
    if request.url.path.startswith(("/api/", "/stream/")):
        return JSONResponse({"detail": "Authentication required"}, status_code=401)
    destination = quote(request.url.path, safe="/")
    return RedirectResponse(f"/login?next={destination}", status_code=303)


@app.get("/login", include_in_schema=False)
async def login_page(next: str = "/") -> HTMLResponse:
    safe_next = next if next.startswith("/") and not next.startswith("//") else "/"
    return HTMLResponse(
        """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>MicListen login</title>
<style>body{font:16px system-ui;background:#081312;color:#eef8f4;display:grid;place-items:center;min-height:100vh;margin:0}form{width:min(360px,calc(100% - 40px));padding:28px;background:#10211f;border:1px solid #25403b;border-radius:16px}input,button{box-sizing:border-box;width:100%;padding:12px;margin-top:12px;border-radius:9px}input{background:#081312;color:white;border:1px solid #36534d}button{border:0;background:#58e6a9;color:#062118;font-weight:700}</style></head>
<body><form method="post"><h1>MicListen</h1><p>Enter the streamer password.</p>
<input type="password" name="password" autofocus required><input type="hidden" name="next" value=""" + safe_next + """>
<button type="submit">Continue</button></form></body></html>"""
    )


@app.post("/login", include_in_schema=False)
async def login(request: Request):
    fields = parse_qs((await request.body()).decode("utf-8", "replace"))
    entered = fields.get("password", [""])[0]
    destination = fields.get("next", ["/"])[0]
    if not destination.startswith("/") or destination.startswith("//"):
        destination = "/"
    if not verify_password(entered, password_hash):
        return HTMLResponse("Incorrect password. Go back and try again.", status_code=401)
    response = RedirectResponse(destination, status_code=303)
    response.set_cookie(
        "miclisten_session",
        _session_token(),
        httponly=True,
        secure=request.url.scheme == "https",
        samesite="strict",
    )
    return response


@app.get("/", include_in_schema=False)
async def index() -> HTMLResponse:
    content = (STATIC_DIR / "index.html").read_text(encoding="utf-8")
    return HTMLResponse(content.replace("{{MICLISTEN_VERSION}}", __version__))


@app.get("/api/devices")
async def devices() -> dict:
    try:
        found = audio_manager.list_devices()
    except AudioUnavailable as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    return {"devices": [device.to_dict() for device in found]}


@app.get("/api/health")
async def health() -> dict:
    return {
        "status": "ok" if audio_manager.backend is not None else "degraded",
        "audio_error": audio_manager.startup_error,
        "version": __version__,
        "authentication": bool(password_hash),
    }


@app.post("/api/shutdown")
async def shutdown(request: Request) -> dict:
    origin = request.headers.get("origin")
    host = request.headers.get("host", "")
    if origin and urlsplit(origin).netloc.lower() != host.lower():
        raise HTTPException(status_code=403, detail="Cross-origin shutdown is not allowed")
    if shutdown_handler is None:
        raise HTTPException(
            status_code=503,
            detail="Shutdown is unavailable when MicListen is run by an external server",
        )
    shutdown_handler()
    return {"status": "shutting_down"}


@app.get("/stream/audio/{device_id}.mp3", include_in_schema=False)
async def native_audio_stream(device_id: int) -> StreamingResponse:
    """Encode a device as live MP3 for native mobile background playback."""
    try:
        import lameenc

        device, queue = await audio_manager.subscribe_native(device_id)
    except (AudioUnavailable, DeviceNotFound) as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    encoder = lameenc.Encoder()
    encoder.set_bit_rate(128)
    encoder.set_in_sample_rate(device.sample_rate)
    encoder.set_channels(device.channels)
    encoder.set_quality(2)
    # Prime the encoder and give media elements bytes immediately. Safari is
    # more willing to treat a chunked response as live media once decoding can
    # begin without waiting for the first capture callback.
    initial_audio = encoder.encode(
        bytes(int(device.sample_rate * device.channels * 2 * 0.1))
    )

    async def encoded_audio():
        try:
            if initial_audio:
                yield bytes(initial_audio)
            while True:
                encoded = encoder.encode(await asyncio.to_thread(queue.get))
                if encoded:
                    yield bytes(encoded)
        finally:
            await audio_manager.unsubscribe_native(device_id, queue)

    return StreamingResponse(
        encoded_audio(),
        media_type="audio/mpeg",
        headers={
            "Cache-Control": "no-store, no-cache, must-revalidate",
            "Accept-Ranges": "none",
            "X-Content-Type-Options": "nosniff",
        },
    )


@app.websocket("/ws/audio/{device_id}")
async def audio_stream(websocket: WebSocket, device_id: int) -> None:
    if password_hash:
        provided = websocket.cookies.get("miclisten_session", "")
        if not hmac.compare_digest(provided, _session_token()):
            await websocket.close(code=4401, reason="Authentication required")
            return
    origin = websocket.headers.get("origin")
    host = websocket.headers.get("host", "")
    if origin and urlsplit(origin).netloc.lower() != host.lower():
        await websocket.close(code=1008, reason="Cross-origin audio access is not allowed")
        return
    await websocket.accept()
    queue = None
    try:
        device, queue = await audio_manager.subscribe(device_id)
        await websocket.send_json(
            {
                "type": "format",
                "encoding": "pcm_s16le",
                "sampleRate": device.sample_rate,
                "channels": device.channels,
                "device": device.to_dict(),
            }
        )
        while True:
            await websocket.send_bytes(await queue.get())
    except (AudioUnavailable, DeviceNotFound) as exc:
        await websocket.send_json({"type": "error", "message": str(exc)})
        await websocket.close(code=1011)
    except WebSocketDisconnect:
        pass
    except RuntimeError:
        # Starlette raises RuntimeError when a disconnected socket is written to.
        pass
    finally:
        if queue is not None:
            await audio_manager.unsubscribe(device_id, queue)
