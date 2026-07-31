from types import SimpleNamespace

from miclisten.audio import AudioBackend, DeviceNotFound


class FakeAudio:
    def get_device_count(self):
        return 4

    def get_device_info_by_index(self, index):
        return [
            {
                "index": 0,
                "name": "Desk Microphone",
                "maxInputChannels": 1,
                "defaultSampleRate": 48000.0,
                "hostApi": 0,
                "isLoopbackDevice": False,
            },
            {
                "index": 1,
                "name": "Speakers",
                "maxInputChannels": 0,
                "maxOutputChannels": 2,
                "defaultSampleRate": 48000.0,
                "hostApi": 0,
            },
            {
                "index": 2,
                "name": "Speakers [Loopback]",
                "maxInputChannels": 8,
                "defaultSampleRate": 44100.0,
                "hostApi": 0,
                "isLoopbackDevice": True,
            },
            {
                "index": 3,
                "name": "Microsoft Sound Mapper - Input",
                "maxInputChannels": 2,
                "defaultSampleRate": 44100.0,
                "hostApi": 1,
                "isLoopbackDevice": False,
            },
        ][index]

    def get_host_api_info_by_type(self, host_type):
        assert host_type == 13
        return {"index": 0, "name": "Windows WASAPI"}

    def get_default_wasapi_device(self, *, d_out=False, d_in=False):
        return self.get_device_info_by_index(1 if d_out else 0)

    def get_default_wasapi_loopback(self):
        return self.get_device_info_by_index(2)


def make_backend():
    backend = AudioBackend.__new__(AudioBackend)
    backend.audio = FakeAudio()
    backend.module = SimpleNamespace(paWASAPI=13)
    return backend


def test_lists_inputs_and_loopback_outputs():
    devices = make_backend().list_devices()

    assert [device.id for device in devices] == [-1, -2, 0, 2]
    assert devices[0].name == "Default input device"
    assert devices[0].kind == "input"
    assert devices[0].is_default is True
    assert devices[0].capture_id == 0
    assert devices[1].name == "Default output device"
    assert devices[1].kind == "output"
    assert devices[1].capture_id == 2
    assert devices[3].kind == "output"
    assert devices[3].channels == 2
    assert devices[3].sample_rate == 44100
    assert "capture_id" not in devices[1].to_dict()
    assert all("Microsoft Sound Mapper" not in device.name for device in devices)


def test_rejects_output_without_loopback_capture():
    backend = make_backend()

    try:
        backend.get_device(1)
    except DeviceNotFound as exc:
        assert "cannot be captured" in str(exc)
    else:
        raise AssertionError("DeviceNotFound was not raised")
