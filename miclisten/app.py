from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Callable
from urllib.parse import urlsplit

from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

from . import __version__
from .audio import AudioManager, AudioUnavailable, DeviceNotFound

STATIC_DIR = Path(__file__).with_name("static")
audio_manager = AudioManager()
shutdown_handler: Callable[[], None] | None = None


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


@app.get("/", include_in_schema=False)
async def index() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


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
