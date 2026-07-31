from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys
import time

import uvicorn

from .config import load_settings, run_configuration_wizard


def _log_path() -> Path:
    if sys.platform == "win32":
        root = Path(os.environ.get("LOCALAPPDATA", Path.home()))
        return root / "MicListen" / "miclisten.log"
    return Path.home() / ".local" / "state" / "miclisten" / "miclisten.log"


def _server_command(host: str, port: int) -> list[str]:
    """Return the command used to start a detached server process."""
    command = [sys.executable]
    if not getattr(sys, "frozen", False):
        command.extend(["-m", "miclisten"])
    command.extend(["--host", host, "--port", str(port)])
    return command


def launch_background(host: str, port: int) -> tuple[int, Path]:
    """Start a detached MicListen child and return its PID and log path."""
    log_path = _log_path()
    log_path.parent.mkdir(parents=True, exist_ok=True)
    command = _server_command(host, port)
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
        log.write(f"\n--- Starting MicListen on {host}:{port} ---\n")
        log.flush()
        process = subprocess.Popen(command, stdout=log, **options)

    # Catch immediate failures such as an invalid bind address or occupied port.
    time.sleep(0.4)
    return_code = process.poll()
    if return_code is not None:
        raise RuntimeError(
            f"MicListen exited during startup with code {return_code}. "
            f"See {log_path}"
        )
    return process.pid, log_path


def main() -> None:
    settings = load_settings()
    parser = argparse.ArgumentParser(description="Stream local audio devices to a web browser")
    parser.add_argument(
        "--host",
        default=settings.host,
        help=f"Address to bind (default: {settings.host})",
    )
    parser.add_argument(
        "--port",
        default=settings.port,
        type=int,
        help=f"Port to bind (default: {settings.port})",
    )
    parser.add_argument(
        "-b",
        "--background",
        action="store_true",
        help="Run detached without a console window",
    )
    parser.add_argument(
        "-c",
        "--configure",
        action="store_true",
        help="Run the interactive default host and port wizard",
    )
    parser.add_argument("--reload", action="store_true", help="Reload when source files change")
    args = parser.parse_args()
    if args.configure:
        if args.background or args.reload:
            parser.error("--configure cannot be combined with --background or --reload")
        run_configuration_wizard()
        return
    if args.background:
        if args.reload:
            parser.error("--background cannot be combined with --reload")
        try:
            pid, log_path = launch_background(args.host, args.port)
        except (OSError, RuntimeError) as exc:
            parser.error(str(exc))
        print(f"MicListen started in the background (PID {pid}).")
        print(f"Open http://{args.host}:{args.port}")
        print(f"Log: {log_path}")
        return
    if args.reload:
        uvicorn.run("miclisten.app:app", host=args.host, port=args.port, reload=True)
        return

    from .app import app, set_shutdown_handler

    config = uvicorn.Config(app, host=args.host, port=args.port)
    server = uvicorn.Server(config)
    set_shutdown_handler(lambda: setattr(server, "should_exit", True))
    try:
        server.run()
    finally:
        set_shutdown_handler(None)


if __name__ == "__main__":
    main()
