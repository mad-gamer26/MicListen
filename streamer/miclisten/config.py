from __future__ import annotations

import base64
import configparser
import getpass
import hashlib
import hmac
import os
import re
import secrets
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable
from urllib.parse import urlsplit

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765
DEFAULT_RELAY_URL = "wss://miclisten.mad-gamer.com"
MODE_SERVER = "server"
MODE_CLIENT = "client"
DEVICE_NAME_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")


@dataclass(frozen=True)
class Settings:
    mode: str = MODE_SERVER
    host: str = DEFAULT_HOST
    port: int = DEFAULT_PORT
    device_name: str = ""
    relay_url: str = DEFAULT_RELAY_URL
    relay_password: str = ""
    password_hash: str = ""


def config_path() -> Path:
    """Return the per-user MicListen INI path."""
    if sys.platform == "win32":
        app_data = os.environ.get("APPDATA")
        root = Path(app_data) if app_data else Path.home() / "AppData" / "Roaming"
    else:
        root = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return root / "MicListen" / "config.ini"


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
        actual = hashlib.pbkdf2_hmac(
            "sha256", password.encode(), salt, int(iterations)
        )
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


def _read_parser(path: Path) -> configparser.ConfigParser | None:
    parser = configparser.ConfigParser(interpolation=None)
    try:
        if not path.is_file() or path.stat().st_size == 0:
            return None
        with path.open("r", encoding="utf-8") as config_file:
            parser.read_file(config_file)
    except (OSError, configparser.Error):
        return None
    return parser


def _valid_port(value: str) -> bool:
    try:
        return 1 <= int(value) <= 65535
    except ValueError:
        return False


def configuration_is_valid(path: Path | None = None) -> bool:
    parser = _read_parser(path or config_path())
    if parser is None or not parser.has_section("miclisten"):
        return False
    if not parser.has_option("miclisten", "mode") or not parser.has_option(
        "miclisten", "password_hash"
    ):
        return False
    mode = parser.get("miclisten", "mode").strip().lower()
    if not _valid_password_hash(parser.get("miclisten", "password_hash")):
        return False
    if mode == MODE_SERVER:
        return (
            parser.has_section("server")
            and bool(parser.get("server", "host", fallback="").strip())
            and _valid_port(parser.get("server", "port", fallback=""))
        )
    if mode == MODE_CLIENT:
        if not parser.has_section("relay"):
            return False
        name = parser.get("relay", "device_name", fallback="").strip().lower()
        relay_url = parser.get("relay", "url", fallback="").strip()
        scheme = urlsplit(relay_url).scheme.lower()
        return (
            bool(DEVICE_NAME_PATTERN.fullmatch(name))
            and scheme in {"ws", "wss"}
            and bool(urlsplit(relay_url).netloc)
            and parser.has_option("relay", "password")
        )
    return False


def load_settings(path: Path | None = None) -> Settings:
    parser = _read_parser(path or config_path())
    if parser is None:
        return Settings()
    mode = parser.get("miclisten", "mode", fallback=MODE_SERVER).strip().lower()
    if mode not in {MODE_SERVER, MODE_CLIENT}:
        mode = MODE_SERVER
    host = parser.get("server", "host", fallback=DEFAULT_HOST).strip() or DEFAULT_HOST
    try:
        port = parser.getint("server", "port", fallback=DEFAULT_PORT)
    except ValueError:
        port = DEFAULT_PORT
    if not 1 <= port <= 65535:
        port = DEFAULT_PORT
    return Settings(
        mode=mode,
        host=host,
        port=port,
        device_name=parser.get("relay", "device_name", fallback="").strip().lower(),
        relay_url=parser.get("relay", "url", fallback=DEFAULT_RELAY_URL).strip()
        or DEFAULT_RELAY_URL,
        relay_password=parser.get("relay", "password", fallback=""),
        password_hash=parser.get("miclisten", "password_hash", fallback=""),
    )


