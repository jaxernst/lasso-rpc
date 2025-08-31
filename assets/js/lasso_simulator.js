// Run states
const RunState = {
  STARTING: 'STARTING',
  RUNNING: 'RUNNING', 
  STOPPING: 'STOPPING',
  STOPPED: 'STOPPED'
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

function generateId() {
  return `run_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
}

// SimulatorRun class - represents a single simulation run
class SimulatorRun {
  constructor(config) {
    this.id = config.id || generateId();
    this.config = { ...config };
    this.state = RunState.STARTING;
    this.startTime = Date.now();
    this.endTime = null;
    
    // HTTP state
    this.httpController = null;
    this.httpTimer = null;
    
    // WebSocket state  
    this.wsSockets = [];
    
    // Per-run statistics
    this.stats = {
      http: { success: 0, error: 0, avgLatencyMs: 0, inflight: 0 },
      ws: { open: 0 }
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
      setTimeout(() => this.stop(), this.config.duration);
    }
    
    this._logActivity('run', { status: 'started', config: this.config });
  }

  stop() {
    if (this.state === RunState.STOPPED || this.state === RunState.STOPPING) {
      return;
    }
    
    this.state = RunState.STOPPING;
    this.endTime = Date.now();
    
    // Stop HTTP load
    this._stopHttpLoad();
    
    // Stop WebSocket load  
    this._stopWsLoad();
    
    this.state = RunState.STOPPED;
    this._logActivity('run', { status: 'stopped', duration: this.endTime - this.startTime });
  }

  isActive() {
    return this.state === RunState.RUNNING || this.state === RunState.STARTING;
  }

  getStats() {
    return JSON.parse(JSON.stringify(this.stats));
  }

  _startHttpLoad() {
    const httpConfig = this.config.http;
    const chains = this.config.chains || getDefaultChains();
    const methods = httpConfig.methods || ['eth_blockNumber'];
    const rps = httpConfig.rps || 5;
    const concurrency = httpConfig.concurrency || 4;
    const strategy = this.config.strategy;
    
    this.stats.http = { success: 0, error: 0, avgLatencyMs: 0, inflight: 0 };
    
    const intervalMs = Math.max(50, Math.floor(1000 / Math.max(1, rps)));
    this.httpController = { stopped: false };

    const fireOnce = async () => {
      if (this.httpController.stopped || this.state !== RunState.RUNNING) return;
      if (this.stats.http.inflight >= concurrency) return;

      const chain = chains[Math.floor(Math.random() * chains.length)];
      const method = methods[Math.floor(Math.random() * methods.length)];

      const body = {
        jsonrpc: "2.0",
        id: Math.floor(Math.random() * 1e9),
        method,
        params: method === "eth_getBalance" 
          ? ["0x0000000000000000000000000000000000000000", "latest"] 
          : [],
      };

      // Use strategy-specific endpoints as defined in the router
      const url = strategy 
        ? `/rpc/${encodeURIComponent(strategy)}/${encodeURIComponent(chain)}`
        : `/rpc/${encodeURIComponent(chain)}`;

      this.stats.http.inflight++;
      const start = now();
      
      this._logActivity("http", {
        method, chain, status: "started", url, runId: this.id
      });
      
      try {
        const resp = await fetch(url, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
        });
        
        const _json = await resp.json().catch(() => null);
        const dur = now() - start;
        
        this.stats.http.avgLatencyMs = updateAvg(
          this.stats.http.avgLatencyMs,
          this.stats.http.success + this.stats.http.error,
          dur
        );
        
        if (resp.ok) {
          this.stats.http.success++;
          this._logActivity("http", {
            method, chain, status: "success", latency: Math.round(dur),
            statusCode: resp.status, runId: this.id
          });
        } else {
          this.stats.http.error++;
          this._logActivity("http", {
            method, chain, status: "error", latency: Math.round(dur),
            statusCode: resp.status, runId: this.id
          });
        }
      } catch (error) {
        const dur = now() - start;
        this.stats.http.avgLatencyMs = updateAvg(
          this.stats.http.avgLatencyMs,
          this.stats.http.success + this.stats.http.error,
          dur
        );
        this.stats.http.error++;
        this._logActivity("http", {
          method, chain, status: "error", latency: Math.round(dur),
          error: error.message, runId: this.id
        });
      } finally {
        this.stats.http.inflight--;
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
    const topics = wsConfig.topics || ['newHeads'];
    
    this.stats.ws.open = 0;
    this.wsSockets = [];

    for (let i = 0; i < connections; i++) {
      const chain = chains[i % chains.length];
      const url = `${location.origin.replace(/^http/, "ws")}/ws/rpc/${encodeURIComponent(chain)}`;
      const ws = new WebSocket(url);

      ws.onopen = () => {
        this.stats.ws.open++;
        this._logActivity("websocket", {
          chain, status: "connected", url, runId: this.id
        });
        
        for (const topic of topics) {
          const subscribeMsg = {
            jsonrpc: "2.0",
            id: Math.floor(Math.random() * 1e9),
            method: "eth_subscribe",
            params: [topic],
          };
          ws.send(JSON.stringify(subscribeMsg));
          
          this._logActivity("websocket", {
            method: "eth_subscribe", chain, status: "subscribed",
            topic, runId: this.id
          });
        }
      };

      ws.onclose = () => {
        this.stats.ws.open = Math.max(0, this.stats.ws.open - 1);
        this._logActivity("websocket", {
          chain, status: "disconnected", runId: this.id
        });
      };

      ws.onerror = (error) => {
        this._logActivity("websocket", {
          chain, status: "error", error: error.message || "Connection error",
          runId: this.id
        });
      };

      ws.onmessage = (event) => {
        try {
          const data = JSON.parse(event.data);
          this._logActivity("websocket", {
            chain, status: "message", method: data.method || "notification",
            id: data.id, runId: this.id
          });
        } catch (e) {
          this._logActivity("websocket", {
            chain, status: "message", method: "raw_data", runId: this.id
          });
        }
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
    this.stats.ws.open = 0;
  }

  _logActivity(type, data) {
    if (activityCallback) {
      activityCallback({
        type,
        timestamp: Date.now(),
        runId: this.id,
        ...data
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
    const run = new SimulatorRun(config);
    this.runs.set(run.id, run);
    
    try {
      run.start();
      return run;
    } catch (error) {
      this.runs.delete(run.id);
      throw error;
    }
  }

  stopRun(runId) {
    const run = this.runs.get(runId);
    if (run) {
      run.stop();
      // Keep run in registry for a moment to allow final stats collection
      setTimeout(() => this.runs.delete(runId), 1000);
      return true;
    }
    return false;
  }

  stopAllRuns() {
    const activeRuns = Array.from(this.runs.values());
    for (const run of activeRuns) {
      if (run.isActive()) {
        run.stop();
      }
    }
    // Clean up stopped runs after a delay
    setTimeout(() => {
      for (const [runId, run] of this.runs.entries()) {
        if (run.state === RunState.STOPPED) {
          this.runs.delete(runId);
        }
      }
    }, 1000);
  }

  isRunning() {
    return Array.from(this.runs.values()).some(run => run.isActive());
  }

  getActiveRuns() {
    return Array.from(this.runs.values()).filter(run => run.isActive());
  }

  getAllRuns() {
    return Array.from(this.runs.values());
  }

  getAggregateStats() {
    const aggregate = {
      http: { success: 0, error: 0, avgLatencyMs: 0, inflight: 0 },
      ws: { open: 0 }
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
      aggregate.http.inflight += stats.http.inflight;
      aggregate.ws.open += stats.ws.open;

      const httpCalls = stats.http.success + stats.http.error;
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
    return availableChains.map(chain => chain.name);
  }
  return ["ethereum"]; // Ethereum mainnet as fallback
}

// Public API functions that maintain backward compatibility
export function setAvailableChains(chains) {
  availableChains = chains;
  console.log("Simulator: Set available chains to:", availableChains);
}

export function getAvailableChains() {
  return availableChains;
}

export function setActivityCallback(callback) {
  activityCallback = callback;
  console.log("Simulator: Activity callback set");
}

// Backward compatibility functions - convert to new run-based API
export function startHttpLoad(opts = {}) {
  // Stop any existing runs first to maintain old behavior
  simulator.stopAllRuns();
  
  const config = {
    chains: opts.chains || getDefaultChains(),
    strategy: opts.strategy,
    duration: opts.durationMs || 30000,
    http: {
      enabled: true,
      methods: opts.methods || ["eth_blockNumber"],
      rps: opts.rps || 5,
      concurrency: opts.concurrency || 4
    },
    ws: {
      enabled: false
    }
  };
  
  return simulator.startRun(config);
}

export function stopHttpLoad() {
  simulator.stopAllRuns();
}

export function startWsLoad(opts = {}) {
  // Stop any existing runs first to maintain old behavior
  simulator.stopAllRuns();
  
  const config = {
    chains: opts.chains || getDefaultChains(),
    duration: opts.durationMs || 30000,
    http: {
      enabled: false
    },
    ws: {
      enabled: true,
      connections: opts.connections || 2,
      topics: opts.topics || ["newHeads"]
    }
  };
  
  return simulator.startRun(config);
}

export function stopWsLoad() {
  simulator.stopAllRuns();
}

export function activeStats() {
  return simulator.getAggregateStats();
}

// New API functions for enhanced control
export function isRunning() {
  return simulator.isRunning();
}

export function startRun(config) {
  return simulator.startRun(config);
}

export function stopRun(runId) {
  return simulator.stopRun(runId);
}

export function stopAllRuns() {
  return simulator.stopAllRuns();
}

export function getActiveRuns() {
  return simulator.getActiveRuns();
}

export function getAllRuns() {
  return simulator.getAllRuns();
}

export function getSimulator() {
  return simulator;
}
