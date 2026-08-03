from __future__ import annotations

import argparse
import asyncio
import base64
import configparser
from dataclasses import dataclass
import getpass
import hashlib
import hmac
import html
import json
import mimetypes
import os
from pathlib import Path
import re
import secrets
import sys
from typing import Any, AsyncIterator
from urllib.parse import parse_qs, quote, urlsplit
import uuid

import uvicorn
from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response, StreamingResponse

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8766
VERSION = "0.6"
NAME_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
AUTHENTICATION_WARNING = (
    "WARNING: Relay authentication is disabled. Anyone who can reach this server "
    "can discover connected streamers and may capture audio from their microphones. "
    "It is highly recommended that you configure a password."
)


@dataclass(frozen=True)
class ServerSettings:
    host: str = DEFAULT_HOST
    port: int = DEFAULT_PORT
    password_hash: str = ""


def config_path() -> Path:
    if sys.platform == "win32":
        root = Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming"))
    else:
        root = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return root / "MicListen Relay" / "config.ini"


def hash_password(password: str) -> str:
    if not password:
        return ""
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 310_000)
    return "pbkdf2_sha256$310000${}${}".format(
        base64.urlsafe_b64encode(salt).decode(),
        base64.urlsafe_b64encode(digest).decode(),
    )


def verify_password(password: str, encoded: str) -> bool:
    if not encoded:
        return password == ""
    try:
        algorithm, iterations, salt_text, digest_text = encoded.split("$", 3)
        if algorithm != "pbkdf2_sha256":
            return False
        salt = base64.urlsafe_b64decode(salt_text.encode())
        expected = base64.urlsafe_b64decode(digest_text.encode())
        actual = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, int(iterations))
    except (TypeError, ValueError):
        return False
    return hmac.compare_digest(actual, expected)


def _valid_password_hash(encoded: str) -> bool:
    if not encoded:
        return True
    try:
        algorithm, iterations, salt_text, digest_text = encoded.split("$", 3)
        return (
            algorithm == "pbkdf2_sha256"
            and int(iterations) >= 100_000
            and len(base64.urlsafe_b64decode(salt_text.encode())) >= 16
            and len(base64.urlsafe_b64decode(digest_text.encode())) == 32
        )
    except (TypeError, ValueError):
        return False


def _read_config() -> configparser.ConfigParser | None:
    path = config_path()
    parser = configparser.ConfigParser(interpolation=None)
    try:
        if not path.is_file() or path.stat().st_size == 0:
            return None
        with path.open("r", encoding="utf-8") as config_file:
            parser.read_file(config_file)
    except (OSError, configparser.Error):
        return None
    return parser


def configuration_is_valid() -> bool:
    parser = _read_config()
    if parser is None or not parser.has_section("server"):
        return False
    required = {"host", "port", "password_hash"}
    if not required.issubset(parser.options("server")):
        return False
    try:
        port = parser.getint("server", "port")
    except ValueError:
        return False
    return (
        bool(parser.get("server", "host").strip())
        and 1 <= port <= 65535
        and _valid_password_hash(parser.get("server", "password_hash"))
    )


def load_settings() -> ServerSettings:
    parser = _read_config()
    if parser is None:
        return ServerSettings()
    host = parser.get("server", "host", fallback=DEFAULT_HOST).strip() or DEFAULT_HOST
    try:
        port = parser.getint("server", "port", fallback=DEFAULT_PORT)
    except ValueError:
        port = DEFAULT_PORT
    if not 1 <= port <= 65535:
        port = DEFAULT_PORT
    return ServerSettings(
        host=host,
        port=port,
        password_hash=parser.get("server", "password_hash", fallback=""),
    )


