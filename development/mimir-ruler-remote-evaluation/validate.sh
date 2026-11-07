#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only

# Validates that the ruler's rule detail headers show up on the query-frontend "query stats" log
# lines, with both the Mimir query engine and the Prometheus engine. Run ./compose-up.sh -d first,
# so the image is built from the local source.

set -euo pipefail

docker_compose() {
    if [ -x "$(command -v docker-compose)" ]; then
        docker-compose "$@"
    else
        docker compose "$@"
    fi
}

SCRIPT_DIR=$(cd "$(dirname -- "$0")" && pwd)
COMPOSE=(-f "${SCRIPT_DIR}/docker-compose.yml")
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-120}

# Each expected line is: rule name|type|namespace|group.
EXPECTED=(
    "checkout:up:sum|recording|team-a_checkout.yaml|availability"
    "CheckoutDown|alerting|team-a_checkout.yaml|availability"
    "payments:up:sum|recording|team-b_payments.yaml|availability"
    "payments:request_duration_seconds:p99|recording|team-b_payments.yaml|team-b/payments/latency"
)

query_stats() {
    docker_compose "${COMPOSE[@]}" logs --no-log-prefix mimir 2>/dev/null | grep 'msg="query stats"' || true
}

field() {
    sed -nE "s/.* $1=([^ ]*).*/\1/p" <<<"$2"
}

metric() {
    curl -s localhost:8001/metrics | awk -v m="$1" '$1 == m { print $2; found = 1 } END { if (!found) print 0 }'
}

run_scenario() {
    local name=$1 query_engine=$2 frontend_use_mqe=$3 expected_engine_metric=$4 unexpected_engine_metric=$5

    echo "=== ${name}: -querier.query-engine=${query_engine}, query-frontend uses the Mimir query engine: ${frontend_use_mqe}"
    docker_compose "${COMPOSE[@]}" down --timeout 5 >/dev/null 2>&1
    QUERY_ENGINE=${query_engine} FRONTEND_USE_MQE=${frontend_use_mqe} docker_compose "${COMPOSE[@]}" up -d >/dev/null 2>&1

    local deadline=$((SECONDS + TIMEOUT_SECONDS)) missing
    while true; do
        missing=()
        local stats
        stats=$(query_stats)
        for expected in "${EXPECTED[@]}"; do
            grep -qF "header_x_rule_name=${expected%%|*} " <<<"${stats}" || missing+=("${expected%%|*}")
        done
        # The ruler restores the alerts' for state on the group's second evaluation.
        grep -qF 'ALERTS_FOR_STATE' <<<"${stats}" || missing+=("ALERTS_FOR_STATE restore query")
        [ ${#missing[@]} -eq 0 ] && break
        if [ ${SECONDS} -ge ${deadline} ]; then
            echo "FAIL: no query stats found for: ${missing[*]}"
            return 1
        fi
        sleep 2
    done

    local failed=0 stats line actual
    stats=$(query_stats)
    printf '%-40s %-10s %-12s %-22s %s\n' "X-Rule-Name" "X-Rule-Type" "X-Rule-Source" "X-Rule-Namespace" "X-Rule-Group"
    for expected in "${EXPECTED[@]}"; do
        line=$(grep -F "header_x_rule_name=${expected%%|*} " <<<"${stats}" | tail -1)
        actual="$(field header_x_rule_name "${line}")|$(field header_x_rule_type "${line}")|$(field header_x_rule_namespace "${line}")|$(field header_x_rule_group "${line}")"
        printf '%-40s %-10s %-12s %-22s %s\n' "$(field header_x_rule_name "${line}")" "$(field header_x_rule_type "${line}")" "$(field header_x_rule_source "${line}")" "$(field header_x_rule_namespace "${line}")" "$(field header_x_rule_group "${line}")"
        if [ "${actual}" != "${expected}" ] || [ "$(field header_x_rule_source "${line}")" != "mimir-ruler" ]; then
            echo "FAIL: expected ${expected}|mimir-ruler, got ${actual}|$(field header_x_rule_source "${line}")"
            failed=1
        fi
    done

    # Restoring the alerts' for state isn't a rule evaluation, so those queries carry no rule headers.
    local restore
    restore=$(grep -F 'ALERTS_FOR_STATE' <<<"${stats}" || true)
    if [ -z "${restore}" ]; then
        echo "FAIL: no ALERTS_FOR_STATE restore query found"
        failed=1
    elif grep -q 'header_x_rule_' <<<"${restore}"; then
        echo "FAIL: ALERTS_FOR_STATE restore query carries rule detail headers"
        failed=1
    else
        echo "ALERTS_FOR_STATE restore query: no rule detail headers, as expected"
    fi

    local expected_count unexpected_count
    expected_count=$(metric "${expected_engine_metric}")
    unexpected_count=$(metric "${unexpected_engine_metric}")
    echo "Engine check: ${expected_engine_metric} = ${expected_count}, ${unexpected_engine_metric} = ${unexpected_count}"
    if [ "${expected_count%.*}" -eq 0 ] || [ "${unexpected_count%.*}" -ne 0 ]; then
        echo "FAIL: queries didn't run on the expected engine"
        failed=1
    fi

    [ ${failed} -eq 0 ] && echo "PASS: ${name}"
    echo
    return ${failed}
}

run_disabled_scenario() {
    local name="Rule detail headers disabled"

    echo "=== ${name}: -ruler.query-frontend.enable-rule-detail-headers=false"
    docker_compose "${COMPOSE[@]}" down --timeout 5 >/dev/null 2>&1
    ENABLE_RULE_DETAIL_HEADERS=false docker_compose "${COMPOSE[@]}" up -d >/dev/null 2>&1

    local deadline=$((SECONDS + TIMEOUT_SECONDS)) stats evaluated
    while true; do
        stats=$(query_stats)
        evaluated=$(grep -c 'path=/prometheus/api/v1/query ' <<<"${stats}" || true)
        [ "${evaluated}" -ge ${#EXPECTED[@]} ] && break
        if [ ${SECONDS} -ge ${deadline} ]; then
            echo "FAIL: only ${evaluated} rule evaluation queries reached the query-frontend"
            return 1
        fi
        sleep 2
    done

    if grep -q 'header_x_rule_' <<<"${stats}"; then
        echo "FAIL: query stats carry rule detail headers although the flag is disabled"
        return 1
    fi
    echo "${evaluated} rule evaluation queries reached the query-frontend, none with rule detail headers"
    echo "PASS: ${name}"
    echo
}

MQE_QUERIER='cortex_mimir_query_engine_estimated_query_peak_memory_consumption_count{engine="querier"}'
PROMETHEUS_QUERIER='prometheus_engine_query_duration_seconds_count{engine="querier",slice="inner_eval"}'

result=0
run_scenario "Mimir query engine" mimir true "${MQE_QUERIER}" "${PROMETHEUS_QUERIER}" || result=1
run_scenario "Prometheus engine" prometheus false "${PROMETHEUS_QUERIER}" "${MQE_QUERIER}" || result=1
run_disabled_scenario || result=1
docker_compose "${COMPOSE[@]}" down --timeout 5 >/dev/null 2>&1
exit ${result}
