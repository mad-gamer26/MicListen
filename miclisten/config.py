from __future__ import annotations

import configparser
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765


@dataclass(frozen=True)
class Settings:
    host: str = DEFAULT_HOST
    port: int = DEFAULT_PORT


def config_path() -> Path:
    """Return the per-user MicListen INI path."""
    if sys.platform == "win32":
        app_data = os.environ.get("APPDATA")
        root = Path(app_data) if app_data else Path.home() / "AppData" / "Roaming"
    else:
        root = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return root / "MicListen" / "config.ini"


def load_settings(path: Path | None = None) -> Settings:
    path = path or config_path()
    parser = configparser.ConfigParser(interpolation=None)
    try:
        parser.read(path, encoding="utf-8")
    except (OSError, configparser.Error):
        return Settings()

    host = parser.get("defaults", "host", fallback=DEFAULT_HOST).strip()
    if not host:
        host = DEFAULT_HOST

    try:
        port = parser.getint("defaults", "port", fallback=DEFAULT_PORT)
    except ValueError:
        port = DEFAULT_PORT
    if not 1 <= port <= 65535:
        port = DEFAULT_PORT
    return Settings(host=host, port=port)


def save_settings(settings: Settings, path: Path | None = None) -> Path:
    path = path or config_path()
    parser = configparser.ConfigParser(interpolation=None)
    if path.exists():
        try:
            parser.read(path, encoding="utf-8")
        except (OSError, configparser.Error):
            parser = configparser.ConfigParser(interpolation=None)
    if not parser.has_section("defaults"):
        parser.add_section("defaults")
    parser.set("defaults", "host", settings.host)
    parser.set("defaults", "port", str(settings.port))

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
    output_func: Callable[[str], None] | None = None,
) -> Settings:
    input_func = input_func or input
    output_func = output_func or print
    path = path or config_path()
    current = load_settings(path)

    output_func("MicListen configuration")
    output_func("Press Enter to keep the value shown in brackets.")

    while True:
        host = input_func(f"Default host [{current.host}]: ").strip() or current.host
        if host:
            break
        output_func("Host cannot be empty.")

    while True:
        entered_port = input_func(f"Default port [{current.port}]: ").strip()
        if not entered_port:
            port = current.port
            break
        try:
            port = int(entered_port)
        except ValueError:
            output_func("Port must be a number between 1 and 65535.")
            continue
        if 1 <= port <= 65535:
            break
        output_func("Port must be a number between 1 and 65535.")

    settings = Settings(host=host, port=port)
    saved_path = save_settings(settings, path)
    output_func(f"Configuration saved to {saved_path}")
    output_func(f"Default address: http://{host}:{port}")
    return settings

