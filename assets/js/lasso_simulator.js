// Run states
const RunState = {
  STARTING: "STARTING",
  RUNNING: "RUNNING",
  STOPPING: "STOPPING",
  STOPPED: "STOPPED",
};

// Global state
let availableChains = [];
let activityCallback = null;
let simulator = null;

function now() {
  return performance && performance.now ? performance.now() : Date.now();
}

function updateAvg(avg, count, value) {
  const n = count + 1;
  return avg + (value - avg) / n;
}

function emptyWsStats() {
  return { open: 0, pending: 0, established: 0, error: 0 };
}

function selectedProviderFromResponse(response) {
  const encoded = response.headers.get("x-lasso-meta");
  if (!encoded) return null;

  try {
    const normalized = encoded.replace(/-/g, "+").replace(/_/g, "/");
    const padding = "=".repeat((4 - (normalized.length % 4)) % 4);
    const bytes = Uint8Array.from(atob(normalized + padding), (char) =>
      char.charCodeAt(0)
    );
    const metadata = JSON.parse(new TextDecoder().decode(bytes));
    const provider = metadata.selected_provider;

    if (typeof provider === "string") return provider;
    if (provider && typeof provider.id === "string") return provider.id;
  } catch (_error) {
    return null;
  }

  return null;
}

