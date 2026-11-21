#!/usr/bin/env python3
"""Exercise a standalone Lasso release against local mock upstreams.

  smoke.py mock --profiles DIR   write a profile and serve the mock upstreams until stopped
  smoke.py wait --url URL        wait until the chain answers through Lasso
  smoke.py send --url URL        check the hash Lasso computes for a raw transaction

The profile `public` holds one chain with two upstreams, the fewest a chain with
a transaction provider can have, so requests go to /rpc/8453. Both reject every
raw transaction and report any looked-up transaction as known, so Lasso answers
a send with the hash it computed itself.
"""

import argparse
import json
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

CHAIN_ID = 8453
UPSTREAM_PORTS = [18100, 18101]
RAW_TRANSACTION = "0x02f86c0180843b9aca0082520894111111111111111111111111111111111180c0"
# Keccak-256 of RAW_TRANSACTION, from `cast keccak`.
RAW_TRANSACTION_HASH = "0x051b28aab7d905fcd825527a911975d0e0dd82c2a56e9b813e2871647a2b3240"
EPOCH = 1_763_596_800
BLOCK_S = 2


def head():
    return 70_000_000 + int((time.time() - EPOCH) // BLOCK_S)


def block(number):
    return {
        "number": hex(number),
        "hash": "0x" + f"{number:064x}",
        "parentHash": "0x" + f"{number - 1:064x}",
        "timestamp": hex(EPOCH + (number - 70_000_000) * BLOCK_S),
        "gasLimit": hex(30_000_000),
        "gasUsed": "0x0",
        "baseFeePerGas": hex(30_000_000_000),
        "transactions": [],
        "uncles": [],
    }


def answer(request):
    method = request.get("method")
    params = request.get("params") or []
    results = {
        "eth_chainId": hex(CHAIN_ID),
        "net_version": str(CHAIN_ID),
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


class Upstream(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        reply = [answer(r) for r in body] if isinstance(body, list) else answer(body)
        data = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_args):
        pass


def rpc(url, method, timeout=2, params=()):
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": list(params)}).encode()
    request = urllib.request.Request(url, payload, {"content-type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read())


def command_mock(args):
    directory = Path(args.profiles)
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "public.yml").write_text(
        f"""---
name: Public RPC
slug: public
---
chains:
  chain_{CHAIN_ID}:
    chain_id: {CHAIN_ID}
    block_time_ms: 2000
    transactions:
      providers: ["up1"]
      fallback: none
    providers:
      - id: "up1"
        url: "http://127.0.0.1:{UPSTREAM_PORTS[0]}"
      - id: "up2"
        url: "http://127.0.0.1:{UPSTREAM_PORTS[1]}"
"""
    )
    servers = [ThreadingHTTPServer(("127.0.0.1", port), Upstream) for port in UPSTREAM_PORTS]
    for server in servers:
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
    print("mock upstreams ready", flush=True)
    threading.Event().wait()


def command_wait(args):
    deadline = time.monotonic() + args.timeout
    while True:
        try:
            if int(rpc(f"{args.url}/rpc/{CHAIN_ID}", "eth_blockNumber")["result"], 16) > 0:
                return
        except Exception:
            pass
        if time.monotonic() > deadline:
            raise SystemExit(f"chain {CHAIN_ID} never answered through {args.url}")
        time.sleep(0.05)


def command_send(args):
    reply = rpc(f"{args.url}/rpc/{CHAIN_ID}", "eth_sendRawTransaction", timeout=10, params=[RAW_TRANSACTION])
    print(json.dumps(reply))
    if reply.get("result") != RAW_TRANSACTION_HASH:
        raise SystemExit(f"expected {RAW_TRANSACTION_HASH}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("mock").add_argument("--profiles", required=True)
    wait = sub.add_parser("wait")
    wait.add_argument("--url", default="http://127.0.0.1:4000")
    wait.add_argument("--timeout", type=float, default=60)
    sub.add_parser("send").add_argument("--url", default="http://127.0.0.1:4000")
    args = parser.parse_args()
    {"mock": command_mock, "wait": command_wait, "send": command_send}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
