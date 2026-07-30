from miclisten.config import (
    DEFAULT_HOST,
    DEFAULT_PORT,
    Settings,
    load_settings,
    run_configuration_wizard,
    save_settings,
)


def test_missing_and_invalid_configuration_uses_hardcoded_defaults(tmp_path):
    path = tmp_path / "MicListen" / "config.ini"
    assert load_settings(path) == Settings(DEFAULT_HOST, DEFAULT_PORT)

    path.parent.mkdir(parents=True)
    path.write_text("[defaults]\nhost = \nport = 99999\n", encoding="utf-8")
    assert load_settings(path) == Settings(DEFAULT_HOST, DEFAULT_PORT)


def test_settings_round_trip_in_defaults_section(tmp_path):
    path = tmp_path / "MicListen" / "config.ini"
    saved = save_settings(Settings("matthews-hp", 9000), path)

    assert saved == path
    assert load_settings(path) == Settings("matthews-hp", 9000)
    contents = path.read_text(encoding="utf-8")
    assert "[defaults]" in contents
    assert "host = matthews-hp" in contents
    assert "port = 9000" in contents


def test_wizard_reads_existing_values_and_validates_port(tmp_path):
    path = tmp_path / "MicListen" / "config.ini"
    save_settings(Settings("existing-host", 8123), path)
    answers = iter(["", "invalid", "70000", "9123"])
    output = []

    settings = run_configuration_wizard(
        path=path,
        input_func=lambda prompt: (output.append(prompt), next(answers))[1],
        output_func=output.append,
    )

    assert settings == Settings("existing-host", 9123)
    assert load_settings(path) == settings
    assert any("Default host [existing-host]" in line for line in output)
    assert sum("Port must be a number" in line for line in output) == 2

