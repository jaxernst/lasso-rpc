let httpStop = null;
let wsSockets = [];
let availableChains = [];
let activityCallback = null;
let stats = {
  http: { success: 0, error: 0, avgLatencyMs: 0, inflight: 0 },
  ws: { open: 0 },
};

function now() {
  return performance && performance.now ? performance.now() : Date.now();
}

function updateAvg(avg, count, value) {
  const n = count + 1;
  return avg + (value - avg) / n;
}

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

function logActivity(type, data) {
  if (activityCallback) {
    activityCallback({
      type,
      timestamp: Date.now(),
      ...data
    });
  }
}

function getDefaultChains() {
  // Use chain names from available chains, fallback to ethereum if none available
  if (availableChains && availableChains.length > 0) {
    return availableChains.map(chain => chain.name);
  }
  return ["ethereum"]; // Ethereum mainnet as fallback
}

export function startHttpLoad({
  chains = getDefaultChains(),
  methods = ["eth_blockNumber"],
  rps = 5,
  concurrency = 4,
  durationMs = 30000,
  strategy = null,
} = {}) {
  stopHttpLoad();
  stats.http = { success: 0, error: 0, avgLatencyMs: 0, inflight: 0 };

  const intervalMs = Math.max(50, Math.floor(1000 / Math.max(1, rps)));
  const controller = { stopped: false };

  async function fireOnce() {
    if (controller.stopped) return;
    if (stats.http.inflight >= concurrency) return;

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

    const qs = strategy ? `?strategy=${encodeURIComponent(strategy)}` : "";
    const url = `/rpc/${encodeURIComponent(chain)}${qs}`;

    const jsonBody = JSON.stringify(body);
    console.log("Making HTTP request to:", url, "with body:", body);
    stats.http.inflight++;
    const start = now();
    
    // Log the start of the request
    logActivity("http", {
      method,
      chain,
      status: "started",
      url: url
    });
    
    try {
      const resp = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: jsonBody,
      });
      const _json = await resp.json().catch(() => null);
      const dur = now() - start;
      stats.http.avgLatencyMs = updateAvg(
        stats.http.avgLatencyMs,
        stats.http.success + stats.http.error,
        dur
      );
      
      if (resp.ok) {
        stats.http.success++;
        logActivity("http", {
          method,
          chain,
          status: "success",
          latency: Math.round(dur),
          statusCode: resp.status
        });
      } else {
        stats.http.error++;
        logActivity("http", {
          method,
          chain,
          status: "error",
          latency: Math.round(dur),
          statusCode: resp.status
        });
      }
    } catch (error) {
      const dur = now() - start;
      stats.http.avgLatencyMs = updateAvg(
        stats.http.avgLatencyMs,
        stats.http.success + stats.http.error,
        dur
      );
      stats.http.error++;
      logActivity("http", {
        method,
        chain,
        status: "error",
        latency: Math.round(dur),
        error: error.message
      });
    } finally {
      stats.http.inflight--;
    }
  }

  const tid = setInterval(fireOnce, intervalMs);
  httpStop = () => {
    controller.stopped = true;
    clearInterval(tid);
  };

  if (durationMs && durationMs > 0) {
    setTimeout(() => stopHttpLoad(), durationMs);
  }
}

export function stopHttpLoad() {
  if (httpStop) {
    httpStop();
    httpStop = null;
  }
}

export function startWsLoad({
  chains = getDefaultChains(),
  connections = 2,
  topics = ["newHeads"],
  durationMs = 30000,
} = {}) {
  stopWsLoad();
  stats.ws.open = 0;
  wsSockets = [];

  for (let i = 0; i < connections; i++) {
    const chain = chains[i % chains.length];
    const url = `${location.origin.replace(
      /^http/,
      "ws"
    )}/ws/rpc/${encodeURIComponent(chain)}`;
    const ws = new WebSocket(url);

    ws.onopen = () => {
      stats.ws.open++;
      logActivity("websocket", {
        chain,
        status: "connected",
        url: url
      });
      
      for (const topic of topics) {
        const subscribeMsg = {
          jsonrpc: "2.0",
          id: Math.floor(Math.random() * 1e9),
          method: "eth_subscribe",
          params: [topic],
        };
        ws.send(JSON.stringify(subscribeMsg));
        
        logActivity("websocket", {
          method: "eth_subscribe",
          chain,
          status: "subscribed",
          topic: topic
        });
      }
    };

    ws.onclose = () => {
      stats.ws.open = Math.max(0, stats.ws.open - 1);
      logActivity("websocket", {
        chain,
        status: "disconnected"
      });
    };

    ws.onerror = (error) => {
      logActivity("websocket", {
        chain,
        status: "error",
        error: error.message || "Connection error"
      });
    };

    ws.onmessage = (event) => {
      // Parse and log incoming messages
      try {
        const data = JSON.parse(event.data);
        logActivity("websocket", {
          chain,
          status: "message",
          method: data.method || "notification",
          id: data.id
        });
      } catch (e) {
        // Silent - just log raw message activity
        logActivity("websocket", {
          chain,
          status: "message",
          method: "raw_data"
        });
      }
    };

    wsSockets.push(ws);
  }

  if (durationMs && durationMs > 0) {
    setTimeout(() => stopWsLoad(), durationMs);
  }
}

export function stopWsLoad() {
  for (const ws of wsSockets) {
    try {
      ws.close();
    } catch (_e) {}
  }
  wsSockets = [];
  stats.ws.open = 0;
}

export function activeStats() {
  return JSON.parse(JSON.stringify(stats));
}
