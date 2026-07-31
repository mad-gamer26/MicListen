import sys

from miclisten.__main__ import _server_command


def test_server_command_uses_module_for_python(monkeypatch):
    monkeypatch.delattr(sys, "frozen", raising=False)

    assert _server_command("127.0.0.1", 8765) == [
        sys.executable,
        "-m",
        "miclisten",
        "--host",
        "127.0.0.1",
        "--port",
        "8765",
    ]


def test_server_command_relaunches_frozen_executable(monkeypatch):
    monkeypatch.setattr(sys, "frozen", True, raising=False)

    assert _server_command("0.0.0.0", 9000) == [
        sys.executable,
        "--host",
        "0.0.0.0",
        "--port",
        "9000",
    ]
