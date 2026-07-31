import sys

from miclisten.__main__ import _server_command, _server_environment


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


def test_server_environment_preserves_python_environment(monkeypatch):
    monkeypatch.delattr(sys, "frozen", raising=False)
    monkeypatch.delenv("PYINSTALLER_RESET_ENVIRONMENT", raising=False)
    monkeypatch.setenv("MICLISTEN_TEST_VALUE", "preserved")

    environment = _server_environment()

    assert environment["MICLISTEN_TEST_VALUE"] == "preserved"
    assert "PYINSTALLER_RESET_ENVIRONMENT" not in environment


def test_server_environment_resets_frozen_bootloader(monkeypatch):
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setenv("PYINSTALLER_RESET_ENVIRONMENT", "0")

    assert _server_environment()["PYINSTALLER_RESET_ENVIRONMENT"] == "1"
