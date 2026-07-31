# MicListen

MicListen is a small Python web application that streams live audio from the
computer running it to a browser. It can play several devices at once and gives
each stream its own volume control.

On Windows, MicListen uses WASAPI loopback through
[PyAudioWPatch](https://github.com/s0d3s/PyAudioWPatch), so both microphones and
speaker/headphone outputs appear in the device list.

## Install and run

Python 3.10 or newer is required.

```powershell
py -m venv .venv
.venv\Scripts\Activate.ps1
python -m pip install -e .
miclisten
```

Then open <http://127.0.0.1:8765>. Click the play button beside any input or
output. Clicking additional devices mixes them in the browser; it does not mix
or modify audio on the host.

You can also run it without installing the console script:

```powershell
python -m miclisten
```

Useful server options:

```text
miclisten --host 127.0.0.1 --port 8765
miclisten --background
miclisten -b
miclisten --configure
miclisten -c
miclisten --help
```

### Configuration file

Run `miclisten --configure` (or `miclisten -c`) to open an interactive wizard
for the default bind host and port. Press Enter at either prompt to retain the
displayed value. Existing settings are loaded before prompting; when no valid
configuration exists, the wizard starts with `127.0.0.1` and `8765`.

On Windows the wizard writes `%APPDATA%\MicListen\config.ini`:

```ini
[defaults]
host = 127.0.0.1
port = 8765
```

MicListen reads this file on every launch. Command-line `--host` and `--port`
arguments override the configured defaults for that launch.

`--background` (or `-b`) starts MicListen as a detached process. On Windows,
the server does not create or retain a console window. Startup messages and
errors are written to `%LOCALAPPDATA%\MicListen\miclisten.log`; the launch
command prints the background process ID so it can also be located in Task
Manager or stopped with `Stop-Process -Id <PID>`.

The **Shut down** button in the web page stops either a foreground or background
MicListen server gracefully after confirmation. It closes active capture streams
and browser connections before the process exits.

## Windows output capture

Output devices are the WASAPI entries whose names end in `[Loopback]`. The UI
labels these as **System output** and hides that suffix. If an expected output
is missing, make sure it is enabled in Windows and press the refresh button.
Bluetooth devices can disappear or change format when their Windows audio
profile changes.

The Inputs and Outputs tabs are intentionally strict: Inputs contains WASAPI
capture endpoints, while Outputs contains only WASAPI loopback endpoints.
Legacy aliases such as Microsoft Sound Mapper and Primary Sound Capture Driver
are omitted. **Default input device** and **Default output device** resolve to
the current Windows defaults whenever a stream is started.

When listening to a loopback output in a browser on the same computer, route
the browser to headphones or a different output device. Playing the captured
stream back through the device being captured can create an audio feedback
loop.

MicListen opens devices in shared mode at their reported native sample rate,
captures signed 16-bit PCM, and sends it over a WebSocket. The browser performs
sample-rate conversion when necessary and keeps a short jitter buffer.

## iPhone and iPad background audio

On current iOS and iPadOS versions, MicListen requests Safari's playback audio
session and uses its low-latency Web Audio stream. This supports background and
lock-screen playback without the roughly two-second startup buffer imposed by a
native live MP3 player. The lock screen shows the selected device and provides
play/pause controls. Older Safari versions without the Audio Session API fall
back to the native MP3 stream for background compatibility.

Start listening before locking the device. iOS may still interrupt playback for
phone calls, Siri, another app taking audio focus, a network change, or if Safari
is force-quit. Return to MicListen and press play again after such an interruption.

## Listening from another computer

Binding to the network is opt-in:

```powershell
miclisten --host 0.0.0.0
```

There is no authentication. Only expose the port on a trusted network. Modern
browsers restrict `AudioWorklet` to secure contexts; `localhost` is allowed,
but a remote IP generally needs HTTPS through a reverse proxy. MicListen falls
back to the older Web Audio processor on HTTP connections so iPhones and other
devices can still listen, with slightly higher latency.

## Development

```powershell
python -m pip install -e ".[test]"
pytest
```

## Windows executable and installer

Install the project dependencies, PyInstaller, and Inno Setup 6, then run:

```powershell
py -m PyInstaller --clean --noconfirm packaging\MicListen.spec
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\MicListen.iss
```

The standalone executable is written to `dist\MicListen.exe`, and the installer
is written to `dist\installer`. The installer is deliberately per-user: it
installs below `%LOCALAPPDATA%\Programs`, cannot be switched to an all-users
installation, creates only a Start Menu shortcut, and never launches MicListen.
It adds the installation directory to the current user's `PATH` and removes
only that entry when MicListen is uninstalled.

The `Build Windows installer` GitHub Actions workflow repeats this build for
pull requests, pushes to `main`, version tags, and manual runs. Pushing a tag
that matches the project version, such as `v0.5.2`, creates a GitHub Release
with generated release notes and attaches both the executable and installer.

The HTTP API is available at `/docs`. Live PCM uses
`/ws/audio/{device_id}`: the server first sends a JSON format message and then
binary interleaved little-endian 16-bit PCM frames. The native mobile playback
path uses a live MP3 response at `/stream/audio/{device_id}.mp3`.
