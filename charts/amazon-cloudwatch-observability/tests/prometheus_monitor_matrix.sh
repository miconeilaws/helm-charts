#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT
#
# Validates otelPrometheusMonitor (ServiceMonitor/PodMonitor scraping) wiring:
#   - one switch, independent of otelContainerInsights;
#   - the chart never renders the community SM/PM CRDs; the operator creates them
#     (--manage-prometheus-crds) with matching operator RBAC;
#   - both agents get a Target Allocator with prometheusCR discovery and read-only RBAC;
#   - with otelContainerInsights off, each agent's config holds only the SM/PM pipeline;
#   - with both on, no component is defined twice and the shared definitions match;
#   - the SM/PM series carry cloudwatch.solution k8s-otel-prometheus-monitors.
#
# This is a template-level test (helm template only); it does not deploy to a cluster.
# The operator's create-if-missing behavior is covered by the operator's pkg/crdmanager
# tests and by cluster testing.
#
# Run from the repo root:
#     bash charts/amazon-cloudwatch-observability/tests/prometheus_monitor_matrix.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
N='\033[0m'

pass_count=0
fail_count=0

MON='--set otelPrometheusMonitor.enabled=true'
CI='--set otelContainerInsights.enabled=true'

SM_CRD='^[[:space:]]*name: servicemonitors\.monitoring\.coreos\.com$'
PM_CRD='^[[:space:]]*name: podmonitors\.monitoring\.coreos\.com$'
# Target Allocator ClusterRole rules (read-only CRD watch and SM/PM discovery).
TA_CRD_RBAC='resources: \["customresourcedefinitions"\]'
TA_SM_PM_RBAC='resources: \["podmonitors", "servicemonitors"\]'
# Operator ClusterRole rule (create-if-missing) and the flag that turns it on.
OP_CRD_RBAC='resources: \[ "customresourcedefinitions" \]'
OP_CRD_VERBS='verbs: \[ "create","get","list","watch" \]'
OP_FLAG='"--manage-prometheus-crds"'

# render <args...> -> echoes the rendered manifests
render() {
    # shellcheck disable=SC2068
    helm template t "$CHART_DIR" \
        --kube-version 1.35.0 \
        --set region=us-west-2 \
        --set clusterName=test-cluster $@ 2>&1
}

pass() { printf "${G}PASS${N} %s\n" "$1"; pass_count=$((pass_count+1)); }
fail() { printf "${R}FAIL${N} %s\n" "$1"; fail_count=$((fail_count+1)); }

# expect_count <desc> <pattern> <expected-count> <render-args...>
expect_count() {
    local desc="$1" pattern="$2" want="$3"; shift 3
    local out got
    out="$(render "$@")" || { fail "$desc (helm error) $out"; return; }
    got="$(printf '%s\n' "$out" | grep -cE "$pattern" || true)"
    if [[ "$got" == "$want" ]]; then
        pass "$desc ($got == $want)"
    else
        fail "$desc (got $got, want $want) [$*]"
    fi
}

# expect_py <desc> <python-check> <render-args...>
# Runs a Python check over the rendered manifests. The check gets `agents`, a dict of
# AmazonCloudWatchAgent name -> {"spec": spec, "otel": parsed otelConfig or {}}, and
# `raw`, the agent name -> otelConfig string. It prints "ok" or a failure reason.
expect_py() {
    local desc="$1" check="$2"; shift 2
    local out res
    out="$(render "$@")" || { fail "$desc (helm error) $out"; return; }
    res="$(printf '%s\n' "$out" | CHECK="$check" python3 -c '
import os, sys, yaml

class UniqueKeyLoader(yaml.SafeLoader):
    pass

def no_duplicates(loader, node, deep=False):
    keys = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in keys:
            raise ValueError("duplicate key %r" % (key,))
        keys.add(key)
    return loader.construct_mapping(node, deep)

UniqueKeyLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, no_duplicates)

agents, raw = {}, {}
for d in yaml.safe_load_all(sys.stdin):
    if not d or d.get("kind") != "AmazonCloudWatchAgent":
        continue
    oc = d["spec"].get("otelConfig") or ""
    raw[d["metadata"]["name"]] = oc
    agents[d["metadata"]["name"]] = {"spec": d["spec"], "otel": yaml.load(oc, Loader=UniqueKeyLoader) if oc else {}}

PIPE = "metrics/cw_k8s_ci_v0_prometheuscr"
SCOPE = "transform/cw_k8s_ci_v0_set_scope_prometheuscr"
NODE, SCRAPER = "cloudwatch-agent", "cloudwatch-agent-cluster-scraper"

def env(agent):
    return {e["name"] for e in agents[agent]["spec"].get("env") or []}

try:
    exec(os.environ["CHECK"])
except Exception as e:
    print("error: %s" % e)
