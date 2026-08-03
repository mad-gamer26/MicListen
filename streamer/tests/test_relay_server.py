from fastapi.testclient import TestClient

from server import server as relay


class FakeWebSocket:
    async def send_json(self, message):
        pass


def test_relay_home_lists_connected_streamer_and_device_login():
    streamer = relay.ConnectedStreamer(
        "matthews-hp",
        FakeWebSocket(),
        relay.hash_password("device secret"),
        {"index.html": "<h1>Streamer interface</h1>"},
        "0.6",
    )
    relay.configure_app(relay.ServerSettings())
    relay.streamers[streamer.name] = streamer
    try:
        with TestClient(relay.app) as client:
            response = client.get("/")
            assert response.status_code == 200
            assert 'href="/matthews-hp/"' in response.text
            assert "Version 0.6" in response.text

            response = client.get("/matthews-hp/", follow_redirects=False)
            assert response.status_code == 303
            assert response.headers["location"].startswith("/matthews-hp/login")

            response = client.post(
                "/matthews-hp/login",
                data={"password": "device secret", "next": "/matthews-hp/"},
                follow_redirects=False,
            )
            assert response.status_code == 303
            response = client.get("/matthews-hp/")
            assert response.status_code == 200
            assert "Streamer interface" in response.text
    finally:
        relay.streamers.clear()


def test_relay_password_protects_device_list():
    settings = relay.ServerSettings(password_hash=relay.hash_password("relay secret"))
    relay.configure_app(settings)
    try:
        with TestClient(relay.app) as client:
            assert client.get("/", follow_redirects=False).status_code == 303
            response = client.post(
                "/login", data={"password": "relay secret", "next": "/"},
                follow_redirects=False,
            )
            assert response.status_code == 303
            assert client.get("/").status_code == 200
    finally:
        relay.configure_app(relay.ServerSettings())


def test_streamer_registration_publishes_interface():
    relay.configure_app(relay.ServerSettings())
    registration = {
        "type": "register",
        "name": "studio-pc",
        "password_hash": "",
        "version": "0.6",
        "web": {
            "index.html": "<h1>Live streamer</h1>",
            "app.js": "console.log('relay');",
            "styles.css": "body{}",
            "audio-processor.js": "",
        },
    }
    with TestClient(relay.app) as client:
        with client.websocket_connect("/_relay/streamer") as websocket:
            websocket.send_json(registration)
            assert websocket.receive_json() == {
                "type": "registered",
                "path": "/studio-pc/",
            }
            assert "studio-pc" in client.get("/").text
            assert "Live streamer" in client.get("/studio-pc/").text
            static = client.get("/studio-pc/static/app.js")
            assert static.status_code == 200
            assert "relay" in static.text

            with client.websocket_connect("/studio-pc/ws/audio/4") as browser:
                start = websocket.receive_json()
                assert start["type"] == "audio_start"
                assert start["device_id"] == 4
                stream_id = start["stream_id"]
                audio_format = {
                    "type": "format",
                    "encoding": "pcm_s16le",
                    "sampleRate": 48000,
                    "channels": 1,
                }
                websocket.send_json(
                    {
                        "type": "stream_format",
                        "stream_id": stream_id,
                        "format": audio_format,
                    }
                )
                assert browser.receive_json() == audio_format
                websocket.send_bytes(stream_id.encode("ascii") + b"\x01\x02")
                assert browser.receive_bytes() == b"\x01\x02"
    relay.streamers.clear()