function generateId() {
  return `run_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
}

// SimulatorRun class - represents a single simulation run
class SimulatorRun {
  constructor(config, onStopped) {
    this.id = config.id || generateId();
    this.config = { ...config };
    this.onStopped = onStopped;
    this.state = RunState.STARTING;
    this.startTime = Date.now();
    this.endTime = null;
    this.durationTimer = null;
    this.stopDrainTimer = null;

    // HTTP state
    this.httpController = null;
    this.httpTimer = null;

    // WebSocket state
    this.wsSockets = [];
    this.wsPendingSubscriptions = new Map();
    this.nextWsRequestId = 1;

    // Per-run statistics
    this.stats = {
      http: {
        success: 0,
        error: 0,
        limited: 0,
        avgLatencyMs: 0,
        inflight: 0,
      },
      ws: emptyWsStats(),
    };
  }

  start() {
    if (this.state !== RunState.STARTING) {
      throw new Error(`Cannot start run in state ${this.state}`);
    }

    this.state = RunState.RUNNING;

    // Start HTTP load if enabled
    if (this.config.http?.enabled) {
      this._startHttpLoad();
    }

    // Start WebSocket load if enabled
    if (this.config.ws?.enabled) {
      this._startWsLoad();
    }

    // Set duration timeout if specified
    if (this.config.duration > 0) {
      this.durationTimer = setTimeout(() => this.stop(), this.config.duration);
    }

    this._logActivity("run", { status: "started" });
  }

  stop() {
    if (this.state === RunState.STOPPED || this.state === RunState.STOPPING) {
      return;
    }

    this.state = RunState.STOPPING;
    this.endTime = Date.now();

    if (this.durationTimer) {
      clearTimeout(this.durationTimer);
      this.durationTimer = null;
    }

    // Stop HTTP load
    this._stopHttpLoad();

    // Stop WebSocket load
    this._stopWsLoad();

    this._finishStopWhenDrained();
  }

  _finishStopWhenDrained() {
    if (this.state !== RunState.STOPPING) return;

    if (this.stats.http.inflight > 0) {
      if (!this.stopDrainTimer) {
        this.stopDrainTimer = setTimeout(() => this._finalizeStop(), 5000);
      }
      return;
    }

    this._finalizeStop();
  }

  _finalizeStop() {
    if (this.state !== RunState.STOPPING) return;

    if (this.stopDrainTimer) {
      clearTimeout(this.stopDrainTimer);
      this.stopDrainTimer = null;
    }

    this.stats.http.inflight = 0;
    this.state = RunState.STOPPED;
    this._logActivity("run", {
      status: "stopped",
      duration: this.endTime - this.startTime,
      stats: this.getStats(),
    });
    this.onStopped(this.id);
  }

  isActive() {
    return this.state !== RunState.STOPPED;
  }

  getStats() {
    return JSON.parse(JSON.stringify(this.stats));
  }

  _startHttpLoad() {
    const httpConfig = this.config.http;
    const chains = this.config.chains || getDefaultChains();
    const methods = httpConfig.methods || ["eth_blockNumber"];
    const rps = httpConfig.rps || 5;
    const concurrency = httpConfig.concurrency || 4;

    // Robust strategy normalization: convert undefined, null, empty string, or string "undefined"/"null" to null
    const rawStrategy = this.config.strategy;
    const strategy =
      rawStrategy &&
      typeof rawStrategy === "string" &&
      rawStrategy.length > 0 &&
      rawStrategy !== "undefined" &&
      rawStrategy !== "null" &&
      rawStrategy.trim() !== ""
        ? rawStrategy
        : null;

    this.stats.http = {
      success: 0,
      error: 0,
      limited: 0,
      avgLatencyMs: 0,
      inflight: 0,
    };

    const intervalMs = Math.max(50, Math.floor(1000 / Math.max(1, rps)));
    this.httpController = { stopped: false };

    const fireOnce = async () => {
      if (!this.httpController || this.httpController.stopped || this.state !== RunState.RUNNING)
        return;
      if (this.stats.http.inflight >= concurrency) return;

      const chain = chains[Math.floor(Math.random() * chains.length)];
      const method = methods[Math.floor(Math.random() * methods.length)];

      const body = {
        jsonrpc: "2.0",
        id: Math.floor(Math.random() * 1e9),
        method,
        params:
          method === "eth_getBalance"
            ? ["0x0000000000000000000000000000000000000000", "latest"]
            : [],
      };

      const profile = this.config.profile || "public";
      const headers = { "Content-Type": "application/json" };
      const url = strategy
        ? `/rpc/profile/${encodeURIComponent(profile)}/${encodeURIComponent(strategy)}/${encodeURIComponent(chain)}`
        : `/rpc/profile/${encodeURIComponent(profile)}/${encodeURIComponent(chain)}`;

      this.stats.http.inflight++;
      const start = now();

      this._logActivity("http", {
        method,
        chain,
        status: "started",
        runId: this.id,
      });

      try {
        const resp = await fetch(url, {
          method: "POST",
          headers,
          body: JSON.stringify(body),
        });

        const json = await resp.json().catch(() => null);
        const dur = now() - start;
        const provider = selectedProviderFromResponse(resp);

        this.stats.http.avgLatencyMs = updateAvg(
          this.stats.http.avgLatencyMs,
          this.stats.http.success +
            this.stats.http.error +
            this.stats.http.limited,
          dur
        );

        if (resp.ok && json?.jsonrpc === "2.0" && json.id === body.id && Object.hasOwn(json, "result") && !Object.hasOwn(json, "error")) {
          this.stats.http.success++;
          this._logActivity("http", {
            method,
            chain,
            status: "success",
            latency: Math.round(dur),
            statusCode: resp.status,
            provider,
            runId: this.id,
          });
        } else {
          this.stats.http.error++;
          this._logActivity("http", {
            method,
            chain,
            status: "error",
            latency: Math.round(dur),
            statusCode: resp.status,
            errorCode: json?.error?.code,
            error: json?.error?.message,
            provider,
            runId: this.id,
          });
        }
      } catch (error) {
        const dur = now() - start;
        this.stats.http.avgLatencyMs = updateAvg(
          this.stats.http.avgLatencyMs,
          this.stats.http.success +
            this.stats.http.error +
            this.stats.http.limited,
          dur
        );
        this.stats.http.error++;
        this._logActivity("http", {
          method,
          chain,
          status: "error",
          latency: Math.round(dur),
          error: error.message,
          runId: this.id,
        });
      } finally {
        this.stats.http.inflight = Math.max(0, this.stats.http.inflight - 1);
        if (this.state === RunState.STOPPING) {
          this._finishStopWhenDrained();
        }
      }
    };

    this.httpTimer = setInterval(fireOnce, intervalMs);
  }

  _stopHttpLoad() {
    if (this.httpController) {
      this.httpController.stopped = true;
      this.httpController = null;
    }
    if (this.httpTimer) {
      clearInterval(this.httpTimer);
      this.httpTimer = null;
    }
  }

  _startWsLoad() {
    const wsConfig = this.config.ws;
    const chains = this.config.chains || getDefaultChains();
    const connections = wsConfig.connections || 2;
    const topics = wsConfig.topics || ["newHeads"];

    this.stats.ws = emptyWsStats();
    this.wsSockets = [];
    this.wsPendingSubscriptions.clear();

    for (let i = 0; i < connections; i++) {
      const chain = chains[i % chains.length];
      const profile = this.config.profile || "public";
      let url = `${location.origin.replace(
        /^http/,
        "ws"
      )}/ws/rpc/profile/${encodeURIComponent(profile)}/${encodeURIComponent(
        chain
      )}`;
      const ws = new WebSocket(url);

      ws.onopen = () => {
        this.stats.ws.open++;
        this._logActivity("websocket", {
          chain,
          status: "connected",
          runId: this.id,
        });

        for (const topic of topics) {
          const requestId = this.nextWsRequestId++;
          const subscribeMsg = {
            jsonrpc: "2.0",
            id: requestId,
            method: "eth_subscribe",
            params: [topic],
          };

          this.wsPendingSubscriptions.set(requestId, { ws, chain, topic });
          this.stats.ws.pending++;

          try {
            ws.send(JSON.stringify(subscribeMsg));

            this._logActivity("websocket", {
              method: "eth_subscribe",
              chain,
              status: "pending",
              topic,
              requestId,
              runId: this.id,
            });
          } catch (error) {
            this._finishWsSubscription(requestId, {
              status: "rejected",
              error: error.message || "Failed to send subscription request",
            });
          }
        }
      };

      ws.onclose = () => {
        this._rejectPendingForSocket(ws);
        this.stats.ws.open = Math.max(0, this.stats.ws.open - 1);
        this._logActivity("websocket", {
          chain,
          status: "disconnected",
          runId: this.id,
        });
      };

      ws.onerror = (error) => {
        this._logActivity("websocket", {
          chain,
          status: "error",
          error: error.message || "Connection error",
          runId: this.id,
        });
      };

      ws.onmessage = (event) => {
        this._handleWsMessage(ws, chain, event.data);
      };

      this.wsSockets.push(ws);
    }
  }

  _stopWsLoad() {
    for (const ws of this.wsSockets) {
      try {
        ws.close();
      } catch (_e) {}
    }
    this.wsSockets = [];
    this.wsPendingSubscriptions.clear();
    this.stats.ws.pending = 0;
    this.stats.ws.open = 0;
  }

  _handleWsMessage(ws, chain, rawData) {
    let data;

    try {
      data = JSON.parse(rawData);
    } catch (_error) {
      this._logActivity("websocket", {
        chain,
        status: "message",
        method: "raw_data",
        runId: this.id,
      });
      return;
    }

    if (this.wsPendingSubscriptions.has(data.id)) {
      if (typeof data.result === "string" && data.result.length > 0) {
        this._finishWsSubscription(data.id, {
          status: "established",
          subscriptionId: data.result,
        });
      } else {
        this._finishWsSubscription(data.id, {
          status: "rejected",
          errorCode: data.error?.code,
          error: data.error?.message || "Subscription establishment failed",
        });
      }

      return;
    }

    if (data.method === "eth_subscription") {
      this._logActivity("websocket", {
        chain,
        status: "notification",
        method: data.method,
        subscriptionId: data.params?.subscription,
        runId: this.id,
      });
      return;
    }

    this._logActivity("websocket", {
      chain,
      status: "message",
      method: data.method || "response",
      id: data.id,
      runId: this.id,
    });
  }

  _finishWsSubscription(requestId, outcome) {
    const request = this.wsPendingSubscriptions.get(requestId);
    if (!request) return;

    this.wsPendingSubscriptions.delete(requestId);
    this.stats.ws.pending = Math.max(0, this.stats.ws.pending - 1);
    if (outcome.status === "established") this.stats.ws.established++;
    if (outcome.status === "rejected") this.stats.ws.error++;

    this._logActivity("websocket", {
      ...outcome,
      method: "eth_subscribe",
      chain: request.chain,
      topic: request.topic,
      requestId,
      runId: this.id,
    });
  }

  _rejectPendingForSocket(ws) {
    for (const [requestId, request] of this.wsPendingSubscriptions) {
      if (request.ws !== ws) continue;

      this._finishWsSubscription(requestId, {
        status: "rejected",
        error: "Connection closed before subscription establishment",
      });
    }
  }

  _logActivity(type, data) {
    if (activityCallback) {
      activityCallback({
        type,
        timestamp: Date.now(),
        runId: this.id,
        ...data,
      });
    }
  }
}

// SimulatorManager class - manages multiple simulation runs
class SimulatorManager {
  constructor() {
    this.runs = new Map();
  }

  startRun(config) {
    const run = new SimulatorRun(config, (runId) => this.runs.delete(runId));
    this.runs.set(run.id, run);

    try {
      run.start();
      return run;
    } catch (error) {
      run.stop();
      throw error;
    }
  }

  stopAllRuns() {
    const activeRuns = Array.from(this.runs.values());
    for (const run of activeRuns) {
      if (run.isActive()) {
        run.stop();
      }
    }
  }

  isRunning() {
    return Array.from(this.runs.values()).some((run) => run.isActive());
  }

  getActiveRuns() {
    return Array.from(this.runs.values()).filter((run) => run.isActive());
  }

  getAggregateStats() {
    const aggregate = {
      http: {
        success: 0,
        error: 0,
        limited: 0,
        avgLatencyMs: 0,
        inflight: 0,
      },
      ws: emptyWsStats(),
    };

    const activeRuns = this.getActiveRuns();
    if (activeRuns.length === 0) {
      return aggregate;
    }

    let totalLatency = 0;
    let totalHttpCalls = 0;

    for (const run of activeRuns) {
      const stats = run.getStats();
      aggregate.http.success += stats.http.success;
      aggregate.http.error += stats.http.error;
      aggregate.http.limited += stats.http.limited;
      aggregate.http.inflight += stats.http.inflight;
      aggregate.ws.open += stats.ws.open;
      aggregate.ws.pending += stats.ws.pending;
      aggregate.ws.established += stats.ws.established;
      aggregate.ws.error += stats.ws.error;

      const httpCalls =
        stats.http.success + stats.http.error + stats.http.limited;
      totalLatency += stats.http.avgLatencyMs * httpCalls;
      totalHttpCalls += httpCalls;
    }

    if (totalHttpCalls > 0) {
      aggregate.http.avgLatencyMs = totalLatency / totalHttpCalls;
    }

    return aggregate;
  }
}

// Initialize the global simulator manager
simulator = new SimulatorManager();

function getDefaultChains() {
  // Use chain names from available chains, fallback to ethereum if none available
  if (availableChains && availableChains.length > 0) {
    return availableChains.map((chain) => chain.name);
  }
  return ["ethereum"]; // Ethereum mainnet as fallback
}

export function setAvailableChains(chains) {
  availableChains = chains;
  console.log("Simulator: Set available chains to:", availableChains);
}

export function setActivityCallback(callback) {
  activityCallback = callback;
  console.log("Simulator: Activity callback set");
}

export function activeStats() {
  return simulator.getAggregateStats();
}

export function isRunning() {
  return simulator.isRunning();
}

export function startRun(config) {
  return simulator.startRun(config);
}

export function stopAllRuns() {
  return simulator.stopAllRuns();
}
