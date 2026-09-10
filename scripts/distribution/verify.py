#!/usr/bin/env python3
"""Verify a container through the downloadable Compose recipe; never build the app."""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import tempfile
import traceback
import time
import urllib.error
import urllib.request

from upstream import Upstream


def run(args, **kwargs):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)
    if result.returncode:
        # Container environment and command arguments can contain generated test secrets.
        raise RuntimeError(f"{args[0]} command failed (exit {result.returncode}): {result.stderr[-2000:]}")
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--compose", default=str(Path(__file__).resolve().parents[2] / "deployment/compose.release.yml"))
    parser.add_argument("--previous-image", help="Immutable previous release image for a policy-off upgrade check")
    parser.add_argument("--previous-version", help="Expected health version of the previous release")
    args = parser.parse_args()
    if bool(args.previous_image) != bool(args.previous_version):
        parser.error("--previous-image and --previous-version must be provided together")
    credential = secrets.token_hex(24)
    upstream = Upstream(credential)
    project = "lasso-dist-" + secrets.token_hex(4)
    checks = []
    started = time.time()
    cid = None
    report = {"image": args.image, "version": args.version, "revision": args.revision, "checks": checks}
    with tempfile.TemporaryDirectory(prefix="lasso-distribution-") as directory:
        root = Path(directory)
        shutil.copyfile(args.compose, root / "compose.yml")
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        env = dict(os.environ)
        # Isolate this installation from the caller's Compose configuration and secrets.
        for key in ["SECRET_KEY_BASE", "RELEASE_COOKIE", "LASSO_NODE_ID", "LASSO_IMAGE", "LASSO_PORT", "COMPOSE_FILE", "COMPOSE_PROJECT_NAME", "LASSO_TEST_CREDENTIAL"]:
            env.pop(key, None)
        secret = secrets.token_hex(64)
        cookie = secrets.token_hex(32)
        (root / ".env").write_text(f"SECRET_KEY_BASE={secret}\nRELEASE_COOKIE={cookie}\nLASSO_TEST_CREDENTIAL={credential}\nLASSO_IMAGE={args.image}\nLASSO_PORT={port}\n")
        (root / ".env").chmod(0o600)
        # This host entry connects the disposable controlled upstream to the container.
        (root / "test.override.json").write_text(json.dumps({"services": {"lasso": {"extra_hosts": ["host.docker.internal:host-gateway"]}}}))
        compose = ["docker", "compose", "--project-name", project, "--project-directory", directory, "--env-file", str(root / ".env"), "-f", str(root / "compose.yml"), "-f", str(root / "test.override.json")]

        def dc(*parts):
            return run(compose + list(parts), env=env)

        def record(name):
            checks.append(name)
            print("PASS " + name, flush=True)

        def request(path, payload=None, with_headers=False):
            data = json.dumps(payload).encode() if payload is not None else None
            req = urllib.request.Request(f"http://127.0.0.1:{port}" + path, data=data, headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=20) as response:
                    body = response.read().decode()
                    return (response.status, body, response.headers) if with_headers else (response.status, body)
            except urllib.error.HTTPError as error:
                return error.code, error.read().decode()

        def healthy(version=args.version):
            for _ in range(60):
                try:
                    status, body = request("/api/health")
                    if status == 200 and json.loads(body).get("version") == version:
                        return
                except (OSError, ValueError):
                    pass
                time.sleep(1)
            raise AssertionError("Container failed versioned health check")

        def execute(*parts, **kwargs):
            return run(["docker", "exec", cid] + list(parts), **kwargs)

        def rpc(expression):
            return execute("/app/bin/lasso", "rpc", expression)

        def write_profile(slug, content):
            run(["docker", "exec", "-i", cid, "sh", "-c", 'cat > "$1"', "sh", f"/data/config/profiles/{slug}.yml"], input=content)

        def profile(slug):
            return f'''---
name: Distribution {slug}
slug: {slug}
rps_limit: 2
---
chains:
  ethereum:
    chain_id: 1
    monitoring:
      probe_interval_ms: 60000
    websocket:
      subscribe_new_heads: true
    providers:
      - id: first
        url: http://host.docker.internal:{upstream.port}/first
        ws_url: ws://host.docker.internal:{upstream.port}/first
        priority: 1
        headers:
          X-Release-Test: ${{LASSO_TEST_CREDENTIAL}}
      - id: second
        url: http://host.docker.internal:{upstream.port}/second
        ws_url: ws://host.docker.internal:{upstream.port}/second
        priority: 2
        headers:
          X-Release-Test: ${{LASSO_TEST_CREDENTIAL}}
'''

        def install(image, version):
            env_file = root / ".env"
            lines = env_file.read_text().splitlines()
            env_file.write_text("\n".join(
                "LASSO_IMAGE=" + image if line.startswith("LASSO_IMAGE=") else line
                for line in lines) + "\n")
            dc("up", "--detach", "--no-build", "--force-recreate", "--wait", "--wait-timeout", "90")
            healthy(version)
            return dc("ps", "--quiet", "lasso")

        try:
            dc("config", "--quiet")
            if args.previous_image:
                assert "@sha256:" in args.previous_image, "Previous release must use an immutable digest"
                cid = install(args.previous_image, args.previous_version)
                previous_info = json.loads(run(["docker", "inspect", cid]))[0]
                previous_labels = previous_info["Config"].get("Labels", {})
                assert previous_labels["org.opencontainers.image.version"] == "v" + args.previous_version
                report["upgrade_from"] = {
                    "image": args.previous_image, "version": args.previous_version,
                    "revision": previous_labels["org.opencontainers.image.revision"]}
                write_profile("custom", profile("custom"))
                assert rpc("IO.inspect(Lasso.Config.ConfigStore.reload())") == ":ok"
                before_upgrade = {"jsonrpc": "2.0", "method": "eth_getBalance",
                                  "params": ["0x0000000000000000000000000000000000000001", "latest"], "id": 9}
                assert json.loads(request("/rpc/profile/custom/ethereum", before_upgrade)[1])["result"] == "0x0"
                assert rpc('Lasso.Benchmarking.Persistence.save_snapshot("custom", "ethereum", %{upgrade_probe: true}); IO.puts("saved")') == "saved"
                for image, version in [(args.image, args.version),
                                       (args.previous_image, args.previous_version),
                                       (args.image, args.version)]:
                    cid = install(image, version)
                    assert json.loads(request("/rpc/profile/custom/ethereum", before_upgrade)[1])["result"] == "0x0"
                    assert rpc('entries = Lasso.Benchmarking.Persistence.load_snapshots("custom", "ethereum", 10); IO.puts(Enum.any?(entries, &(&1["data"]["upgrade_probe"] == true)))') == "true"
                record("Previous release upgrade, policy-off rollback and forward recovery preserve profiles, routing and history")
            dc("up", "--detach", "--no-build", "--wait", "--wait-timeout", "90")
            cid = dc("ps", "--quiet", "lasso")
            healthy()
            record("Compose install from image without source or application build tools")
            info = json.loads(run(["docker", "inspect", cid]))[0]
            assert info["Config"]["User"] == "10001:10001"
            assert info["HostConfig"]["ReadonlyRootfs"]
            assert info["HostConfig"]["CapDrop"] == ["ALL"]
            assert "no-new-privileges:true" in info["HostConfig"]["SecurityOpt"]
            labels = info["Config"].get("Labels", {})
            assert labels["org.opencontainers.image.revision"] == args.revision
            assert labels["org.opencontainers.image.version"] == "v" + args.version
            report["architecture"] = json.loads(run(["docker", "image", "inspect", info["Image"]]))[0]["Architecture"]
            record("Version/revision identity, nonroot user, read-only root, restricted capabilities")
            status, body = request("/api/chains")
            assert status == 200 and len(json.loads(body)["chains"]) >= 1
            assert request("/dashboard")[0] == 200
            assert request("/favicon.svg")[0] == 200
            record("Bundled profiles, dashboard HTML, and favicon")
            write_profile("public", profile("public"))
            write_profile("custom", profile("custom"))
            execute("rm", "-f", "/data/config/profiles/testnet.yml")
            assert rpc("IO.inspect(Lasso.Config.ConfigStore.reload())") == ":ok"
            payload = {"jsonrpc": "2.0", "method": "eth_getBalance", "params": ["0x0000000000000000000000000000000000000001", "latest"], "id": 34}
            for path in ["/rpc/ethereum", "/rpc/profile/custom/ethereum", "/rpc/profile/custom/provider/first/ethereum"]:
                status, body = request(path, payload)
                assert status == 200 and json.loads(body).get("result") == "0x0", (path, status, body)
            assert upstream.authenticated > 0
            record("Custom YAML activation, namespaced routing, provider override, credential substitution")
            before = upstream.calls["/second"]
            upstream.fail_first = True
            for _ in range(4):
                status, body = request("/rpc/profile/custom/fastest/ethereum", payload)
                assert status == 200 and json.loads(body).get("result") == "0x0", (status, body)
            assert upstream.calls["/second"] > before
            upstream.fail_first = False
            record("HTTP ingress remains available with one provider failing HTTP and WebSocket dispatch")
            # Node's built-in WebSocket client requires no installed npm dependencies.
            ws = r'''
const assert = require('node:assert/strict');
const ws = new WebSocket(process.argv[1]);
const timer = setTimeout(() => { console.error('WebSocket RPC/subscription timed out'); process.exit(1); }, 20000);
let ordinary = false, subscription = false;
ws.onopen = () => ws.send(JSON.stringify({jsonrpc:'2.0',id:1,method:'eth_chainId',params:[]}));
ws.onmessage = event => {
  const data = JSON.parse(event.data);
  if(data.id === 1) { assert.equal(data.result, '0x1'); ordinary = true; ws.send(JSON.stringify({jsonrpc:'2.0',id:2,method:'eth_subscribe',params:['newHeads']})); }
  if(data.id === 2) { assert.equal(typeof data.result, 'string', JSON.stringify(data)); subscription = true; }
  if(data.id === 3) { assert.equal(data.result, true); clearTimeout(timer); ws.close(); }
  if(data.method === 'eth_subscription') { assert.ok(ordinary && subscription); assert.equal(data.params.result.number, '0x1000'); ws.send(JSON.stringify({jsonrpc:'2.0',id:3,method:'eth_unsubscribe',params:[data.params.subscription]})); }
};
ws.onerror = () => { console.error('WebSocket error'); process.exit(1); };
'''
            run(["node", "-e", ws, f"ws://127.0.0.1:{port}/ws/rpc/profile/custom/provider/second/ethereum"], timeout=25)
            record("WebSocket RPC, subscription acknowledgment, newHeads delivery, and unsubscribe")
            write_profile("shared", profile("shared"))
            assert rpc("IO.inspect(Lasso.Config.ConfigStore.reload())") == ":ok"
            for slug in ["shared", "public", "custom"]:
                assert json.loads(request(f"/rpc/profile/{slug}/ethereum", payload)[1])["result"] == "0x0"
                run(["node", "-e", ws, f"ws://127.0.0.1:{port}/ws/rpc/profile/{slug}/ethereum"], timeout=25)
            record("New profile reload reuses connected upstreams for HTTP and subscriptions; existing profiles remain available")
            for path, expected in [("/rpc/profile/missing/ethereum", 404), ("/rpc/provider/missing/ethereum", 400)]:
                status, body = request(path, payload)
                assert status == expected and "error" in json.loads(body)
            record("Invalid profile/provider client errors")
            write_profile("custom", profile("custom") + "\nunsupported_setting: true\n")
            answer = rpc('before = Lasso.Config.ConfigStore.route_generation(); result = Lasso.Config.ConfigStore.reload(); unless match?({:error, _}, result) and before == Lasso.Config.ConfigStore.route_generation(), do: raise("Invalid reload changed active config"); IO.puts("retained")')
            assert answer == "retained"
            assert json.loads(request("/rpc/profile/custom/ethereum", payload)[1])["result"] == "0x0"
            write_profile("custom", profile("custom"))
            assert rpc("IO.inspect(Lasso.Config.ConfigStore.reload())") == ":ok"
            record("Invalid reload preserves active generation and working RPC")
            assert rpc('Lasso.Benchmarking.Persistence.save_snapshot("custom", "ethereum", %{release_probe: true}); entries = Lasso.Benchmarking.Persistence.load_snapshots("custom", "ethereum", 1); unless Enum.any?(entries, &(&1["data"]["release_probe"] == true)), do: raise("Snapshot missing"); IO.puts("saved")') == "saved"
            previous = cid
            dc("up", "--detach", "--no-build", "--force-recreate", "--wait", "--wait-timeout", "90")
            cid = dc("ps", "--quiet", "lasso")
            assert cid != previous
            healthy()
            assert json.loads(request("/rpc/profile/custom/ethereum", payload)[1])["result"] == "0x0"
            assert rpc('entries = Lasso.Benchmarking.Persistence.load_snapshots("custom", "ethereum", 1); IO.puts(Enum.any?(entries, &(&1["data"]["release_probe"] == true)))') == "true"
            record("Container replacement preserves custom profiles and actual saved benchmark history")
            profiles = root / "profiles"
            profiles.mkdir()
            for slug in ["public", "custom"]:
                (profiles / (slug + ".yml")).write_text(profile(slug))
                (profiles / (slug + ".yml")).chmod(0o644)
            profiles.chmod(0o755)
            override = {"services": {"lasso": {"extra_hosts": ["host.docker.internal:host-gateway"], "environment": {"LASSO_PROFILES_DIR": "/profiles"}, "volumes": [{"type": "bind", "source": str(profiles), "target": "/profiles", "read_only": True}]}}}
            (root / "test.override.json").write_text(json.dumps(override))
            dc("up", "--detach", "--no-build", "--force-recreate", "--wait", "--wait-timeout", "90")
            cid = dc("ps", "--quiet", "lasso")
            healthy()
            assert rpc("IO.inspect(Lasso.Config.ConfigStore.reload())") == ":ok"
            assert json.loads(request("/rpc/profile/custom/ethereum", payload)[1])["result"] == "0x0"
            record("Read-only host-managed profiles boot, reload, and route successfully")
            assert rpc('IO.puts(is_nil(Process.whereis(Lasso.BlockPublication.Repo)))') == "true"
            record("Policy-off installation requires no PostgreSQL process or server")

            # Upgrade the same installed artifact to its optional journal configuration.
            override["services"]["publication-db"] = {
                "image": "postgres:16",
                "environment": {"POSTGRES_PASSWORD": credential, "POSTGRES_DB": "publication"},
                "healthcheck": {"test": ["CMD-SHELL", "pg_isready -U postgres -d publication"],
                                "interval": "1s", "timeout": "5s", "retries": 30}}
            override["services"]["lasso"]["environment"].update({
                "LASSO_BLOCK_PUBLICATION_DATABASE_URL": f"postgresql://postgres:{credential}@publication-db/publication",
                "LASSO_BLOCK_PUBLICATION_MEMBERS": "docker-local"})
            (root / "test.override.json").write_text(json.dumps(override))
            (root / "test.override.json").chmod(0o600)
            dc("up", "--detach", "--wait", "--wait-timeout", "90", "publication-db")
            migration = 'case Lasso.BlockPublication.Storage.migrate() do {:ok, _, _} -> IO.puts("journal-ready"); other -> raise inspect(other) end'
            for _ in range(2):
                assert "journal-ready" in dc("run", "--rm", "--no-deps", "lasso", "eval", migration)
            dc("up", "--detach", "--no-build", "--force-recreate", "--wait", "--wait-timeout", "90", "lasso")
            cid = dc("ps", "--quiet", "lasso")
            healthy()
            record("Optional journal installation and idempotent migrations from the release command")

            def set_global(enabled):
                contents = profile("custom")
                if enabled:
                    contents = contents.replace("    chain_id: 1", "    chain_id: 1\n    head_policy: global")
                (profiles / "custom.yml").write_text(contents)
                assert rpc("IO.inspect(Lasso.Config.ConfigStore.reload())") == ":ok"

            def choice(minimum):
                call = {"jsonrpc": "2.0", "method": "eth_getBlockByNumber", "params": ["latest", False], "id": 91}
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    status, body, headers = request("/rpc/profile/custom/ethereum?include_meta=headers", call, with_headers=True)
                    result = json.loads(body)
                    if status == 200 and result.get("result") and int(result["result"]["number"], 16) >= minimum:
                        encoded = headers["x-lasso-meta"]
                        meta = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
                        assert meta["head_policy"]["policy"] == "global"
                        assert meta["head_policy"]["scope"] == "profile_chain_fleet"
                        assert meta["head_policy"]["block_hash"] == result["result"]["hash"]
                        assert meta["service_profile_id"] == "custom"
                        return result["result"]
                    time.sleep(0.25)
                raise AssertionError("No qualified publication at the expected floor")

            upstream.height += 1
            set_global(True)
            first = choice(upstream.height)
            selector = {"blockHash": first["hash"], "requireCanonical": True}
            pinned = dict(payload, params=[payload["params"][0], selector])
            assert json.loads(request("/rpc/profile/custom/ethereum", pinned)[1])["result"] == "0x0"
            assert ("pinned", "eth_getBalance", selector) in upstream.events
            unknown = dict(payload, params=[payload["params"][0], {"blockHash": "0x" + "f" * 64, "requireCanonical": True}])
            assert "error" in json.loads(request("/rpc/profile/custom/ethereum", unknown)[1])
            record("File-profile global publication, correlated metadata, pinned execution and unknown-hash rejection")
            ws_pinned = r'''
const assert = require('node:assert/strict');
const ws = new WebSocket(process.argv[1]);
const hash = process.argv[2], number = process.argv[3];
const timer = setTimeout(() => { console.error('Pinned WebSocket query timed out'); process.exit(1); }, 15000);
const send = (id, method, params) => ws.send(JSON.stringify({jsonrpc:'2.0', id, method, params}));
ws.onopen = () => send(1, 'eth_getBlockByNumber', ['latest', false]);
ws.onmessage = event => {
  const data = JSON.parse(event.data);
  if (data.id === 1) {
    assert.equal(data.result?.hash, hash); assert.equal(data.result.number, number);
    send(2, 'eth_getBalance', ['0x0000000000000000000000000000000000000001', {blockHash:hash,requireCanonical:true}]);
  } else if (data.id === 2) {
    assert.equal(data.result, '0x0');
    send(3, 'eth_getBalance', ['0x0000000000000000000000000000000000000001', {blockHash:'0x'+'f'.repeat(64),requireCanonical:true}]);
  } else if (data.id === 3) {
    assert.ok(data.error && data.error.code < 0); clearTimeout(timer); ws.close();
  } else { throw new Error('Unexpected WebSocket response'); }
};
ws.onerror = () => { console.error('Pinned WebSocket error'); process.exit(1); };
'''
            run(["node", "-e", ws_pinned, f"ws://127.0.0.1:{port}/ws/rpc/profile/custom/ethereum", first["hash"], first["number"]], timeout=20)
            record("WebSocket published block choice, pinned state and unknown-hash rejection")

            dc("stop", "publication-db")
            assert choice(int(first["number"], 16))["hash"] == first["hash"]
            dc("start", "publication-db")
            upstream.height += 1
            second = choice(upstream.height)
            assert int(second["number"], 16) > int(first["number"], 16)
            record("Database connection recovery preserves the floor and permits subsequent advancement")
            old_boot = rpc('IO.puts(Lasso.BlockPublication.Gate.boot())')
            dc("up", "--detach", "--no-build", "--force-recreate", "--wait", "--wait-timeout", "90", "lasso")
            cid = dc("ps", "--quiet", "lasso")
            healthy()
            assert rpc('IO.puts(Lasso.BlockPublication.Gate.boot())') != old_boot
            assert int(choice(upstream.height)["number"], 16) >= int(second["number"], 16)
            record("Graceful container replacement recovers retained publication and admits a new boot")
            set_global(False)
            rpc('case Lasso.BlockPublication.Operator.disable({"custom", 1}) do {:ok, _} -> :ok; other -> raise inspect(other) end')
            for _ in range(120):
                if rpc('state = Lasso.BlockPublication.Postgres.get({"custom", 1}); IO.puts(state["phase"])') == "disabled":
                    break
                time.sleep(0.25)
            else:
                raise AssertionError("Coordinated disable did not complete")
            assert rpc('IO.puts(Lasso.BlockPublication.Postgres.get({"custom", 1})["minimum_height"])') == str(upstream.height)
            set_global(True)
            rpc('case Lasso.BlockPublication.Postgres.configure({"custom", 1}, "global", 12_000) do {:ok, _} -> :ok; other -> raise inspect(other) end')
            assert int(choice(upstream.height)["number"], 16) >= int(second["number"], 16)
            record("Disable and reenable retain the acknowledged floor")

            logs = subprocess.run(["docker", "logs", cid], text=True, capture_output=True, check=True)
            surfaces = request("/dashboard/custom")[1] + logs.stdout + logs.stderr
            assert all(value not in surfaces for value in [credential, secret, cookie])
            record("Generated credentials absent from inspected dashboard HTML and runtime logs")
            report["result"] = "pass"
        except Exception as error:
            message = str(error) or traceback.format_exc()
            for value in [credential, secret, cookie]:
                message = message.replace(value, "[redacted]")
            report.update(result="fail", error=message, upstream_events=upstream.events)
            if cid:
                logs = subprocess.run(["docker", "logs", "--tail", "100", cid], text=True, capture_output=True)
                diagnostic = logs.stdout + logs.stderr
                for value in [credential, secret, cookie]:
                    diagnostic = diagnostic.replace(value, "[redacted]")
                Path(args.report + ".log").write_text(diagnostic)
            raise RuntimeError(message) from None
        finally:
            report["duration_seconds"] = round(time.time() - started, 2)
            Path(args.report).write_text(json.dumps(report, indent=2) + "\n")
            try:
                dc("down", "--volumes", "--timeout", "15")
            finally:
                upstream.close()


if __name__ == "__main__":
    main()
