import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const source = await readFile(new URL('../../assets/js/lasso_simulator.js', import.meta.url), 'utf8');

for (const outcome of ['success', 'rpc-error', 'malformed']) {
  test(`retains the final ${outcome} outcome while stopping`, async () => {
    const sim = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}#${outcome}`);
    let releaseResponse;
    let started;
    const requestStarted = new Promise(resolve => { started = resolve; });
    let requestBody;
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (url, options) => {
      assert.equal(url, '/rpc/profile/local/fastest/1');
      requestBody = JSON.parse(options.body);
      started();
      return new Promise(resolve => { releaseResponse = resolve; });
    };
    let finished;
    const completion = new Promise(resolve => { finished = resolve; });
    sim.setActivityCallback(event => {
      if (event.type === 'run' && event.status === 'stopped') finished(event);
    });
    try {
      sim.startRun({profile: 'local', chains: [1], strategy: 'fastest',
        http: {enabled: true, methods: ['eth_blockNumber'], rps: 1000, concurrency: 1},
        ws: {enabled: false}});
      await requestStarted;
      sim.stopAllRuns();
      assert.equal(sim.isRunning(), true);
      assert.equal(sim.isRunning('other'), false);
      assert.equal(sim.activeStats('local').http.inflight, 1);
      assert.equal(sim.activeStats('other').http.inflight, 0);
      releaseResponse({ok: true, status: 200, headers: new Headers(), json: async () =>
        outcome === 'success' ? {jsonrpc: '2.0', id: requestBody.id, result: '0x1'} :
        outcome === 'rpc-error' ? {jsonrpc: '2.0', id: requestBody.id, error: {code: -32000, message: 'failed'}} : null});
      const final = await completion;
      assert.equal(final.profile, "local");
      assert.equal(final.stats.http.success, outcome === 'success' ? 1 : 0);
      assert.equal(final.stats.http.error, outcome === 'success' ? 0 : 1);
      assert.equal(final.stats.http.inflight, 0);
      assert.equal(sim.isRunning(), false);
    } finally { sim.stopAllRuns(); globalThis.fetch = originalFetch; }
  });
}

test('WebSocket tester URLs retain the selected profile, chain, and strategy', async () => {
  const sim = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}#ws-routing`);
  const previousSocket = globalThis.WebSocket;
  const previousLocation = globalThis.location;
  const urls = [];
  globalThis.location = {origin: 'http://localhost:4000'};
  globalThis.WebSocket = class {
    constructor(url) { urls.push(url); }
    close() { this.onclose?.(); }
  };
  try {
    sim.startRun({profile: 'local', chains: [1], strategy: 'fastest',
      http: {enabled: false}, ws: {enabled: true, connections: 2}});
    assert.deepEqual(urls, [
      'ws://localhost:4000/ws/rpc/profile/local/fastest/1',
      'ws://localhost:4000/ws/rpc/profile/local/fastest/1'
    ]);
  } finally {
    sim.stopAllRuns();
    globalThis.WebSocket = previousSocket;
    globalThis.location = previousLocation;
  }
});

test('switching profiles with identical chains stops the prior tester and clears its display', async () => {
  const sim = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}#profile-switch`);
  const app = await readFile(new URL('../../assets/js/app.js', import.meta.url), 'utf8');
  const hookSource = app.slice(app.indexOf('const SimulatorControl = '), app.indexOf('// Draggable Network Viewport Hook'));
  const hook = new Function('LassoSim', `${hookSource}; return SimulatorControl;`)(sim);
  const previousSocket = globalThis.WebSocket;
  const previousLocation = globalThis.location;
  const events = [];
  let profile = 'first';
  globalThis.location = {origin: 'http://localhost:4000'};
  globalThis.WebSocket = class { close() { this.onclose?.(); } };
  Object.assign(hook, {
    el: {isConnected: true, getAttribute: name => name === 'data-profile' ? profile : '[{"name":1}]'},
    handleEvent() {},
    pushEvent(name, payload) { events.push([name, payload]); }
  });
  try {
    hook.mounted();
    // Prevent network-state notifications in this isolated hook test.
    hook.el.isConnected = false;
    sim.startRun({profile: 'first', chains: [1], http: {enabled: false}, ws: {enabled: true}});
    assert.equal(sim.isRunning('first'), true);
    profile = 'second';
    hook.updated();
    assert.equal(sim.isRunning('first'), false);
    assert.equal(hook.profile, 'second');
    assert.deepEqual(hook.recentCalls, []);
    assert.ok(events.some(([name, payload]) => name === 'sim_running' && payload.running === false));
    assert.ok(events.some(([name, payload]) => name === 'update_recent_calls' && payload.calls.length === 0));
    hook.trackActivity({profile: 'first', type: 'run', status: 'stopped'});
    assert.deepEqual(hook.recentCalls, []);
  } finally {
    hook.destroyed();
    globalThis.WebSocket = previousSocket;
    globalThis.location = previousLocation;
  }
});
