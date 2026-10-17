#!/usr/bin/env python3
"""Boot the release Compose recipe unchanged and route through its public pool."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import socket
import tempfile
import time
import urllib.parse
import urllib.request

from verify import run


# The README promises these mainnets and testnets without provider credentials.
README_CHAINS = {"1", "8453", "42161", "11155111", "84532", "421614"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compose", required=True, help="Local candidate recipe or published HTTPS download URL")
    parser.add_argument("--image", help="Candidate image override; omit to exercise the published recipe's default")
    parser.add_argument("--version", required=True)
    parser.add_argument("--report", required=True)
    args = parser.parse_args()
    report = {"compose": args.compose, "version": args.version, "requested_image": args.image, "chains": [], "result": "fail"}
    started = time.monotonic()
    secret, cookie = secrets.token_hex(64), secrets.token_hex(32)
    with tempfile.TemporaryDirectory(prefix="lasso-quickstart-") as directory:
        root = Path(directory)
        project = "lasso-quickstart-" + secrets.token_hex(4)
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("COMPOSE_", "LASSO_"))
               and key not in {"SECRET_KEY_BASE", "RELEASE_COOKIE", "PHX_HOST", "PHX_SCHEME"}}
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        env_file = root / ".env"
        env_file.touch(mode=0o600)
        env_file.write_text(f"SECRET_KEY_BASE={secret}\nRELEASE_COOKIE={cookie}\nLASSO_PORT={port}\n"
                            + (f"LASSO_IMAGE={args.image}\n" if args.image else ""))
        compose = ["docker", "compose", "--project-name", project, "--project-directory", directory,
                   "--env-file", str(env_file), "-f", str(root / "compose.yml")]

        def dc(*parts):
            return run(compose + list(parts), env=env)

        def request(path, payload=None):
            data = json.dumps(payload).encode() if payload is not None else None
            req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data,
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=20) as response:
                return json.load(response)

        try:
            if args.compose.startswith("https://"):
                with urllib.request.urlopen(args.compose, timeout=30) as response:
                    recipe = response.read()
                    report["download_url"] = urllib.parse.urlunsplit(
                        urllib.parse.urlsplit(response.url)._replace(query="", fragment=""))
            else:
                recipe = Path(args.compose).read_bytes()
            (root / "compose.yml").write_bytes(recipe)
            report["compose_sha256"] = hashlib.sha256(recipe).hexdigest()
            dc("up", "--detach", "--no-build", "--wait", "--wait-timeout", "90")
            cid = dc("ps", "--quiet", "lasso")
            info = json.loads(run(["docker", "inspect", cid]))[0]
            report.update(image=info["Config"]["Image"], image_id=info["Image"],
                          image_labels=info["Config"].get("Labels", {}))
            health = request("/api/health")
            report["health"] = health
            if health.get("status") != "healthy" or health.get("version") != args.version:
                raise RuntimeError("Versioned health check failed")
            chains = request("/api/chains")["chains"]
            if not README_CHAINS.issubset({str(chain["chain_id"]) for chain in chains}):
                raise RuntimeError("Chain inventory is missing a README mainnet or testnet")
            for index, chain in enumerate(chains, 1):
                slug = urllib.parse.quote(chain["chain_name"], safe="")
                payload = {"jsonrpc": "2.0", "id": index, "method": "eth_blockNumber", "params": []}
                entry = {"chain_id": chain["chain_id"], "chain": chain["chain_name"]}
                report["chains"].append(entry)
                try:
                    result = request(f"/rpc/fastest/{slug}?include_meta=body", payload)
                    entry["response"] = result
                    if (result.get("jsonrpc") != "2.0" or result.get("id") != index
                            or "error" in result or not isinstance(result.get("result"), str)
                            or not re.fullmatch(r"0x[1-9a-fA-F][0-9a-fA-F]*", result["result"])):
                        raise RuntimeError("Invalid eth_blockNumber response")
                    entry["result"] = "pass"
                    print(f"PASS {chain['chain_name']}: {result['result']}", flush=True)
                except Exception as error:
                    entry.update(result="fail", error=str(error))
            if any(chain["result"] != "pass" for chain in report["chains"]):
                raise RuntimeError("Bundled public pool failed to serve every chain")
            report["result"] = "pass"
        except Exception as error:
            report["error"] = str(error).replace(secret, "[redacted]").replace(cookie, "[redacted]")
        finally:
            if (root / "compose.yml").exists():
                try:
                    dc("down", "--volumes", "--timeout", "15")
                except Exception as error:
                    report.update(result="fail", cleanup_error=str(error))
            report["duration_seconds"] = round(time.monotonic() - started, 2)
            Path(args.report).write_text(json.dumps(report, indent=2) + "\n")
    if report["result"] != "pass":
        raise SystemExit(report.get("error", report.get("cleanup_error")))


if __name__ == "__main__":
    main()
