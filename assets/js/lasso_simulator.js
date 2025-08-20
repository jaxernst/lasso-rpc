let httpStop = null;
let wsSockets = [];
let availableChains = [];
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

function getDefaultChains() {
  // Use chain IDs from available chains, fallback to ethereum if none available
  if (availableChains && availableChains.length > 0) {
    return availableChains.map(chain => chain.id);
  }
  return ["1"]; // Ethereum mainnet as fallback
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
    console.log("JSON body:", jsonBody);
    console.log("JSON body length:", jsonBody.length);
    stats.http.inflight++;
    const start = now();
    try {
      const resp = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: jsonBody,
      });
      console.log("HTTP response:", resp.status, resp.statusText);
      const _json = await resp.json().catch(() => null);
      const dur = now() - start;
      stats.http.avgLatencyMs = updateAvg(
        stats.http.avgLatencyMs,
        stats.http.success + stats.http.error,
        dur
      );
      if (resp.ok) {
        stats.http.success++;
      } else {
        stats.http.error++;
      }
    } catch (_e) {
      const dur = now() - start;
      stats.http.avgLatencyMs = updateAvg(
        stats.http.avgLatencyMs,
        stats.http.success + stats.http.error,
        dur
      );
      stats.http.error++;
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
    )}/rpc/${encodeURIComponent(chain)}`;
    const ws = new WebSocket(url);

    ws.onopen = () => {
      stats.ws.open++;
      for (const topic of topics) {
        ws.send(
          JSON.stringify({
            jsonrpc: "2.0",
            id: Math.floor(Math.random() * 1e9),
            method: "eth_subscribe",
            params: [topic],
          })
        );
      }
    };

    ws.onclose = () => {
      stats.ws.open = Math.max(0, stats.ws.open - 1);
    };

    ws.onerror = () => {
      // passive
    };

    ws.onmessage = () => {
      // passive; the server will process and emit events already
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
