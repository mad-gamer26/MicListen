import asyncio
import queue

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from miclisten.app import app, audio_manager, native_audio_stream, set_shutdown_handler
from miclisten.audio import DeviceInfo


def test_index_and_device_api(monkeypatch):
    device = DeviceInfo(
        id=4,
        name="Test microphone",
        kind="input",
        channels=1,
        sample_rate=48000,
        host_api="Test API",
        is_default=True,
    )

    monkeypatch.setattr(audio_manager, "start", lambda: None)
    monkeypatch.setattr(audio_manager, "list_devices", lambda: [device])

    async def close():
        pass

    monkeypatch.setattr(audio_manager, "close", close)
    with TestClient(app) as client:
        response = client.get("/")
        assert response.status_code == 200
        assert "MicListen" in response.text
        assert "meter-row" not in response.text
        assert 'id="shutdown"' in response.text
        assert "LOCAL AUDIO MONITOR" not in response.text
        assert 'class="eyebrow"' not in response.text
        assert "Audio stays on your network" not in response.text
        assert 'id="device-filter"' in response.text
        assert '<option value="all">All</option>' in response.text
        assert "default-badge" not in response.text
        assert "device-meta" not in response.text

        response = client.get("/static/app.js")
        assert response.status_code == 200
        assert "createLegacyPCMPlayer" in response.text
        assert "Are you sure you wish to shut down MicListen?" in response.text

        response = client.get("/api/devices")
        assert response.status_code == 200
        assert response.json()["devices"][0]["name"] == "Test microphone"

        shutdown_requested = False

        def request_shutdown():
            nonlocal shutdown_requested
            shutdown_requested = True

        set_shutdown_handler(request_shutdown)
        response = client.post("/api/shutdown", headers={"origin": "http://testserver"})
        set_shutdown_handler(None)
        assert response.status_code == 200
        assert response.json() == {"status": "shutting_down"}
        assert shutdown_requested is True

        set_shutdown_handler(request_shutdown)
        response = client.post(
            "/api/shutdown", headers={"origin": "https://untrusted.example"}
        )
        set_shutdown_handler(None)
        assert response.status_code == 403

        with pytest.raises(WebSocketDisconnect) as rejected:
            with client.websocket_connect(
                "/ws/audio/4", headers={"origin": "https://untrusted.example"}
            ):
                pass
        assert rejected.value.code == 1008


def test_native_stream_starts_with_mp3_bytes(monkeypatch):
    device = DeviceInfo(
        id=4,
        name="Test microphone",
        kind="input",
        channels=1,
        sample_rate=48000,
        host_api="Test API",
    )
    audio_queue = queue.Queue()
    unsubscribed = False

    async def subscribe(device_id):
        assert device_id == 4
        return device, audio_queue

    async def unsubscribe(device_id, subscribed_queue):
        nonlocal unsubscribed
        assert device_id == 4
        assert subscribed_queue is audio_queue
        unsubscribed = True

    monkeypatch.setattr(audio_manager, "subscribe_native", subscribe)
    monkeypatch.setattr(audio_manager, "unsubscribe_native", unsubscribe)

    async def consume_first_chunk():
        response = await native_audio_stream(4)
        assert response.media_type == "audio/mpeg"
        first = await response.body_iterator.__anext__()
        await response.body_iterator.aclose()
        return first

    first = asyncio.run(consume_first_chunk())
    assert isinstance(first, bytes)
    assert first[0] == 0xFF and first[1] & 0xE0 == 0xE0
    assert unsubscribed is True