def save_settings(settings: ServerSettings) -> Path:
    path = config_path()
    parser = configparser.ConfigParser(interpolation=None)
    parser["server"] = {
        "host": settings.host,
        "port": str(settings.port),
        "password_hash": settings.password_hash,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8") as config_file:
        parser.write(config_file)
    os.replace(temporary, path)
    return path


def run_configuration_wizard() -> ServerSettings:
    current = load_settings()
    print("MicListen Relay Server configuration")
    print("Press Enter to keep the value shown in brackets.")
    host = input(f"Bind host [{current.host}]: ").strip() or current.host
    while True:
        entered = input(f"Bind port [{current.port}]: ").strip()
        if not entered:
            port = current.port
            break
        try:
            port = int(entered)
        except ValueError:
            port = 0
        if 1 <= port <= 65535:
            break
        print("Port must be a number between 1 and 65535.")
    label = "Relay password"
    if current.password_hash:
        label += " [configured; Enter keeps it; type - to disable]"
    else:
        label += " [optional; Enter disables authentication]"
    entered_password = getpass.getpass(label + ": ")
    if entered_password == "-":
        password_hash = ""
    elif entered_password:
        password_hash = hash_password(entered_password)
    else:
        password_hash = current.password_hash
    settings = ServerSettings(host, port, password_hash)
    path = save_settings(settings)
    print(f"Configuration saved to {path}")
    print(f"Default address: http://{host}:{port}")
    return settings


class ConnectedStreamer:
    def __init__(
        self,
        name: str,
        websocket: WebSocket,
        password_hash: str,
        web_files: dict[str, str],
        version: str,
    ) -> None:
        self.name = name
        self.websocket = websocket
        self.password_hash = password_hash
        self.web_files = web_files
        self.version = version
        self.send_lock = asyncio.Lock()
        self.pending: dict[str, asyncio.Future] = {}
        self.streams: dict[str, asyncio.Queue[tuple[str, Any]]] = {}

    async def send(self, message: dict[str, Any]) -> None:
        async with self.send_lock:
            await self.websocket.send_json(message)

    async def request(self, action: str, timeout: float = 15) -> Any:
        request_id = uuid.uuid4().hex
        future = asyncio.get_running_loop().create_future()
        self.pending[request_id] = future
        try:
            await self.send({"type": "request", "id": request_id, "action": action})
            return await asyncio.wait_for(future, timeout)
        finally:
            self.pending.pop(request_id, None)

    async def start_stream(self, device_id: int, native: bool = False):
        stream_id = str(uuid.uuid4())
        queue: asyncio.Queue[tuple[str, Any]] = asyncio.Queue(maxsize=24)
        self.streams[stream_id] = queue
        await self.send(
            {
                "type": "native_start" if native else "audio_start",
                "stream_id": stream_id,
                "device_id": device_id,
            }
        )
        return stream_id, queue

    async def stop_stream(self, stream_id: str) -> None:
        self.streams.pop(stream_id, None)
        try:
            await self.send({"type": "audio_stop", "stream_id": stream_id})
        except (RuntimeError, WebSocketDisconnect):
            pass

    def close(self, reason: str) -> None:
        for future in self.pending.values():
            if not future.done():
                future.set_exception(RuntimeError(reason))
        for queue in self.streams.values():
            try:
                queue.put_nowait(("error", reason))
            except asyncio.QueueFull:
                pass


app = FastAPI(title="MicListen Relay")
streamers: dict[str, ConnectedStreamer] = {}
streamers_lock = asyncio.Lock()
relay_password_hash = ""
session_secret = secrets.token_bytes(32)


def configure_app(settings: ServerSettings) -> None:
    global relay_password_hash
    relay_password_hash = settings.password_hash


def _relay_token() -> str:
    return hmac.new(session_secret, relay_password_hash.encode(), hashlib.sha256).hexdigest()


def _device_cookie_name(name: str) -> str:
    return "miclisten_device_" + name.replace("-", "_")


def _device_token(streamer: ConnectedStreamer) -> str:
    payload = f"{streamer.name}|{streamer.password_hash}".encode()
    return hmac.new(session_secret, payload, hashlib.sha256).hexdigest()


def _relay_authenticated_from_cookies(cookies: dict[str, str]) -> bool:
    if not relay_password_hash:
        return True
    return hmac.compare_digest(cookies.get("miclisten_relay", ""), _relay_token())


def _device_authenticated_from_cookies(
    streamer: ConnectedStreamer, cookies: dict[str, str]
) -> bool:
    if not streamer.password_hash:
        return True
    return hmac.compare_digest(
        cookies.get(_device_cookie_name(streamer.name), ""), _device_token(streamer)
    )


@app.middleware("http")
async def require_relay_login(request: Request, call_next):
    if request.url.path == "/login":
        return await call_next(request)
    if _relay_authenticated_from_cookies(request.cookies):
        return await call_next(request)
    if "/api/" in request.url.path or "/stream/" in request.url.path:
        return JSONResponse({"detail": "Relay authentication required"}, status_code=401)
    destination = quote(request.url.path, safe="/")
    return RedirectResponse(f"/login?next={destination}", status_code=303)


def _login_html(title: str, message: str, destination: str) -> str:
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>{html.escape(title)}</title>
<style>body{{font:16px system-ui;background:#081312;color:#eef8f4;display:grid;place-items:center;min-height:100vh;margin:0}}form{{width:min(360px,calc(100% - 40px));padding:28px;background:#10211f;border:1px solid #25403b;border-radius:16px}}input,button{{box-sizing:border-box;width:100%;padding:12px;margin-top:12px;border-radius:9px}}input{{background:#081312;color:white;border:1px solid #36534d}}button{{border:0;background:#58e6a9;color:#062118;font-weight:700}}</style></head>
<body><form method="post"><h1>{html.escape(title)}</h1><p>{html.escape(message)}</p>
<input type="password" name="password" autofocus required><input type="hidden" name="next" value="{html.escape(destination, quote=True)}">
<button type="submit">Continue</button></form></body></html>"""


@app.get("/login", include_in_schema=False)
async def relay_login_page(next: str = "/") -> HTMLResponse:
    destination = next if next.startswith("/") and not next.startswith("//") else "/"
    return HTMLResponse(_login_html("MicListen Relay", "Enter the relay password.", destination))


@app.post("/login", include_in_schema=False)
async def relay_login(request: Request):
    fields = parse_qs((await request.body()).decode("utf-8", "replace"))
    destination = fields.get("next", ["/"])[0]
    if not destination.startswith("/") or destination.startswith("//"):
        destination = "/"
    if not verify_password(fields.get("password", [""])[0], relay_password_hash):
        return HTMLResponse("Incorrect password. Go back and try again.", status_code=401)
    response = RedirectResponse(destination, status_code=303)
    response.set_cookie(
        "miclisten_relay", _relay_token(), httponly=True,
        secure=request.url.scheme == "https", samesite="strict"
    )
    return response


@app.get("/", include_in_schema=False)
async def index() -> HTMLResponse:
    async with streamers_lock:
        names = sorted(streamers)
    buttons = "".join(
        f'<a href="/{html.escape(name, quote=True)}/">{html.escape(name)}</a>' for name in names
    ) or "<p>No streamers are currently connected.</p>"
    return HTMLResponse(f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>MicListen Relay</title>
<style>body{{font:16px system-ui;background:#081312;color:#eef8f4;margin:0}}main{{width:min(720px,calc(100% - 40px));margin:64px auto}}.devices{{display:grid;gap:12px}}a{{padding:18px;border:1px solid #25403b;border-radius:14px;background:#10211f;color:#58e6a9;text-decoration:none;font-weight:700}}p{{color:#8da9a2}}</style></head>
<body><main><h1>MicListen Relay</h1><p>Select a connected streamer.</p><div class="devices">{buttons}</div><p>Version {VERSION}</p></main></body></html>""")


@app.get("/api/health")
async def relay_health() -> dict[str, Any]:
    return {"status": "ok", "version": VERSION, "connected_streamers": len(streamers), "authentication": bool(relay_password_hash)}


async def _get_streamer(name: str) -> ConnectedStreamer:
    streamer = streamers.get(name)
    if streamer is None:
        raise HTTPException(status_code=404, detail="Streamer is not connected")
    return streamer


async def _require_device(request: Request, name: str) -> ConnectedStreamer:
    streamer = await _get_streamer(name)
    if not _device_authenticated_from_cookies(streamer, request.cookies):
        raise HTTPException(status_code=401, detail="Streamer authentication required")
    return streamer


@app.get("/{name}/login", include_in_schema=False)
async def device_login_page(name: str, next: str | None = None) -> HTMLResponse:
    streamer = await _get_streamer(name)
    destination = next or f"/{name}/"
    if not destination.startswith(f"/{name}/"):
        destination = f"/{name}/"
    return HTMLResponse(_login_html("MicListen", f"Enter the password for {name}.", destination))


@app.post("/{name}/login", include_in_schema=False)
async def device_login(name: str, request: Request):
    streamer = await _get_streamer(name)
    fields = parse_qs((await request.body()).decode("utf-8", "replace"))
    if not verify_password(fields.get("password", [""])[0], streamer.password_hash):
        return HTMLResponse("Incorrect password. Go back and try again.", status_code=401)
    destination = fields.get("next", [f"/{name}/"])[0]
    if not destination.startswith(f"/{name}/"):
        destination = f"/{name}/"
    response = RedirectResponse(destination, status_code=303)
    response.set_cookie(
        _device_cookie_name(name), _device_token(streamer), path=f"/{name}",
        httponly=True, secure=request.url.scheme == "https", samesite="strict"
    )
    return response


def _device_login_redirect(name: str, destination: str) -> RedirectResponse:
    return RedirectResponse(
        f"/{name}/login?next={quote(destination, safe='/')}", status_code=303
    )


@app.get("/{name}/", include_in_schema=False)
async def device_index(name: str, request: Request):
    streamer = await _get_streamer(name)
    if not _device_authenticated_from_cookies(streamer, request.cookies):
        return _device_login_redirect(name, f"/{name}/")
    content = streamer.web_files.get("index.html")
    if content is None:
        raise HTTPException(status_code=503, detail="Streamer did not provide its web interface")
    return HTMLResponse(content)


@app.get("/{name}/static/{filename}", include_in_schema=False)
async def device_static(name: str, filename: str, request: Request):
    streamer = await _require_device(request, name)
    if filename not in {"app.js", "styles.css", "audio-processor.js"}:
        raise HTTPException(status_code=404)
    content = streamer.web_files.get(filename)
    if content is None:
        raise HTTPException(status_code=404)
    media_type = mimetypes.guess_type(filename)[0] or "application/octet-stream"
    return Response(content, media_type=media_type, headers={"Cache-Control": "no-store"})


@app.get("/{name}/api/devices")
async def device_list(name: str, request: Request):
    streamer = await _require_device(request, name)
    try:
        return await streamer.request("devices")
    except (RuntimeError, TimeoutError) as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.get("/{name}/api/health")
async def device_health(name: str, request: Request):
    streamer = await _require_device(request, name)
    try:
        return await streamer.request("health")
    except (RuntimeError, TimeoutError) as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.post("/{name}/api/shutdown")
async def device_shutdown(name: str, request: Request):
    streamer = await _require_device(request, name)
    origin = request.headers.get("origin")
    host = request.headers.get("host", "")
    if origin and urlsplit(origin).netloc.lower() != host.lower():
        raise HTTPException(status_code=403, detail="Cross-origin shutdown is not allowed")
    try:
        return await streamer.request("shutdown")
    except (RuntimeError, TimeoutError) as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.websocket("/{name}/ws/audio/{device_id}")
async def device_audio(websocket: WebSocket, name: str, device_id: int) -> None:
    streamer = streamers.get(name)
    origin = websocket.headers.get("origin")
    host = websocket.headers.get("host", "")
    if (
        streamer is None
        or (origin and urlsplit(origin).netloc.lower() != host.lower())
        or not _relay_authenticated_from_cookies(websocket.cookies)
        or not _device_authenticated_from_cookies(streamer, websocket.cookies)
    ):
        await websocket.close(code=4401, reason="Authentication required")
        return
    await websocket.accept()
    stream_id = ""
    try:
        stream_id, queue = await streamer.start_stream(device_id)
        while True:
            kind, payload = await queue.get()
            if kind == "json":
                await websocket.send_json(payload)
            elif kind == "audio":
                await websocket.send_bytes(payload)
            else:
                await websocket.send_json({"type": "error", "message": payload})
                await websocket.close(code=1011)
                break
    except (WebSocketDisconnect, RuntimeError):
        pass
    finally:
        if stream_id:
            await streamer.stop_stream(stream_id)


@app.get("/{name}/stream/audio/{device_id}.mp3", include_in_schema=False)
async def device_native_audio(name: str, device_id: int, request: Request):
    streamer = await _require_device(request, name)
    stream_id, queue = await streamer.start_stream(device_id, native=True)

    async def content() -> AsyncIterator[bytes]:
        try:
            while True:
                kind, payload = await queue.get()
                if kind == "audio":
                    yield payload
                elif kind == "error":
                    break
        finally:
            await streamer.stop_stream(stream_id)

    return StreamingResponse(
        content(), media_type="audio/mpeg",
        headers={"Cache-Control": "no-store", "Accept-Ranges": "none"}
    )


@app.websocket("/_relay/streamer")
async def streamer_connection(websocket: WebSocket) -> None:
    authorization = websocket.headers.get("authorization", "")
    supplied = authorization[7:] if authorization.startswith("Bearer ") else ""
    if relay_password_hash and not verify_password(supplied, relay_password_hash):
        await websocket.close(code=4401, reason="Invalid relay password")
        return
    await websocket.accept()
    streamer: ConnectedStreamer | None = None
    try:
        registration = await websocket.receive_json()
        name = str(registration.get("name", "")).lower()
        web_files = registration.get("web")
        if (
            registration.get("type") != "register"
            or not NAME_PATTERN.fullmatch(name)
            or not isinstance(web_files, dict)
        ):
            await websocket.send_json({"type": "error", "message": "Invalid registration"})
            await websocket.close(code=1008)
            return
        streamer = ConnectedStreamer(
            name, websocket, str(registration.get("password_hash", "")),
            {str(key): str(value) for key, value in web_files.items()},
            str(registration.get("version", "unknown")),
        )
        async with streamers_lock:
            previous = streamers.get(name)
            streamers[name] = streamer
        if previous is not None:
            previous.close("A newer connection replaced this streamer")
            await previous.websocket.close(code=1012)
        await websocket.send_json({"type": "registered", "path": f"/{name}/"})
        while True:
            message = await websocket.receive()
            if message.get("text") is not None:
                payload = json.loads(message["text"])
                message_type = payload.get("type")
                if message_type == "response":
                    future = streamer.pending.get(str(payload.get("id", "")))
                    if future is not None and not future.done():
                        if payload.get("ok"):
                            future.set_result(payload.get("result"))
                        else:
                            future.set_exception(RuntimeError(payload.get("error", "Request failed")))
                elif message_type in {"stream_format", "stream_error"}:
                    queue = streamer.streams.get(str(payload.get("stream_id", "")))
                    if queue is not None:
                        kind = "json" if message_type == "stream_format" else "error"
                        value = payload.get("format") if kind == "json" else payload.get("message")
                        await queue.put((kind, value))
            elif message.get("bytes") is not None:
                raw = message["bytes"]
                if len(raw) < 36:
                    continue
                stream_id = raw[:36].decode("ascii", "ignore")
                queue = streamer.streams.get(stream_id)
                if queue is not None:
                    if queue.full():
                        try:
                            queue.get_nowait()
                        except asyncio.QueueEmpty:
                            pass
                    await queue.put(("audio", raw[36:]))
            else:
                break
    except (WebSocketDisconnect, RuntimeError, json.JSONDecodeError):
        pass
    finally:
        if streamer is not None:
            streamer.close("Streamer disconnected")
            async with streamers_lock:
                if streamers.get(streamer.name) is streamer:
                    streamers.pop(streamer.name, None)


def main() -> None:
    parser = argparse.ArgumentParser(description="MicListen relay server")
    parser.add_argument("--host", help="Address to bind")
    parser.add_argument("--port", type=int, help="Port to bind")
    parser.add_argument("-c", "--configure", action="store_true", help="Run configuration wizard")
    args = parser.parse_args()
    if args.configure:
        if args.host or args.port:
            parser.error("--configure cannot be combined with --host or --port")
        run_configuration_wizard()
        return
    if not configuration_is_valid():
        print("You must configure MicListen Relay Server before using it for the first time.")
        answer = input(
            "Would you like to run the interactive configuration wizard? [y/N]: "
        ).strip().lower()
        if answer not in {"y", "yes"}:
            print("Aborting.")
            raise SystemExit(1)
        run_configuration_wizard()
    settings = load_settings()
    if not settings.password_hash:
        print(AUTHENTICATION_WARNING, file=sys.stderr)
    configure_app(settings)
    uvicorn.run(app, host=args.host or settings.host, port=args.port or settings.port)


if __name__ == "__main__":
    main()
