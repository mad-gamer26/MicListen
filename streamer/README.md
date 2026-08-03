# MicListen Streamer

MicListen captures microphones and system outputs and streams them to a browser.
It can run as a standalone web server or connect as a named device to a
MicListen relay.

## Installation

```powershell
py -m pip install -U miclisten
```

For the current GitHub source:

```powershell
py -m pip install -U "git+https://github.com/mad-gamer26/MicListen.git#subdirectory=streamer"
```

Run `miclisten`. If the per-user `config.ini` is missing, empty, or incomplete,
MicListen requires the interactive configuration wizard before it starts. You
can rerun the wizard later with `miclisten --configure`.

## Modes

In **server mode**, MicListen hosts its interface directly. The default address
is <http://127.0.0.1:8765>. Command-line `--host` and `--port` values override
the configured bind address for that run.

In **client mode**, MicListen connects outbound to the configured relay using a
`ws://` or `wss://` URL. Its configured device name becomes the public path. A
device named `matthews-hp` appears at `/matthews-hp/` on the relay.

Useful commands:

```text
miclisten
miclisten --background
miclisten --configure
miclisten --host 0.0.0.0 --port 8765
miclisten --help
```

`--host`, `--port`, and `--reload` apply only to server mode. Background mode
works in either mode. Logs are written to `%LOCALAPPDATA%\MicListen\miclisten.log`
on Windows or `~/.local/state/miclisten/miclisten.log` elsewhere.

## Authentication

The wizard can set a streamer password in either mode. In server mode it
protects the local interface, APIs, and audio. In client mode it protects that
device's interface and audio paths on the relay. Passwords are saved as salted
PBKDF2 hashes.

Authentication is optional, but MicListen prints a warning on every start when
it is disabled because anyone who can reach the service could capture audio.

## Windows output capture

On Windows, MicListen uses WASAPI loopback through PyAudioWPatch. Inputs contain
WASAPI capture endpoints; Outputs contain WASAPI loopback endpoints. Default
input and output entries resolve to the current Windows defaults when capture
begins.

When listening to loopback audio on the same computer, route the browser to a
different output or headphones to prevent feedback.

## Browser audio

MicListen sends signed 16-bit PCM over WebSockets. The browser handles sample
rate conversion and buffering. On iOS and iPadOS it uses the playback audio
session when available; older Safari versions fall back to a live MP3 stream for
background playback.

Remote browsers should use HTTPS. `AudioWorklet` normally requires a secure
context, although MicListen includes a legacy fallback for plain HTTP LAN use.

## Development

From the repository root:

```powershell
py -m pip install -e ".\streamer[test]"
py -m pytest streamer\tests
```
