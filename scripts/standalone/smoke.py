#!/usr/bin/env python3
"""Exercise a standalone Lasso release against local mock upstreams.

  smoke.py mock --profiles DIR              write profiles and serve mock upstreams until stopped
  smoke.py wait --url URL                   wait until every chain answers through Lasso
  smoke.py send --url URL                   check the hash Lasso computes for a raw transaction

Every chain gets three mock upstreams answering in 20, 60 and 120 ms. The
profile `public` holds all chains, so requests go to /rpc/<chain_id>. On chain
8453 the first upstream is the transaction provider: it rejects every raw
transaction and reports any looked-up transaction as known, so Lasso answers a
send with the hash it computed itself.
"""

import argparse
import json
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

CHAIN_IDS = [1, 10, 56, 100, 137, 250, 324, 8453, 42161, 43114, 59144, 81457, 534352]
LATENCIES_MS = [20, 60, 120]
SEND_CHAIN = 8453
RAW_TRANSACTION = "0x02f86c0180843b9aca0082520894111111111111111111111111111111111180c0"
# Keccak-256 of RAW_TRANSACTION, from `cast keccak`.
RAW_TRANSACTION_HASH = "0x051b28aab7d905fcd825527a911975d0e0dd82c2a56e9b813e2871647a2b3240"
EPOCH = 1_763_596_800
BLOCK_S = 2


def head():
    return 70_000_000 + int((time.time() - EPOCH) // BLOCK_S)


def block(number):
    tag = f"{number:064x}"
    return {
        "number": hex(number),
        "hash": "0x" + tag,
        "parentHash": "0x" + f"{number - 1:064x}",
        "timestamp": hex(EPOCH + (number - 70_000_000) * BLOCK_S),
        "gasLimit": hex(30_000_000),
        "gasUsed": "0x0",
        "baseFeePerGas": hex(30_000_000_000),
        "transactions": [],
        "uncles": [],
    }


def answer(chain_id, request):
    method = request.get("method")
    params = request.get("params") or []
    results = {
        "eth_chainId": hex(chain_id),
        "net_version": str(chain_id),
        "eth_syncing": False,
        "eth_blockNumber": hex(head()),
        "eth_gasPrice": hex(30_000_000_000),
    }
    if method == "eth_sendRawTransaction":
        return {"jsonrpc": "2.0", "id": request.get("id"), "error": {"code": -32602, "message": "invalid transaction"}}
    if method in results:
        result = results[method]
    elif method == "eth_getTransactionByHash":
        result = {"hash": params[0]}
    elif method in ("eth_getBlockByNumber", "eth_getBlockByHash"):
        tag = params[0] if params else "latest"
        result = block(head() if not str(tag).startswith("0x") or method.endswith("Hash") else int(tag, 16))
    else:
        result = "0x0"
    return {"jsonrpc": "2.0", "id": request.get("id"), "result": result}


def serve_upstream(port, chain_id, latency_ms):
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
            time.sleep(latency_ms / 1000)
            reply = [answer(chain_id, r) for r in body] if isinstance(body, list) else answer(chain_id, body)
            data = json.dumps(reply).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()


def start_mocks(chains, base_port):
    for k, chain_id in enumerate(chains):
        for i, latency in enumerate(LATENCIES_MS):
            serve_upstream(base_port + 3 * k + i, chain_id, latency)


def write_profiles(directory, chains, base_port):
    directory.mkdir(parents=True, exist_ok=True)
    lines = ["---", "name: Public RPC", "slug: public", "---", "chains:"]
    for k, chain_id in enumerate(chains):
        lines += [f"  chain_{chain_id}:", f"    chain_id: {chain_id}", "    block_time_ms: 2000"]
        if chain_id == SEND_CHAIN:
            lines += ["    transactions:", f'      providers: ["c{chain_id}_up1"]', "      fallback: none"]
        lines += ["    providers:"]
        for i in range(len(LATENCIES_MS)):
            lines += [f'      - id: "c{chain_id}_up{i + 1}"', f'        url: "http://127.0.0.1:{base_port + 3 * k + i}"']
    (directory / "public.yml").write_text("\n".join(lines) + "\n")


def rpc(url, method, timeout=2, params=()):
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": list(params)}).encode()
    request = urllib.request.Request(url, payload, {"content-type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read())


def wait_for_chains(url, chains, started, deadline_s):
    first = {}
    while len(first) < len(chains):
        if time.monotonic() - started > deadline_s:
            missing = sorted(set(chains) - set(first))
            raise SystemExit(f"chains never answered: {missing}")
        for chain_id in chains:
            if chain_id in first:
                continue
            try:
                reply = rpc(f"{url}/rpc/{chain_id}", "eth_blockNumber")
                if int(reply["result"], 16) > 0:
                    first[chain_id] = time.monotonic() - started
            except Exception:
                pass
        time.sleep(0.02)
    return first


def command_mock(args):
    write_profiles(Path(args.profiles), CHAIN_IDS[: args.chains], args.base_port)
    start_mocks(CHAIN_IDS[: args.chains], args.base_port)
    print("mock upstreams ready", flush=True)
    threading.Event().wait()


def command_wait(args):
    chains = CHAIN_IDS[: args.chains]
    first = wait_for_chains(args.url, chains, time.monotonic(), args.timeout)
    print(json.dumps({"chains": len(first), "slowest_s": round(max(first.values()), 3)}))


def command_send(args):
    reply = rpc(f"{args.url}/rpc/{SEND_CHAIN}", "eth_sendRawTransaction", timeout=10, params=[RAW_TRANSACTION])
    print(json.dumps(reply))
    if reply.get("result") != RAW_TRANSACTION_HASH:
        raise SystemExit(f"expected {RAW_TRANSACTION_HASH}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("mock", "wait", "send"):
        p = sub.add_parser(name)
        p.add_argument("--chains", type=int, default=len(CHAIN_IDS))
        p.add_argument("--base-port", type=int, default=18100)
    sub.choices["mock"].add_argument("--profiles", required=True)
    sub.choices["wait"].add_argument("--url", default="http://127.0.0.1:4000")
    sub.choices["wait"].add_argument("--timeout", type=float, default=60)
    sub.choices["send"].add_argument("--url", default="http://127.0.0.1:4000")
    args = parser.parse_args()
    {"mock": command_mock, "wait": command_wait, "send": command_send}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
