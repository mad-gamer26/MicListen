from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys
import time

import uvicorn

from .config import (
    MODE_CLIENT,
    configuration_is_valid,
    load_settings,
    run_configuration_wizard,
)

AUTHENTICATION_WARNING = (
    "WARNING: Authentication is disabled. Anyone who can reach MicListen could "
    "capture audio from this computer's microphone. It is highly recommended "
    "that you configure a password."
)


def _log_path() -> Path:
    if sys.platform == "win32":
        root = Path(os.environ.get("LOCALAPPDATA", Path.home()))
        return root / "MicListen" / "miclisten.log"
    return Path.home() / ".local" / "state" / "miclisten" / "miclisten.log"


def launch_background(arguments: list[str], description: str) -> tuple[int, Path]:
    """Start a detached MicListen child and return its PID and log path."""
    log_path = _log_path()
    log_path.parent.mkdir(parents=True, exist_ok=True)
    command = [sys.executable, "-m", "miclisten", *arguments]
    options: dict = {
        "stdin": subprocess.DEVNULL,
        "stderr": subprocess.STDOUT,
        "close_fds": True,
    }
    if sys.platform == "win32":
        options["creationflags"] = (
            subprocess.CREATE_NO_WINDOW
            | subprocess.DETACHED_PROCESS
            | subprocess.CREATE_NEW_PROCESS_GROUP
        )
    else:
        options["start_new_session"] = True

    with log_path.open("a", encoding="utf-8") as log:
        log.write(f"\n--- Starting MicListen {description} ---\n")
        log.flush()
        process = subprocess.Popen(command, stdout=log, **options)
    time.sleep(0.4)
    return_code = process.poll()
    if return_code is not None:
        raise RuntimeError(
            f"MicListen exited during startup with code {return_code}. See {log_path}"
        )
    return process.pid, log_path


def _configuration_required() -> None:
    print("You must configure MicListen before using it for the first time.")
    answer = input(
        "Would you like to run the interactive configuration wizard? [y/N]: "
    ).strip().lower()
    if answer not in {"y", "yes"}:
        print("Aborting.")
        raise SystemExit(1)
    run_configuration_wizard()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Stream local audio directly or through a MicListen relay"
    )
    parser.add_argument("--host", help="Address to bind in server mode")
    parser.add_argument("--port", type=int, help="Port to bind in server mode")
    parser.add_argument(
        "-b", "--background", action="store_true", help="Run detached without a console"
    )
    parser.add_argument(
        "-c", "--configure", action="store_true", help="Run the configuration wizard"
    )
    parser.add_argument("--reload", action="store_true", help="Reload server-mode source")
    args = parser.parse_args()

    if args.configure:
        if args.background or args.reload or args.host or args.port:
            parser.error("--configure cannot be combined with runtime options")
        run_configuration_wizard()
        return
    if not configuration_is_valid():
        _configuration_required()

    settings = load_settings()
    if not settings.password_hash:
        print(AUTHENTICATION_WARNING, file=sys.stderr)

    if settings.mode == MODE_CLIENT and (args.host or args.port or args.reload):
        parser.error("--host, --port, and --reload are only available in server mode")
    if args.background:
        child_arguments: list[str] = []
        description = "relay client"
        if settings.mode != MODE_CLIENT:
            host = args.host or settings.host
            port = args.port or settings.port
            child_arguments = ["--host", host, "--port", str(port)]
            description = f"server on {host}:{port}"
        try:
            pid, log_path = launch_background(child_arguments, description)
        except (OSError, RuntimeError) as exc:
            parser.error(str(exc))
        print(f"MicListen started in the background (PID {pid}).")
        print(f"Log: {log_path}")
        return

    if settings.mode == MODE_CLIENT:
        from .relay import run_relay_client

        try:
            run_relay_client(settings)
        except KeyboardInterrupt:
            pass
        return

    host = args.host or settings.host
    port = args.port or settings.port
    if args.reload:
        os.environ["MICLISTEN_PASSWORD_HASH"] = settings.password_hash
        uvicorn.run("miclisten.app:app", host=host, port=port, reload=True)
        return

    from .app import app, configure_authentication, set_shutdown_handler

    configure_authentication(settings.password_hash)
    config = uvicorn.Config(app, host=host, port=port)
    server = uvicorn.Server(config)
    set_shutdown_handler(lambda: setattr(server, "should_exit", True))
    try:
        server.run()
    finally:
        set_shutdown_handler(None)


if __name__ == "__main__":
    main()
