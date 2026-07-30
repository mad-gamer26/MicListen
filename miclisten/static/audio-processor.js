class PCMPlayerProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const config = options.processorOptions || {};
    this.channels = config.channels || 1;
    this.sourceRate = config.sampleRate || sampleRate;
    this.ratio = this.sourceRate / sampleRate;
    this.capacity = Math.ceil(this.sourceRate * 2);
    this.buffers = Array.from({ length: this.channels }, () => new Float32Array(this.capacity));
    this.read = 0;
    this.write = 0;
    this.available = 0;
    this.phase = 0;
    this.started = false;
    this.port.onmessage = (event) => this.push(event.data);
  }

  push(data) {
    const pcm = new Int16Array(data);
    const frames = Math.floor(pcm.length / this.channels);
    for (let frame = 0; frame < frames; frame++) {
      if (this.available >= this.capacity - 1) {
        this.read = (this.read + 1) % this.capacity;
        this.available--;
      }
      for (let channel = 0; channel < this.channels; channel++) {
        this.buffers[channel][this.write] = pcm[frame * this.channels + channel] / 32768;
      }
      this.write = (this.write + 1) % this.capacity;
      this.available++;
    }
    if (this.available > this.sourceRate * 0.2) {
      const target = Math.ceil(this.sourceRate * 0.06);
      const dropped = this.available - target;
      this.read = (this.read + dropped) % this.capacity;
      this.available = target;
      this.phase = 0;
    }
    if (this.available >= this.sourceRate * 0.03) this.started = true;
  }

  process(inputs, outputs) {
    const output = outputs[0];
    if (!this.started || this.available < 2) {
      if (this.available < 2) this.started = false;
      return true;
    }

    for (let i = 0; i < output[0].length; i++) {
      if (this.available < 2) {
        this.started = false;
        break;
      }
      const next = (this.read + 1) % this.capacity;
      for (let channel = 0; channel < output.length; channel++) {
        const source = Math.min(channel, this.channels - 1);
        const a = this.buffers[source][this.read];
        const b = this.buffers[source][next];
        const value = a + (b - a) * this.phase;
        output[channel][i] = value;
      }
      this.phase += this.ratio;
      while (this.phase >= 1 && this.available > 1) {
        this.phase -= 1;
        this.read = (this.read + 1) % this.capacity;
        this.available--;
      }
    }
    return true;
  }
}

registerProcessor("pcm-player", PCMPlayerProcessor);
