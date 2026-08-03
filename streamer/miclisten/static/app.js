const devicesElement = document.querySelector("#devices");
const notice = document.querySelector("#notice");
const note = document.querySelector("#connection-note");
const template = document.querySelector("#device-template");
const sessions = new Map();
const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent)
  || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
let devices = [];
let filter = "all";
const appPath = new URL(".", window.location.href).pathname.replace(/\/$/, "");

const icons = {
  input: `<svg viewBox="0 0 24 24"><rect x="8" y="3" width="8" height="12" rx="4"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3M9 21h6"/></svg>`,
  output: `<svg viewBox="0 0 24 24"><path d="M5 9v6M19 9v6M5 15H3V9h2a7 7 0 0 1 14 0h2v6h-2M8 19h7a4 4 0 0 0 4-4"/></svg>`,
};

function showError(message) {
  notice.textContent = message;
  notice.classList.remove("hidden");
}

function clearError() {
  notice.classList.add("hidden");
}

async function loadDevices() {
  clearError();
  devicesElement.innerHTML = `<div class="empty">Finding audio devices…</div>`;
  try {
    const response = await fetch("api/devices", { cache: "no-store" });
    const body = await response.json();
    if (!response.ok) throw new Error(body.detail || "Could not load audio devices");
    devices = body.devices;
    updateCounts();
    render();
  } catch (error) {
    devices = [];
    devicesElement.innerHTML = `<div class="empty">No audio devices available</div>`;
    showError(error.message);
  }
}

function updateCounts() {
  const inputs = devices.filter(device => device.kind === "input").length;
  const outputs = devices.filter(device => device.kind === "output").length;
  document.querySelector("#input-option").textContent = `Inputs (${inputs})`;
  document.querySelector("#output-option").textContent = `Outputs (${outputs})`;
}

function render() {
  devicesElement.innerHTML = "";
  const groups = filter === "all"
    ? [
        { title: "Inputs", kind: "input" },
        { title: "Outputs", kind: "output" },
      ]
    : [{ title: null, kind: filter }];

  for (const group of groups) {
    if (group.title) {
      const heading = document.createElement("h2");
      heading.className = "section-heading";
      heading.textContent = group.title;
      devicesElement.append(heading);
    }

    const matching = devices.filter(device => device.kind === group.kind);
    if (!matching.length) {
      const empty = document.createElement("p");
      empty.className = "section-empty";
      empty.textContent = `No ${group.kind} devices found`;
      devicesElement.append(empty);
      continue;
    }

    for (const device of matching) {
      const card = template.content.firstElementChild.cloneNode(true);
      const session = sessions.get(device.id);
      const active = Boolean(session);
      card.dataset.id = device.id;
      card.classList.toggle("listening", active);
      card.querySelector(".device-icon").innerHTML = icons[device.kind];
      const name = card.querySelector(".device-name");
      name.textContent = device.name.replace(/ \[Loopback\]$/i, "");
      name.setAttribute("aria-level", filter === "all" ? "3" : "2");
      const volume = card.querySelector(".volume");
      volume.value = session?.volume ?? 1;
      card.querySelector(".volume-text").textContent = `${Math.round(volume.value * 100)}%`;
      volume.addEventListener("input", () => setVolume(device.id, volume, card));
      const listenButton = card.querySelector(".listen-button");
      listenButton.setAttribute("aria-label", `${active ? "Stop" : "Start"} listening to ${device.name}`);
      listenButton.addEventListener("click", () => toggle(device, card));
      if (active) card.querySelector(".status-text").textContent = session.status || "Live";
      devicesElement.append(card);
    }
  }
}

function setVolume(id, input, card) {
  const value = Number(input.value);
  card.querySelector(".volume-text").textContent = `${Math.round(value * 100)}%`;
  const session = sessions.get(id);
  if (session) {
    session.volume = value;
    if (session.audio) session.audio.volume = Math.min(value, 1);
    if (session.gain) session.gain.gain.setTargetAtTime(value, session.context.currentTime, 0.02);
  }
}

async function toggle(device, card) {
  if (sessions.has(device.id)) {
    stop(device.id);
    setCardState(card, device, false, "Ready");
    updateNote();
    return;
  }

  clearError();
  const playbackSessionAvailable = requestPlaybackAudioSession();
  if (isIOS && !playbackSessionAvailable) {
    await startNativeAudio(device, card);
    return;
  }

  setCardState(card, device, true, "Connecting");
  let pendingContext = null;
  try {
    // Creating the context directly in the click handler satisfies browser
    // autoplay policies; stream metadata can arrive a moment later.
    const context = new AudioContext({ latencyHint: "interactive" });
    pendingContext = context;
    await context.resume();
    const scheme = location.protocol === "https:" ? "wss" : "ws";
    const socket = new WebSocket(`${scheme}://${location.host}${appPath}/ws/audio/${device.id}`);
    socket.binaryType = "arraybuffer";
    const session = { socket, context, node: null, gain: null, volume: Number(card.querySelector(".volume").value), status: "Connecting" };
    sessions.set(device.id, session);
    configureWebAudioMediaSession(device, session);
    pendingContext = null;

    socket.onmessage = async (event) => {
      try {
        if (typeof event.data === "string") {
          const message = JSON.parse(event.data);
          if (message.type === "error") {
            throw new Error(message.message);
          } else if (message.type === "format") {
            await configurePlayer(session, message);
            session.status = "Live";
            setCardState(card, device, true, "Live");
            if ("mediaSession" in navigator) navigator.mediaSession.playbackState = "playing";
            updateNote();
          }
        } else if (session.pushAudio) {
          session.pushAudio(event.data);
        }
      } catch (error) {
        showError(error.message);
        stop(device.id);
        render();
        updateNote();
      }
    };
    socket.onerror = () => showError(`Connection failed for ${device.name}`);
    socket.onclose = () => {
      if (sessions.get(device.id) === session) {
        sessions.delete(device.id);
        if (session.context) session.context.close();
        render();
        updateNote();
      }
    };
  } catch (error) {
    sessions.delete(device.id);
    if (pendingContext) pendingContext.close();
    showError(error.message);
    render();
  }
}