')" || true
    if [[ "$res" == "ok" ]]; then
        pass "$desc"
    else
        fail "$desc: $res [$*]"
    fi
}

printf "${Y}== off by default ==${N}\n"
expect_count "default => no Target Allocator"        'targetAllocator:' 0
expect_count "default => no operator flag"           "$OP_FLAG" 0
expect_count "default => no operator CRD RBAC"       "$OP_CRD_RBAC" 0
expect_count "default => no TA CRD RBAC"             "$TA_CRD_RBAC" 0
expect_count "default => no cluster-scraper agent"   'name: cloudwatch-agent-cluster-scraper$' 0
expect_count "otelCI only => no Target Allocator"    'targetAllocator:' 0 $CI
expect_count "otelCI only => no operator flag"       "$OP_FLAG" 0 $CI
expect_count "otelCI only => no TA CRD RBAC"         "$TA_CRD_RBAC" 0 $CI
# The old otelContainerInsights.prometheusScrape key is gone and does nothing.
expect_count "removed prometheusScrape.enabled is ignored" 'targetAllocator:' 0 $CI --set otelContainerInsights.prometheusScrape.enabled=true

printf "\n${Y}== chart never renders the SM/PM CRDs ==${N}\n"
expect_count "monitor on => no ServiceMonitor CRD"          "$SM_CRD" 0 $MON
expect_count "monitor on => no PodMonitor CRD"              "$PM_CRD" 0 $MON
expect_count "monitor + otelCI => no CRD objects at all"    'kind: CustomResourceDefinition' 0 $MON $CI

printf "\n${Y}== operator --manage-prometheus-crds and RBAC follow otelPrometheusMonitor ==${N}\n"
for extra in "" "$CI"; do
    label="monitor on${extra:+ + otelCI}"
    expect_count "$label => operator flag"                        "$OP_FLAG" 1 $MON $extra
    expect_count "$label => operator CRD RBAC"                    "$OP_CRD_RBAC" 1 $MON $extra
    expect_count "$label => operator CRD verbs (no update/patch/delete)" "$OP_CRD_VERBS" 1 $MON $extra
    expect_count "$label => TA CRD watch RBAC"                    "$TA_CRD_RBAC" 1 $MON $extra
    expect_count "$label => TA SM/PM RBAC"                        "$TA_SM_PM_RBAC" 1 $MON $extra
    expect_count "$label => TA on both agents"                    'targetAllocator:' 2 $MON $extra
    expect_count "$label => prometheusCR on both agents"          'prometheusCR:' 2 $MON $extra
    expect_count "$label => per-node on the per-node agent"       'allocationStrategy: "per-node"' 1 $MON $extra
    expect_count "$label => consistent-hashing on the cluster-scraper" 'allocationStrategy: "consistent-hashing"' 1 $MON $extra
    expect_count "$label => scraperRole only on the cluster-scraper"   'scraperRole: cluster-scraper' 1 $MON $extra
    expect_count "$label => no monitor selectors"                 'onitorSelector:' 0 $MON $extra
done
# A Target Allocator enabled directly on an agent keeps consistent-hashing.
expect_count "direct TA => consistent-hashing" 'allocationStrategy: "consistent-hashing"' 1 \
    --set agent.prometheus.targetAllocator.enabled=true --set agent.prometheus.targetAllocator.prometheusCR.enabled=true

printf "\n${Y}== otelPrometheusMonitor without otelContainerInsights ==${N}\n"
expect_py "both agents render with only the SM/PM pipeline" '
for a in (NODE, SCRAPER):
    pipes = sorted(agents[a]["otel"]["service"]["pipelines"])
    assert pipes == [PIPE], "%s pipelines %s" % (a, pipes)
print("ok")' $MON
expect_py "no other otelCI components or env" '
for a in (NODE, SCRAPER):
    o = agents[a]["otel"]
    p = o["service"]["pipelines"][PIPE]
    for section in ("receivers", "processors", "exporters"):
        assert sorted(o[section]) == sorted(p[section]), "%s %s not limited to the pipeline" % (a, section)
    assert "OTEL_CI_VERSION" not in env(a), "%s has OTEL_CI_VERSION" % a
    assert "POD_NAME" in env(a), "%s has no POD_NAME" % a
print("ok")' $MON
expect_py "service.extensions are exactly the exporters' authenticators" '
for a in (NODE, SCRAPER):
    o = agents[a]["otel"]
    auths = sorted({e["auth"]["authenticator"] for e in o["exporters"].values() if "auth" in e})
    assert sorted(o["service"]["extensions"]) == auths, "%s extensions %s, want %s" % (a, o["service"]["extensions"], auths)
    assert sorted(o["extensions"]) == auths, "%s extension definitions %s" % (a, sorted(o["extensions"]))
