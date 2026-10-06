#!/usr/bin/env python3
"""Evaluate dashboard regressions using promtool (Prometheus 3.5+)."""
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DASHBOARD = json.loads((ROOT / "docs/grafana/lasso-core-v1.json").read_text())
PANELS = {panel["id"]: panel for panel in DASHBOARD["panels"]}
VARIABLES = dict(job="lasso", node=".*", profile="public", chain="1",
                 provider="drpc", method=".*", origin="client", __rate_interval="2m", __range="1h")


def expression(panel, **overrides):
    variables = VARIABLES | overrides
    return re.sub(r"\$([A-Za-z_][A-Za-z_0-9]*)",
                  lambda match: variables.get(match[1], ".*"),
                  PANELS[panel]["targets"][0]["expr"])


def series(name, labels, values):
    labels = ",".join(f'{key}="{value}"' for key, value in labels.items())
    return dict(series=f"{name}{{{labels}}}", values=values)


ROUTE = dict(job="lasso", instance="node-a", profile="public", chain="1",
             provider="drpc", method="eth_call", origin="client", transport="http")
COMPLETIONS = series("lasso_rpc_request_duration_seconds_count",
                     ROUTE | dict(outcome="success"), "0+60x5")
FAILOVERS = series("lasso_rpc_failovers_total", ROUTE, "0+30x5")
PHYSICAL = dict(job="lasso", instance="node-a", chain="1", instance_id="1:drpc:abc")
WS = series("lasso_websocket_connections_total", PHYSICAL | dict(event="connected"), "0+60x5")
MAPPINGS = [series("lasso_provider_info", PHYSICAL | dict(profile=profile, provider=provider),
                   "1+0x5") for profile, provider in
            [("public", "drpc"), ("private", "drpc"), ("public", "alias")]]


def case(name, inputs, expr, expected):
    return dict(name=name, interval="1m", input_series=inputs,
                promql_expr_test=[dict(expr=expr, eval_time="5m", exp_samples=expected)])


def sample(labels, value):
    return dict(labels=labels, value=value)


WS_SAMPLE = [sample('{chain="1",instance_id="1:drpc:abc",event="connected"}', 1)]
TESTS = [
    case("zero failovers with traffic", [COMPLETIONS], expression(12), [sample("{}", 0)]),
    case("positive failover ratio", [COMPLETIONS, FAILOVERS], expression(12), [sample("{}", 0.5)]),
    case("absent exporter stays absent", [], expression(12), []),
    case("selected route maps to physical connection", [WS, *MAPPINGS], expression(22), WS_SAMPLE),
    case("shared routes count physical events once", [WS, *MAPPINGS],
         expression(22, profile=".*", provider=".*"), WS_SAMPLE),
    case("unmatched route stays absent", [WS, *MAPPINGS], expression(22, provider="alchemy"), []),
    case("unmatched profile stays absent", [WS, *MAPPINGS], expression(22, profile="missing"), []),
    case("another node cannot supply the mapping", [WS, *[
        series("lasso_provider_info", PHYSICAL | dict(instance="node-b", profile="public", provider="drpc"), "1+0x5")
    ]], expression(22), []),
]


TOTALS = dict(job="lasso", instance="node-a", profile="public", chain="1", origin="client")
ATTEMPT = dict(job="lasso", instance="node-a", profile="public", chain="1", provider="drpc",
               transport="http", outcome="service_failure", category="rate_limit")
TESTS.extend([
    case("exact route totals give the success ratio", [
        series("lasso_rpc_route_requests_total", TOTALS | dict(outcome="success"), "0+45x5"),
        series("lasso_rpc_route_requests_total", TOTALS | dict(outcome="error"), "0+15x5"),
    ], expression(3), [sample("{}", 0.75)]),
    case("attempt diagnostics separate client from system traffic", [
        series("lasso_upstream_attempts_total", ATTEMPT | dict(origin="client"), "0+60x5"),
        series("lasso_upstream_attempts_total", ATTEMPT | dict(origin="system"), "0+600x5"),
    ], expression(9), [sample('{chain="1",provider="drpc",outcome="service_failure"}', 1)]),
])


