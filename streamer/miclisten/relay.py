from __future__ import annotations

import asyncio
import json
import logging
from pathlib import Path
from typing import Any

import websockets

from . import __version__
from .audio import AudioManager, AudioUnavailable, DeviceNotFound
from .config import Settings

logger = logging.getLogger(__name__)
STATIC_DIR = Path(__file__).with_name("static")


def _web_files() -> dict[str, str]:
    index = (STATIC_DIR / "index.html").read_text(encoding="utf-8")
    return {
        "index.html": index.replace("{{MICLISTEN_VERSION}}", __version__),
        "app.js": (STATIC_DIR / "app.js").read_text(encoding="utf-8"),
        "styles.css": (STATIC_DIR / "styles.css").read_text(encoding="utf-8"),
        "audio-processor.js": (STATIC_DIR / "audio-processor.js").read_text(
            encoding="utf-8"
        ),
    }


class RelayClient:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.audio = AudioManager()
        self.socket: Any = None
        self.send_lock = asyncio.Lock()
        self.stream_tasks: dict[str, asyncio.Task] = {}
        self.stop_event = asyncio.Event()

    async def send_json(self, message: dict[str, Any]) -> None:
        async with self.send_lock:
            await self.socket.send(json.dumps(message))

    async def send_audio(self, stream_id: str, payload: bytes) -> None:
        async with self.send_lock:
            await self.socket.send(stream_id.encode("ascii") + payload)

    async def _pcm_stream(self, stream_id: str, device_id: int) -> None:
        queue = None
        try:
            device, queue = await self.audio.subscribe(device_id)
            await self.send_json(
                {
                    "type": "stream_format",
                    "stream_id": stream_id,
                    "format": {
                        "type": "format",
                        "encoding": "pcm_s16le",
                        "sampleRate": device.sample_rate,
                        "channels": device.channels,
                        "device": device.to_dict(),
                    },
                }
            )
            while True:
                await self.send_audio(stream_id, await queue.get())
        except (AudioUnavailable, DeviceNotFound, OSError) as exc:
            await self.send_json(
                {"type": "stream_error", "stream_id": stream_id, "message": str(exc)}
            )
        except asyncio.CancelledError:
            raise
        finally:
            if queue is not None:
                await self.audio.unsubscribe(device_id, queue)

    async def _mp3_stream(self, stream_id: str, device_id: int) -> None:
        queue = None
        try:
            import lameenc

            device, queue = await self.audio.subscribe_native(device_id)
            encoder = lameenc.Encoder()
            encoder.set_bit_rate(128)
            encoder.set_in_sample_rate(device.sample_rate)
            encoder.set_channels(device.channels)
            encoder.set_quality(2)
            initial = encoder.encode(
                bytes(int(device.sample_rate * device.channels * 2 * 0.1))
            )
            if initial:
                await self.send_audio(stream_id, bytes(initial))
            while True:
                encoded = encoder.encode(await asyncio.to_thread(queue.get))
                if encoded:
                    await self.send_audio(stream_id, bytes(encoded))
        except (AudioUnavailable, DeviceNotFound, OSError) as exc:
            await self.send_json(
                {"type": "stream_error", "stream_id": stream_id, "message": str(exc)}
            )
        except asyncio.CancelledError:
            raise
        finally:
            if queue is not None:
                await self.audio.unsubscribe_native(device_id, queue)

    async def _stop_stream(self, stream_id: str) -> None:
        task = self.stream_tasks.pop(stream_id, None)
        if task is not None:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)

    async def _handle_request(self, message: dict[str, Any]) -> None:
        request_id = str(message.get("id", ""))
        action = message.get("action")
        should_stop = False
        try:
            if action == "devices":
                result = {"devices": [item.to_dict() for item in self.audio.list_devices()]}
            elif action == "health":
                result = {
                    "status": "ok" if self.audio.backend is not None else "degraded",
                    "audio_error": self.audio.startup_error,
                    "version": __version__,
                    "authentication": bool(self.settings.password_hash),
                }
            elif action == "shutdown":
                result = {"status": "shutting_down"}
                should_stop = True
            else:
                raise ValueError(f"Unknown relay action: {action}")
            await self.send_json(
                {"type": "response", "id": request_id, "ok": True, "result": result}
            )
            if should_stop:
                self.stop_event.set()
        except (AudioUnavailable, ValueError) as exc:
            await self.send_json(
                {"type": "response", "id": request_id, "ok": False, "error": str(exc)}
            )

    async def _receive(self) -> None:
        async for raw in self.socket:
            if not isinstance(raw, str):
                continue
            message = json.loads(raw)
            message_type = message.get("type")
            if message_type == "request":
                await self._handle_request(message)
            elif message_type in {"audio_start", "native_start"}:
                stream_id = str(message["stream_id"])
                await self._stop_stream(stream_id)
                target = self._pcm_stream if message_type == "audio_start" else self._mp3_stream
                self.stream_tasks[stream_id] = asyncio.create_task(
                    target(stream_id, int(message["device_id"]))
                )
            elif message_type == "audio_stop":
                await self._stop_stream(str(message["stream_id"]))

    async def connect_once(self) -> None:
        endpoint = self.settings.relay_url.rstrip("/") + "/_relay/streamer"
        headers = {"Authorization": f"Bearer {self.settings.relay_password}"}
        async with websockets.connect(
            endpoint, additional_headers=headers, max_size=None, ping_interval=20
        ) as socket:
            self.socket = socket
            await self.send_json(
                {
                    "type": "register",
                    "name": self.settings.device_name,
                    "password_hash": self.settings.password_hash,
                    "version": __version__,
                    "web": _web_files(),
                }
            )
            response = json.loads(await socket.recv())
            if response.get("type") != "registered":
                raise RuntimeError(response.get("message", "Relay registration failed"))
            print(
                f"Connected to {self.settings.relay_url} as "
                f"/{self.settings.device_name}"
            )
            receive_task = asyncio.create_task(self._receive())
            stop_task = asyncio.create_task(self.stop_event.wait())
            done, pending = await asyncio.wait(
                {receive_task, stop_task}, return_when=asyncio.FIRST_COMPLETED
            )
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
            for task in done:
                if task is receive_task:
                    task.result()

    async def run(self) -> None:
        self.audio.start()
        try:
            while not self.stop_event.is_set():
                try:
                    await self.connect_once()
                except (OSError, RuntimeError, websockets.ConnectionClosed) as exc:
                    if self.stop_event.is_set():
                        break
                    logger.warning("Relay connection failed: %s", exc)
                    print(f"Relay connection failed: {exc}. Retrying in 5 seconds.")
                    try:
                        await asyncio.wait_for(self.stop_event.wait(), timeout=5)
                    except TimeoutError:
                        pass
                finally:
                    for stream_id in list(self.stream_tasks):
                        await self._stop_stream(stream_id)
        finally:
            await self.audio.close()


def run_relay_client(settings: Settings) -> None:
    asyncio.run(RelayClient(settings).run())