print("ok")' $MON
expect_py "renders on AKS" '
for a in (NODE, SCRAPER):
    assert list(agents[a]["otel"]["service"]["pipelines"]) == [PIPE], a
print("ok")' $MON --set k8sMode=AKS --set roleArn=arn:aws:iam::111111111111:role/x

printf "\n${Y}== otelPrometheusMonitor with otelContainerInsights ==${N}\n"
expect_py "no component or key defined twice (otelConfig parses with unique keys)" '
for a in (NODE, SCRAPER):
    o = agents[a]["otel"]
    assert PIPE in o["service"]["pipelines"], "%s has no %s" % (a, PIPE)
    assert len(o["service"]["pipelines"]) > 1, "%s lost its otelCI pipelines" % a
print("ok")' $MON $CI
expect_py "service.extensions has every authenticator, once" '
for a in (NODE, SCRAPER):
    o = agents[a]["otel"]
    ext = o["service"]["extensions"]
    assert len(ext) == len(set(ext)), "%s duplicate extensions %s" % (a, ext)
    for e in o["exporters"].values():
        if "auth" in e:
            assert e["auth"]["authenticator"] in ext, "%s missing %s" % (a, e["auth"]["authenticator"])
print("ok")' $MON $CI

# The components the SM/PM pipeline uses must be the same with and without otelCI.
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
render $MON > "$tmp_dir/mon_only.yaml"
render $MON $CI > "$tmp_dir/mon_ci.yaml"
same="$(python3 - "$tmp_dir/mon_only.yaml" "$tmp_dir/mon_ci.yaml" <<'EOF'
import sys, yaml
def load(path):
    out = {}
    for d in yaml.safe_load_all(open(path)):
        if d and d.get("kind") == "AmazonCloudWatchAgent" and d["spec"].get("otelConfig"):
            out[d["metadata"]["name"]] = yaml.safe_load(d["spec"]["otelConfig"])
    return out
a, b = load(sys.argv[1]), load(sys.argv[2])
bad = []
for agent, o in a.items():
    for section in ("receivers", "processors", "exporters", "extensions"):
        for name, comp in (o.get(section) or {}).items():
            if b[agent][section].get(name) != comp:
                bad.append("%s %s/%s" % (agent, section, name))
print("ok" if not bad else "differ: " + ", ".join(bad))
EOF
)"
if [[ "$same" == "ok" ]]; then pass "SM/PM components identical with and without otelCI"; else fail "SM/PM components identical with and without otelCI: $same"; fi

printf "\n${Y}== cloudwatch.solution and cloudwatch.pipeline ==${N}\n"
for extra in "" "$CI"; do
    expect_py "SM/PM pipelines set k8s-otel-prometheus-monitors / prometheus-monitors${extra:+ (with otelCI)}" '
for a in (NODE, SCRAPER):
    o = agents[a]["otel"]
    assert SCOPE in o["service"]["pipelines"][PIPE]["processors"], "%s pipeline lacks %s" % (a, SCOPE)
    stmts = " ".join(s for ms in o["processors"][SCOPE]["metric_statements"] for s in ms["statements"])
    assert "\"cloudwatch.solution\"], \"k8s-otel-prometheus-monitors\"" in stmts, "%s solution: %s" % (a, stmts)
    assert "\"cloudwatch.pipeline\"], \"prometheus-monitors\"" in stmts, "%s pipeline: %s" % (a, stmts)
print("ok")' $MON $extra
done
expect_py "otelCI pipelines keep k8s-otel-container-insights" '
for a in (NODE, SCRAPER):
    for name, comp in agents[a]["otel"]["processors"].items():
        if name == SCOPE or not name.startswith("transform/cw_k8s_ci_v0_set_scope"):
            continue
        stmts = " ".join(s for ms in comp.get("metric_statements", []) + comp.get("log_statements", []) for s in ms["statements"])
        assert "k8s-otel-prometheus-monitors" not in stmts, "%s %s uses the monitors solution" % (a, name)
print("ok")' $MON $CI

printf "\n${Y}== units set on both SM/PM pipelines ==${N}\n"
# The per-node and cluster-scraper pipelines normalize units the same way, so a
# monitor's units do not depend on which agent scrapes it.
for extra in "" "$CI"; do
    expect_py "set_unit on both SM/PM pipelines${extra:+ (with otelCI)}" '
for a in (NODE, SCRAPER):
    assert "transform/cw_k8s_ci_v0_set_unit" in agents[a]["otel"]["service"]["pipelines"][PIPE]["processors"], a
print("ok")' $MON $extra
done

printf "\n${Y}== Summary ==${N}\n"
printf "passed: ${G}%s${N}, failed: ${R}%s${N}\n" "$pass_count" "$fail_count"
[[ "$fail_count" -eq 0 ]]