async function startNativeAudio(device, card) {
  setCardState(card, device, true, "Connecting");
  let audio = null;
  try {
    requestPlaybackAudioSession();

    audio = document.createElement("audio");
    audio.className = "native-audio";
    audio.preload = "none";
    audio.playsInline = true;
    audio.src = `stream/audio/${device.id}.mp3`;
    audio.volume = Math.min(Number(card.querySelector(".volume").value), 1);

    const session = {
      audio,
      socket: null,
      context: null,
      node: null,
      gain: null,
      volume: Number(card.querySelector(".volume").value),
      status: "Connecting",
    };
    sessions.set(device.id, session);
    document.body.append(audio);
    configureMediaSession(device, audio);

    audio.addEventListener("playing", () => {
      if (sessions.get(device.id) !== session) return;
      session.status = "Live";
      setCardState(card, device, true, "Live");
      if ("mediaSession" in navigator) navigator.mediaSession.playbackState = "playing";
      updateNote();
    });
    audio.addEventListener("waiting", () => {
      if (sessions.get(device.id) !== session) return;
      session.status = "Buffering";
      if (card.isConnected) card.querySelector(".status-text").textContent = "Buffering";
    });
    audio.addEventListener("pause", () => {
      if (sessions.get(device.id) !== session) return;
      session.status = "Paused";
      if (card.isConnected) card.querySelector(".status-text").textContent = "Paused";
      if ("mediaSession" in navigator) navigator.mediaSession.playbackState = "paused";
    });
    audio.addEventListener("error", () => {
      if (sessions.get(device.id) !== session) return;
      const message = audio.error?.message || `Could not play ${device.name}`;
      showError(message);
      stop(device.id);
      render();
      updateNote();
    });

    await audio.play();
  } catch (error) {
    if (sessions.has(device.id)) stop(device.id);
    else if (audio) audio.remove();
    setCardState(card, device, false, "Ready");
    showError(error.message);
    updateNote();
  }
}

function requestPlaybackAudioSession() {
  if (!navigator.audioSession) return false;
  try {
    navigator.audioSession.type = "playback";
    return navigator.audioSession.type === "playback";
  } catch (_) {
    return false;
  }
}

function configureWebAudioMediaSession(device, session) {
  if (!("mediaSession" in navigator)) return;
  if (typeof MediaMetadata !== "undefined") {
    navigator.mediaSession.metadata = new MediaMetadata({
      title: device.name.replace(/ \[Loopback\]$/i, ""),
      artist: device.kind === "output" ? "MicListen · System output" : "MicListen · Microphone",
      album: "Live audio",
    });
  }
  const setHandler = (action, handler) => {
    try {
      navigator.mediaSession.setActionHandler(action, handler);
    } catch (_) {
      // Some Safari versions expose Media Session without every action.
    }
  };
  setHandler("play", () => {
    requestPlaybackAudioSession();
    session.context?.resume();
    navigator.mediaSession.playbackState = "playing";
  });
  setHandler("pause", () => {
    session.context?.suspend();
    navigator.mediaSession.playbackState = "paused";
  });
  setHandler("stop", () => {
    stop(device.id);
    render();
    updateNote();
  });
}

function configureMediaSession(device, audio) {
  if (!("mediaSession" in navigator)) return;
  if (typeof MediaMetadata !== "undefined") {
    navigator.mediaSession.metadata = new MediaMetadata({
      title: device.name.replace(/ \[Loopback\]$/i, ""),
      artist: device.kind === "output" ? "MicListen · System output" : "MicListen · Microphone",
      album: "Live audio",
    });
  }
  const setHandler = (action, handler) => {
    try {
      navigator.mediaSession.setActionHandler(action, handler);
    } catch (_) {
      // Some Safari versions expose Media Session without every action.
    }
  };
  setHandler("play", () => audio.play());
  setHandler("pause", () => audio.pause());
  setHandler("stop", () => {
    stop(device.id);
    render();
    updateNote();
  });
}

