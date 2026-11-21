#!/usr/bin/env python3
"""Exercise a standalone Lasso release against local mock upstreams.

  smoke.py mock --profiles DIR              write profiles and serve mock upstreams until stopped
  smoke.py wait --url URL                   wait until every chain answers through Lasso
  smoke.py send --url URL                   check the hash Lasso computes for a raw transaction
  smoke.py run --release DIR --report FILE  start the release, wait, then sample its footprint

Every chain gets three mock upstreams answering in 20, 60 and 120 ms. The
profile `public` holds all chains, so requests go to /rpc/<chain_id>. On chain
8453 the first upstream is the transaction provider: it rejects every raw
transaction and reports any looked-up transaction as known, so Lasso answers a
send with the hash it computed itself.
"""

import argparse
import json
import os
import platform
import subprocess
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


def wait_for_chains(url, chains, started, deadline_s, alive=lambda: True):
    first = {}
    while len(first) < len(chains):
        if time.monotonic() - started > deadline_s or not alive():
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


def process_tree(root):
    rows = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,rss=,comm="], capture_output=True, text=True).stdout
    procs = {}
    for line in rows.splitlines():
        pid, ppid, rss, comm = line.split(None, 3)
        procs[int(pid)] = (int(ppid), int(rss), comm)
    tree = {root} if root in procs else set()
    grew = True
    while grew:
        grew = False
        for pid, (ppid, _rss, _comm) in procs.items():
            if ppid in tree and pid not in tree:
                tree.add(pid)
                grew = True
    return {pid: procs[pid] for pid in tree}


def cpu_seconds(pids):
    if platform.system() == "Linux":
        ticks = os.sysconf("SC_CLK_TCK")
        total = 0
        for pid in pids:
            try:
                fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
                total += int(fields[11]) + int(fields[12])
            except OSError:
                pass
        return total / ticks
    out = subprocess.run(["ps", "-o", "time=", "-p", ",".join(map(str, pids))], capture_output=True, text=True).stdout
    total = 0.0
    for value in out.split():
        parts = [float(p) for p in value.replace("-", ":").split(":")]
        total += sum(p * 60**i for i, p in enumerate(reversed(parts)))
    return total


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


def command_run(args):
    chains = CHAIN_IDS[: args.chains]
    work = Path(args.work).resolve()
    profiles = work / "profiles"
    write_profiles(profiles, chains, args.base_port)
    start_mocks(chains, args.base_port)
    env = {"PATH": "/usr/bin:/bin", "HOME": os.environ.get("HOME", str(work)), "PORT": str(args.port),
           "LASSO_PROFILES_DIR": str(profiles), "RELEASE_TMP": str(work / "tmp")}
    env.update(dict(item.split("=", 1) for item in args.env))
    log = open(work / "lasso.log", "w")
    started = time.monotonic()
    proc = subprocess.Popen([str(Path(args.release).resolve() / "bin/lasso"), "start"], env=env, cwd=work,
                            stdout=log, stderr=subprocess.STDOUT)
    samples = []
    stop_sampling = threading.Event()

    def sample(interval):
        while not stop_sampling.wait(interval):
            tree = process_tree(proc.pid)
            if tree:
                samples.append({"t": round(time.monotonic() - started, 2),
                                "rss_mb": round(sum(r for _p, r, _c in tree.values()) / 1024, 1),
                                "procs": sorted(os.path.basename(c) for _p, _r, c in tree.values())})

    sampler = threading.Thread(target=sample, args=(0.1,), daemon=True)
    sampler.start()
    try:
        first = wait_for_chains(f"http://127.0.0.1:{args.port}", chains, started, 120, lambda: proc.poll() is None)
        ready = time.monotonic() - started
        while time.monotonic() - started < ready + 10:
            time.sleep(0.1)
        stop_sampling.set()
        sampler.join()
        boot_peak = max(s["rss_mb"] for s in samples)
        stop_sampling.clear()
        sampler = threading.Thread(target=sample, args=(5,), daemon=True)
        sampler.start()
        idle_start = time.monotonic()
        cpu_start = cpu_seconds(list(process_tree(proc.pid)))
        time.sleep(args.idle)
        cpu_used = cpu_seconds(list(process_tree(proc.pid))) - cpu_start
        idle_s = time.monotonic() - idle_start
        stop_sampling.set()
        sampler.join()
        idle = [s for s in samples if s["t"] >= idle_start - started]
        report = {
            "system": f"{platform.system()} {platform.machine()}",
            "env": args.env,
            "first_answer_s": round(min(first.values()), 3),
            "all_chains_s": round(max(first.values()), 3),
            "boot_peak_rss_mb": boot_peak,
            "settled_rss_mb": sorted(s["rss_mb"] for s in idle)[len(idle) // 2],
            "idle_s": round(idle_s, 1),
            "idle_cpu_percent": round(100 * cpu_used / idle_s, 2),
            "processes": idle[-1]["procs"],
        }
        Path(args.report).write_text(json.dumps({**report, "samples": samples}, indent=2))
        print(json.dumps(report))
    finally:
        stop_sampling.set()
        proc.terminate()
        try:
            proc.wait(30)
        except subprocess.TimeoutExpired:
            proc.kill()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("mock", "wait", "send", "run"):
        p = sub.add_parser(name)
        p.add_argument("--chains", type=int, default=len(CHAIN_IDS))
        p.add_argument("--base-port", type=int, default=18100)
    sub.choices["mock"].add_argument("--profiles", required=True)
    sub.choices["wait"].add_argument("--url", default="http://127.0.0.1:4000")
    sub.choices["wait"].add_argument("--timeout", type=float, default=60)
    sub.choices["send"].add_argument("--url", default="http://127.0.0.1:4000")
    run = sub.choices["run"]
    run.add_argument("--release", required=True)
    run.add_argument("--report", required=True)
    run.add_argument("--work", default=".")
    run.add_argument("--port", type=int, default=4000)
    run.add_argument("--idle", type=float, default=120)
    run.add_argument("--env", action="append", default=[], help="KEY=VALUE passed to the release")
    args = parser.parse_args()
    {"mock": command_mock, "wait": command_wait, "send": command_send, "run": command_run}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
