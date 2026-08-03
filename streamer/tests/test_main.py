import pytest

from miclisten.__main__ import _configuration_required


def test_declining_required_configuration_aborts(monkeypatch, capsys):
    monkeypatch.setattr("builtins.input", lambda prompt: "no")
    with pytest.raises(SystemExit) as stopped:
        _configuration_required()
    assert stopped.value.code == 1
    output = capsys.readouterr().out
    assert "You must configure MicListen before using it for the first time." in output
    assert "Aborting." in output
