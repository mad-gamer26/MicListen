# MicListen

MicListen streams microphones and system audio to a browser. The repository now
contains two components:

- [`streamer/`](streamer/) — the installable `miclisten` application that
  captures audio. It can serve browsers directly or connect outbound to a relay.
- [`server/server.py`](server/server.py) — a standalone relay that lists connected
  streamers and exposes each one at `/<device-name>/`.

## Install the streamer

Install the published package:

```powershell
py -m pip install -U miclisten
```

To install the current GitHub source after the monorepo layout change:

```powershell
py -m pip install -U "git+https://github.com/mad-gamer26/MicListen.git#subdirectory=streamer"
```

The first `miclisten` run requires configuration. Choose **server** mode to host
the web interface directly, or **client** mode to connect to a relay. Run the
wizard again at any time with:

```powershell
miclisten --configure
```

### Server mode

Server mode is the original standalone MicListen behavior:

```powershell
miclisten
```

Open the configured address, normally <http://127.0.0.1:8765>.

### Client mode

Client mode asks for:

- A URL-safe device name such as `matthews-hp`
- The relay WebSocket URL, such as `wss://miclisten.mad-gamer.com`
- The relay password, when the relay uses authentication
- An optional streamer password protecting that device's interface and audio

It makes an outbound connection to the relay and sends its web interface,
device responses, PCM audio, and mobile MP3 fallback through that connection.
The browser address is then:

```text
https://miclisten.mad-gamer.com/matthews-hp/
```

## Run the relay

The relay uses FastAPI and Uvicorn, which are installed with MicListen. It can
also be installed on its own host with:

```bash
python -m pip install "fastapi>=0.115,<1" "uvicorn[standard]>=0.30,<1"
python server/server.py
```

Its first run requires an interactive configuration. Reopen the wizard with:

```bash
python server/server.py --configure
```

The relay home page displays every connected device as a button. Selecting a
button opens that streamer's interface. A relay password protects the complete
site and incoming streamer connections; each streamer can additionally have
its own password.

For an Internet deployment, bind the relay to a private/local address and put
it behind an HTTPS reverse proxy. Streamers should connect using `wss://`, and
the proxy must support WebSocket upgrades for `/_relay/streamer` and device
audio paths.

## Authentication warning

Passwords are optional to permit trusted local-network use. Whenever either
component starts without its own authentication enabled, it prints a warning:
an unauthenticated listener could capture microphone or system audio. Do not
expose an unauthenticated MicListen service or relay to the Internet.

Local browser passwords are stored as salted PBKDF2 hashes. A client-mode
streamer's relay credential must remain retrievable in its per-user config file
because it is needed for each outbound connection.

## Development

```powershell
py -m pip install -e ".\streamer[test]"
py -m pytest streamer\tests
```

See [`streamer/README.md`](streamer/README.md) for audio capture and browser
compatibility details.
