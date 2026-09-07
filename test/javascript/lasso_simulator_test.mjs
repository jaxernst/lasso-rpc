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
      releaseResponse({ok: true, status: 200, headers: new Headers(), json: async () =>
        outcome === 'success' ? {jsonrpc: '2.0', id: requestBody.id, result: '0x1'} :
        outcome === 'rpc-error' ? {jsonrpc: '2.0', id: requestBody.id, error: {code: -32000, message: 'failed'}} : null});
      const final = await completion;
      assert.equal(final.stats.http.success, outcome === 'success' ? 1 : 0);
      assert.equal(final.stats.http.error, outcome === 'success' ? 0 : 1);
      assert.equal(final.stats.http.inflight, 0);
      assert.equal(sim.isRunning(), false);
    } finally { sim.stopAllRuns(); globalThis.fetch = originalFetch; }
  });
}