LONG_IDS = ["1:" + "a" * 63 + ":" + suffix for suffix in ["0123456789ab", "fedcba987654"]]
LONG_WS = [series("lasso_websocket_connections_total", PHYSICAL | dict(instance_id=id, event="connected"),
                  f"0+{rate}x5") for id, rate in zip(LONG_IDS, [60, 120])]
LONG_MAPS = [series("lasso_provider_info", PHYSICAL | dict(instance_id=id, profile="public", provider="drpc"),
                    "1+0x5") for id in LONG_IDS]
TESTS.append(case("long credential-distinct physical instances stay separate", [*LONG_WS, *LONG_MAPS],
                  expression(22), [sample(f'{{chain="1",instance_id="{id}",event="connected"}}', rate)
                                   for id, rate in zip(LONG_IDS, [1, 2])]))


LONG_PROVIDER = "a" * 64 + "first"
LONG_PROFILE = "p" * 64 + "public"
LONG_ROUTE = ROUTE | dict(provider=LONG_PROVIDER, profile=LONG_PROFILE)
TESTS.extend([
    case("long configured route filters retain completions", [
        series("lasso_rpc_request_duration_seconds_count", LONG_ROUTE | dict(outcome="success"), "0+60x5")
    ], expression(12, provider=LONG_PROVIDER, profile=LONG_PROFILE), [sample("{}", 0)]),
    case("long route mapping selects physical connection", [WS,
        series("lasso_provider_info", PHYSICAL | dict(provider=LONG_PROVIDER, profile=LONG_PROFILE), "1+0x5")
    ], expression(22, provider=LONG_PROVIDER, profile=LONG_PROFILE), WS_SAMPLE),
])



def bounded_identifier(value):
    raw = value.encode("utf-8")
    return value if len(raw) <= 128 else "sha256:" + base64.urlsafe_b64encode(hashlib.sha256(raw).digest()).decode().rstrip("=")


HASH_PROFILE = bounded_identifier("p" * 129)
HASH_PROVIDERS = [bounded_identifier("a" * 129 + suffix) for suffix in ["first", "second"]]
for provider in HASH_PROVIDERS:
    route = ROUTE | dict(profile=HASH_PROFILE, provider=provider)
    TESTS.append(case("hashed route filters retain completion evidence " + provider, [
        series("lasso_rpc_request_duration_seconds_count", route | dict(outcome="success"), "0+60x5")
    ], expression(12, profile=HASH_PROFILE, provider=provider), [sample("{}", 0)]))
TESTS.append(case("hashed route mapping selects physical connection", [WS,
    series("lasso_provider_info", PHYSICAL | dict(profile=HASH_PROFILE, provider=HASH_PROVIDERS[0]), "1+0x5")
], expression(22, profile=HASH_PROFILE, provider=HASH_PROVIDERS[0]), WS_SAMPLE))


def main():
    promtool = sys.argv[1] if len(sys.argv) > 1 else "promtool"
    with tempfile.TemporaryDirectory(prefix="lasso-promql-") as directory:
        path = Path(directory)
        rules = []
        for panel in DASHBOARD["panels"]:
            for target in panel.get("targets", []):
                if "expr" in target:
                    expr = re.sub(r"\$([A-Za-z_][A-Za-z_0-9]*)",
                                  lambda match: VARIABLES.get(match[1], ".*"), target["expr"])
                    rules.append(dict(record=f"dashboard_panel_{panel['id']}_{target['refId']}", expr=expr))
        (path / "rules.json").write_text(json.dumps(dict(groups=[dict(name="dashboard", rules=rules)])))
        (path / "tests.json").write_text(json.dumps(dict(rule_files=[], tests=TESTS)))
        subprocess.run([promtool, "check", "rules", str(path / "rules.json")], check=True)
        subprocess.run([promtool, "test", "rules", str(path / "tests.json")], check=True)
    print(f"Parsed {len(rules)} dashboard expressions; evaluated {len(TESTS)} regression scenarios.")


if __name__ == "__main__":
    main()
