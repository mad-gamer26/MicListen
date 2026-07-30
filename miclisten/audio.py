from __future__ import annotations

import asyncio
import logging
import queue as thread_queue
import sys
from dataclasses import asdict, dataclass
from typing import Any

logger = logging.getLogger(__name__)
DEFAULT_INPUT_ID = -1
DEFAULT_OUTPUT_ID = -2


class AudioUnavailable(RuntimeError):
    """Raised when PortAudio cannot be loaded or initialized."""


class DeviceNotFound(LookupError):
    """Raised when a requested capture device is missing."""


@dataclass(frozen=True)
class DeviceInfo:
    id: int
    name: str
    kind: str
    channels: int
    sample_rate: int
    host_api: str
    is_default: bool = False
    target_name: str | None = None
    capture_id: int | None = None

    def to_dict(self) -> dict[str, Any]:
        result = asdict(self)
        result.pop("capture_id")
        return result


class CaptureSource:
    """A single PortAudio capture stream fanned out to several browser clients."""

    def __init__(self, backend: "AudioBackend", device: DeviceInfo, loop: asyncio.AbstractEventLoop):
        self.backend = backend
        self.device = device
        self.loop = loop
        self.subscribers: set[asyncio.Queue[bytes]] = set()
        self.native_subscribers: set[thread_queue.Queue[bytes]] = set()
        self.stream: Any = None

    def start(self) -> None:
        pyaudio = self.backend.module

        def callback(in_data: bytes, frame_count: int, time_info: Any, status: int):
            if status:
                logger.debug("PortAudio status %s for device %s", status, self.device.id)
            if in_data:
                self._broadcast_native(in_data)
                self.loop.call_soon_threadsafe(self._broadcast, in_data)
            return (None, pyaudio.paContinue)

        self.stream = self.backend.audio.open(
            format=pyaudio.paInt16,
            channels=self.device.channels,
            rate=self.device.sample_rate,
            input=True,
            input_device_index=(
                self.device.capture_id
                if self.device.capture_id is not None
                else self.device.id
            ),
            frames_per_buffer=1024,
            stream_callback=callback,
        )
        self.stream.start_stream()

    def _broadcast(self, data: bytes) -> None:
        for queue in tuple(self.subscribers):
            if queue.full():
                try:
                    queue.get_nowait()
                except asyncio.QueueEmpty:
                    pass
            try:
                queue.put_nowait(data)
            except asyncio.QueueFull:
                pass

    def _broadcast_native(self, data: bytes) -> None:
        for queue in tuple(self.native_subscribers):
            if queue.full():
                try:
                    queue.get_nowait()
                except thread_queue.Empty:
                    pass
            try:
                queue.put_nowait(data)
            except thread_queue.Full:
                pass

    def subscribe(self) -> asyncio.Queue[bytes]:
        queue: asyncio.Queue[bytes] = asyncio.Queue(maxsize=12)
        self.subscribers.add(queue)
        return queue

    def unsubscribe(self, queue: asyncio.Queue[bytes]) -> None:
        self.subscribers.discard(queue)

    def subscribe_native(self) -> thread_queue.Queue[bytes]:
        queue: thread_queue.Queue[bytes] = thread_queue.Queue(maxsize=12)
        self.native_subscribers.add(queue)
        return queue

    def unsubscribe_native(self, queue: thread_queue.Queue[bytes]) -> None:
        self.native_subscribers.discard(queue)

    def close(self) -> None:
        if self.stream is None:
            return
        try:
            if self.stream.is_active():
                self.stream.stop_stream()
        finally:
            self.stream.close()
            self.stream = None