async function configurePlayer(session, format) {
  const context = session.context;
  const gain = context.createGain();
  gain.gain.value = session.volume;
  let node;

  if (context.audioWorklet && typeof AudioWorkletNode !== "undefined") {
    await context.audioWorklet.addModule(new URL("static/audio-processor.js?v=0.2.1", document.baseURI));
    node = new AudioWorkletNode(context, "pcm-player", {
      numberOfOutputs: 1,
      outputChannelCount: [format.channels],
      processorOptions: { channels: format.channels, sampleRate: format.sampleRate },
    });
    session.pushAudio = data => node.port.postMessage(data, [data]);
  } else {
    node = createLegacyPCMPlayer(context, format);
    session.pushAudio = data => node.pushPCM(data);
  }

  node.connect(gain).connect(context.destination);
  session.node = node;
  session.gain = gain;
  await context.resume();
}

// ScriptProcessorNode is deprecated, but it remains the broadest-compatible
// fallback for iOS browsers where AudioWorklet is unavailable (notably HTTP
// pages on a LAN). The processing is equivalent to the worklet player.
function createLegacyPCMPlayer(context, format) {
  const channels = Math.max(1, Math.min(2, format.channels));
  const sourceRate = format.sampleRate;
  const ratio = sourceRate / context.sampleRate;
  const capacity = Math.ceil(sourceRate * 2);
  const buffers = Array.from({ length: channels }, () => new Float32Array(capacity));
  const node = context.createScriptProcessor(2048, 0, channels);
  let read = 0;
  let write = 0;
  let available = 0;
  let phase = 0;
  let started = false;

  node.pushPCM = data => {
    const pcm = new Int16Array(data);
    const frames = Math.floor(pcm.length / channels);
    for (let frame = 0; frame < frames; frame++) {
      if (available >= capacity - 1) {
        read = (read + 1) % capacity;
        available--;
      }
      for (let channel = 0; channel < channels; channel++) {
        buffers[channel][write] = pcm[frame * channels + channel] / 32768;
      }
      write = (write + 1) % capacity;
      available++;
    }
    if (available > sourceRate * 0.2) {
      const target = Math.ceil(sourceRate * 0.06);
      const dropped = available - target;
      read = (read + dropped) % capacity;
      available = target;
      phase = 0;
    }
    if (available >= sourceRate * 0.03) started = true;
  };

  node.onaudioprocess = event => {
    const output = event.outputBuffer;
    if (!started || available < 2) {
      if (available < 2) started = false;
      return;
    }

    for (let sample = 0; sample < output.length; sample++) {
      if (available < 2) {
        started = false;
        break;
      }
      const next = (read + 1) % capacity;
      for (let channel = 0; channel < output.numberOfChannels; channel++) {
        const source = Math.min(channel, channels - 1);
        const a = buffers[source][read];
        const value = a + (buffers[source][next] - a) * phase;
        output.getChannelData(channel)[sample] = value;
      }
      phase += ratio;
      while (phase >= 1 && available > 1) {
        phase -= 1;
        read = (read + 1) % capacity;
        available--;
      }
    }
  };

  return node;
}

function stop(id) {
  const session = sessions.get(id);
  if (!session) return;
  sessions.delete(id);
  if (session.socket) {
    session.socket.onclose = null;
    session.socket.close();
  }
  if (session.audio) {
    session.audio.pause();
    session.audio.removeAttribute("src");
    session.audio.load();
    session.audio.remove();
  }
  if (session.node) session.node.disconnect();
  if (session.context) session.context.close();
}

function setCardState(card, device, active, status) {
  card.classList.toggle("listening", active);
  card.querySelector(".status-text").textContent = status;
  card.querySelector(".listen-button").setAttribute(
    "aria-label",
    `${active ? "Stop" : "Start"} listening to ${device.name}`,
  );
}

function updateNote() {
  const count = sessions.size;
  note.textContent = count ? `Listening to ${count} device${count === 1 ? "" : "s"}` : "Select a device to begin listening";
}

async function shutDownMicListen() {
  const confirmed = window.confirm("Are you sure you wish to shut down MicListen?");
  if (!confirmed) return;

  const button = document.querySelector("#shutdown");
  button.disabled = true;
  button.querySelector("span").textContent = "Shutting down…";
  try {
    const response = await fetch("api/shutdown", { method: "POST" });
    const result = await response.json();
    if (!response.ok) throw new Error(result.detail || "MicListen could not be shut down");
    [...sessions.keys()].forEach(stop);
    devicesElement.querySelectorAll("button, input").forEach(control => control.disabled = true);
    notice.textContent = "MicListen has shut down. You may close this page.";
    notice.classList.remove("hidden");
    note.textContent = "Server stopped";
  } catch (error) {
    button.disabled = false;
    button.querySelector("span").textContent = "Shut down";
    showError(error.message);
  }
}

document.querySelector("#refresh").addEventListener("click", loadDevices);
document.querySelector("#shutdown").addEventListener("click", shutDownMicListen);
document.querySelector("#device-filter").addEventListener("change", event => {
  filter = event.target.value;
  render();
});
window.addEventListener("beforeunload", () => [...sessions.keys()].forEach(stop));

loadDevices();
