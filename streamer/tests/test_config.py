from miclisten.config import (
    DEFAULT_HOST,
    DEFAULT_PORT,
    MODE_CLIENT,
    MODE_SERVER,
    Settings,
    configuration_is_valid,
    hash_password,
    load_settings,
    run_configuration_wizard,
    save_settings,
    verify_password,
)


def test_missing_and_invalid_configuration_is_not_valid(tmp_path):
    path = tmp_path / "MicListen" / "config.ini"
    assert load_settings(path) == Settings()
    assert configuration_is_valid(path) is False

    path.parent.mkdir(parents=True)
    path.write_text("[server]\nhost = \nport = 99999\n", encoding="utf-8")
    assert configuration_is_valid(path) is False
    assert load_settings(path).host == DEFAULT_HOST
    assert load_settings(path).port == DEFAULT_PORT


def test_server_settings_round_trip(tmp_path):
    path = tmp_path / "MicListen" / "config.ini"
    expected = Settings(
        mode=MODE_SERVER,
        host="0.0.0.0",
        port=9000,
        password_hash=hash_password("secret"),
    )
    assert save_settings(expected, path) == path
    assert load_settings(path) == expected
    assert configuration_is_valid(path) is True
    contents = path.read_text(encoding="utf-8")
    assert "[miclisten]" in contents
    assert "[server]" in contents


def test_client_settings_round_trip(tmp_path):
    path = tmp_path / "MicListen" / "config.ini"
    expected = Settings(
        mode=MODE_CLIENT,
        device_name="matthews-hp",
        relay_url="wss://miclisten.mad-gamer.com",
        relay_password="relay secret",
        password_hash=hash_password("device secret"),
    )
    save_settings(expected, path)
    assert load_settings(path) == expected
    assert configuration_is_valid(path) is True


def test_wizard_reads_existing_values_and_validates_port(tmp_path):
    path = tmp_path / "MicListen" / "config.ini"
    save_settings(Settings(mode=MODE_SERVER, host="existing-host", port=8123), path)
    answers = iter(["", "", "invalid", "70000", "9123"])
    output = []

    settings = run_configuration_wizard(
        path=path,
        input_func=lambda prompt: (output.append(prompt), next(answers))[1],
        password_func=lambda prompt: (output.append(prompt), "")[1],
        output_func=output.append,
    )

    assert settings.mode == MODE_SERVER
    assert settings.host == "existing-host"
    assert settings.port == 9123
    assert load_settings(path) == settings
    assert any("Bind host [existing-host]" in line for line in output)
    assert sum("Port must be a number" in line for line in output) == 2


def test_password_hashes_are_salted_and_verifiable():
    first = hash_password("correct horse")
    second = hash_password("correct horse")
    assert first != second
    assert verify_password("correct horse", first) is True
    assert verify_password("wrong", first) is False


def test_client_wizard_validates_name_and_relay_url(tmp_path):
    path = tmp_path / "MicListen" / "config.ini"
    answers = iter(
        [
            "client",
            "Not A Valid Name",
            "matthews-hp",
            "https://wrong-scheme.example",
            "wss://miclisten.mad-gamer.com",
        ]
    )
    passwords = iter(["relay secret", "device secret"])
    output = []
    settings = run_configuration_wizard(
        path=path,
        input_func=lambda prompt: (output.append(prompt), next(answers))[1],
        password_func=lambda prompt: (output.append(prompt), next(passwords))[1],
        output_func=output.append,
    )
    assert settings.mode == MODE_CLIENT
    assert settings.device_name == "matthews-hp"
    assert settings.relay_url == "wss://miclisten.mad-gamer.com"
    assert settings.relay_password == "relay secret"
    assert verify_password("device secret", settings.password_hash)
    assert configuration_is_valid(path)
    assert any("lowercase letters" in line for line in output)
    assert any("ws:// or wss://" in line for line in output)