def save_settings(settings: Settings, path: Path | None = None) -> Path:
    path = path or config_path()
    parser = configparser.ConfigParser(interpolation=None)
    parser["miclisten"] = {
        "mode": settings.mode,
        "password_hash": settings.password_hash,
    }
    if settings.mode == MODE_SERVER:
        parser["server"] = {"host": settings.host, "port": str(settings.port)}
    else:
        parser["relay"] = {
            "device_name": settings.device_name,
            "url": settings.relay_url,
            "password": settings.relay_password,
        }
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f"{path.name}.tmp")
    with temporary.open("w", encoding="utf-8") as config_file:
        parser.write(config_file)
    os.replace(temporary, path)
    return path


def run_configuration_wizard(
    *,
    path: Path | None = None,
    input_func: Callable[[str], str] | None = None,
    password_func: Callable[[str], str] | None = None,
    output_func: Callable[[str], None] | None = None,
) -> Settings:
    input_func = input_func or input
    password_func = password_func or getpass.getpass
    output_func = output_func or print
    path = path or config_path()
    current = load_settings(path)

    output_func("MicListen configuration")
    output_func("Press Enter to keep the value shown in brackets.")
    while True:
        mode = (
            input_func(f"Mode (server/client) [{current.mode}]: ").strip().lower()
            or current.mode
        )
        if mode in {MODE_SERVER, MODE_CLIENT}:
            break
        output_func("Mode must be 'server' or 'client'.")

    host, port = current.host, current.port
    device_name, relay_url, relay_password = (
        current.device_name,
        current.relay_url,
        current.relay_password,
    )
    if mode == MODE_SERVER:
        while True:
            host = input_func(f"Bind host [{current.host}]: ").strip() or current.host
            if host:
                break
            output_func("Host cannot be empty.")
        while True:
            entered = input_func(f"Bind port [{current.port}]: ").strip()
            if not entered:
                port = current.port
                break
            if _valid_port(entered):
                port = int(entered)
                break
            output_func("Port must be a number between 1 and 65535.")
    else:
        suggested_name = current.device_name or "my-computer"
        while True:
            device_name = (
                input_func(f"Device name [{suggested_name}]: ").strip().lower()
                or suggested_name
            )
            if DEVICE_NAME_PATTERN.fullmatch(device_name):
                break
            output_func("Use lowercase letters, numbers, and single hyphens only.")
        while True:
            relay_url = (
                input_func(f"Relay WebSocket URL [{current.relay_url}]: ").strip()
                or current.relay_url
            ).rstrip("/")
            parsed = urlsplit(relay_url)
            if parsed.scheme in {"ws", "wss"} and parsed.netloc:
                break
            output_func("Relay URL must start with ws:// or wss://.")
        relay_prompt = "Relay password"
        if current.relay_password:
            relay_prompt += " [configured; Enter keeps it; type - to disable]"
        else:
            relay_prompt += " [none]"
        entered_relay_password = password_func(f"{relay_prompt}: ")
        if entered_relay_password == "-":
            relay_password = ""
        else:
            relay_password = entered_relay_password or current.relay_password

    password_prompt = "Streamer password"
    if current.password_hash:
        password_prompt += " [configured; Enter keeps it; type - to disable]"
    else:
        password_prompt += " [optional; Enter disables authentication]"
    entered_password = password_func(f"{password_prompt}: ")
    if entered_password == "-":
        password_hash = ""
    elif entered_password:
        password_hash = hash_password(entered_password)
    else:
        password_hash = current.password_hash

    settings = Settings(
        mode=mode,
        host=host,
        port=port,
        device_name=device_name,
        relay_url=relay_url,
        relay_password=relay_password,
        password_hash=password_hash,
    )
    saved_path = save_settings(settings, path)
    output_func(f"Configuration saved to {saved_path}")
    if mode == MODE_SERVER:
        output_func(f"Default address: http://{host}:{port}")
    else:
        output_func(f"Relay device path: /{device_name}")
    return settings