class AudioBackend:
    def __init__(self) -> None:
        try:
            if sys.platform == "win32":
                import pyaudiowpatch as pyaudio
            else:
                import pyaudio
        except (ImportError, OSError) as exc:
            raise AudioUnavailable(f"Could not load the audio backend: {exc}") from exc

        self.module = pyaudio
        try:
            self.audio = pyaudio.PyAudio()
        except Exception as exc:
            raise AudioUnavailable(f"Could not initialize PortAudio: {exc}") from exc

    def list_devices(self) -> list[DeviceInfo]:
        if hasattr(self.module, "paWASAPI") and hasattr(
            self.audio, "get_default_wasapi_device"
        ):
            return self._list_wasapi_devices()

        default_input = -1
        try:
            default_input = int(self.audio.get_default_input_device_info()["index"])
        except (IOError, OSError):
            pass

        devices: list[DeviceInfo] = []
        for index in range(self.audio.get_device_count()):
            raw = self.audio.get_device_info_by_index(index)
            channels = int(raw.get("maxInputChannels", 0))
            if channels < 1:
                continue
            is_loopback = bool(raw.get("isLoopbackDevice", False))
            try:
                host = self.audio.get_host_api_info_by_index(int(raw["hostApi"]))["name"]
            except (KeyError, IOError, OSError):
                host = "Unknown"
            devices.append(
                DeviceInfo(
                    id=index,
                    name=str(raw.get("name", f"Device {index}")),
                    kind="output" if is_loopback else "input",
                    channels=min(channels, 2),
                    sample_rate=int(float(raw.get("defaultSampleRate", 48000))),
                    host_api=str(host),
                    is_default=index == default_input,
                )
            )
        return devices

    def _list_wasapi_devices(self) -> list[DeviceInfo]:
        try:
            wasapi = self.audio.get_host_api_info_by_type(self.module.paWASAPI)
        except OSError as exc:
            raise AudioUnavailable("Windows WASAPI is unavailable") from exc

        host_index = int(wasapi["index"])
        host_name = str(wasapi.get("name", "Windows WASAPI"))
        devices: list[DeviceInfo] = []

        def from_raw(
            raw: dict[str, Any],
            *,
            logical_id: int | None = None,
            logical_name: str | None = None,
            kind: str | None = None,
            is_default: bool = False,
        ) -> DeviceInfo:
            channels = int(raw.get("maxInputChannels", 0))
            is_loopback = bool(raw.get("isLoopbackDevice", False))
            return DeviceInfo(
                id=int(raw["index"]) if logical_id is None else logical_id,
                name=str(raw.get("name", "Audio device")) if logical_name is None else logical_name,
                kind=kind or ("output" if is_loopback else "input"),
                channels=min(max(channels, 1), 2),
                sample_rate=int(float(raw.get("defaultSampleRate", 48000))),
                host_api=host_name,
                is_default=is_default,
                target_name=str(raw.get("name", "Audio device")) if logical_id is not None else None,
                capture_id=int(raw["index"]) if logical_id is not None else None,
            )

        try:
            default_input = self.audio.get_default_wasapi_device(d_in=True)
            if int(default_input.get("maxInputChannels", 0)) > 0:
                devices.append(
                    from_raw(
                        default_input,
                        logical_id=DEFAULT_INPUT_ID,
                        logical_name="Default input device",
                        kind="input",
                        is_default=True,
                    )
                )
        except (OSError, LookupError):
            pass

        try:
            default_output = self.audio.get_default_wasapi_loopback()
            devices.append(
                from_raw(
                    default_output,
                    logical_id=DEFAULT_OUTPUT_ID,
                    logical_name="Default output device",
                    kind="output",
                    is_default=True,
                )
            )
        except (OSError, LookupError, ValueError):
            pass

        for index in range(self.audio.get_device_count()):
            raw = self.audio.get_device_info_by_index(index)
            if int(raw.get("hostApi", -1)) != host_index:
                continue
            if int(raw.get("maxInputChannels", 0)) < 1:
                continue
            devices.append(from_raw(raw))

        return devices

    def get_device(self, device_id: int) -> DeviceInfo:
        for device in self.list_devices():
            if device.id == device_id:
                return device
        raise DeviceNotFound(f"Audio device {device_id} was not found or cannot be captured")

    def close(self) -> None:
        self.audio.terminate()


class AudioManager:
    def __init__(self) -> None:
        self.backend: AudioBackend | None = None
        self.startup_error: str | None = None
        self.sources: dict[int, CaptureSource] = {}
        self.lock = asyncio.Lock()

    def start(self) -> None:
        if self.backend is not None:
            return
        try:
            self.backend = AudioBackend()
            self.startup_error = None
        except AudioUnavailable as exc:
            self.startup_error = str(exc)
            logger.warning("MicListen audio unavailable: %s", exc)

    def list_devices(self) -> list[DeviceInfo]:
        if self.backend is None:
            raise AudioUnavailable(self.startup_error or "Audio backend is not running")
        return self.backend.list_devices()

    async def subscribe(self, device_id: int) -> tuple[DeviceInfo, asyncio.Queue[bytes]]:
        if self.backend is None:
            raise AudioUnavailable(self.startup_error or "Audio backend is not running")
        async with self.lock:
            source = self.sources.get(device_id)
            if source is None:
                device = self.backend.get_device(device_id)
                source = CaptureSource(self.backend, device, asyncio.get_running_loop())
                try:
                    source.start()
                except Exception as exc:
                    raise AudioUnavailable(f"Could not open {device.name}: {exc}") from exc
                self.sources[device_id] = source
            return source.device, source.subscribe()

    async def subscribe_native(
        self, device_id: int
    ) -> tuple[DeviceInfo, thread_queue.Queue[bytes]]:
        if self.backend is None:
            raise AudioUnavailable(self.startup_error or "Audio backend is not running")
        async with self.lock:
            source = self.sources.get(device_id)
            if source is None:
                device = self.backend.get_device(device_id)
                source = CaptureSource(self.backend, device, asyncio.get_running_loop())
                try:
                    source.start()
                except Exception as exc:
                    raise AudioUnavailable(f"Could not open {device.name}: {exc}") from exc
                self.sources[device_id] = source
            return source.device, source.subscribe_native()

    async def unsubscribe(self, device_id: int, queue: asyncio.Queue[bytes]) -> None:
        async with self.lock:
            source = self.sources.get(device_id)
            if source is None:
                return
            source.unsubscribe(queue)
            if not source.subscribers and not source.native_subscribers:
                source.close()
                self.sources.pop(device_id, None)

    async def unsubscribe_native(
        self, device_id: int, queue: thread_queue.Queue[bytes]
    ) -> None:
        async with self.lock:
            source = self.sources.get(device_id)
            if source is None:
                return
            source.unsubscribe_native(queue)
            if not source.subscribers and not source.native_subscribers:
                source.close()
                self.sources.pop(device_id, None)

    async def close(self) -> None:
        async with self.lock:
            for source in self.sources.values():
                source.close()
            self.sources.clear()
            if self.backend is not None:
                self.backend.close()
                self.backend = None
