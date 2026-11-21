#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-zero-trust-lab}"
FRONTEND_TEST_POD="${FRONTEND_TEST_POD:-frontend-check}"
API_TEST_POD="${API_TEST_POD:-api-check}"
TEST_IMAGE="${TEST_IMAGE:-busybox:1.36}"

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

command -v kubectl >/dev/null 2>&1 || fail "kubectl is required but was not found in PATH."
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || fail "Namespace '$NAMESPACE' does not exist. Apply the lab manifests first."

ensure_test_pod() {
  local pod_name="$1"
  local app_label="$2"

  if ! kubectl get pod "$pod_name" -n "$NAMESPACE" >/dev/null 2>&1; then
    log "Creating test Pod '$pod_name' with app=$app_label"
    kubectl run "$pod_name" \
      --namespace "$NAMESPACE" \
      --image "$TEST_IMAGE" \
      --labels "app=$app_label" \
      --restart Never \
      --command -- sh -c 'sleep 36000'
  fi

  kubectl wait \
    --namespace "$NAMESPACE" \
    --for=condition=Ready \
    "pod/$pod_name" \
    --timeout=180s >/dev/null || fail "Test Pod '$pod_name' did not become Ready."
}

log "Checking test Pods"
ensure_test_pod "$FRONTEND_TEST_POD" "frontend"
ensure_test_pod "$API_TEST_POD" "api"

log "1/4: Frontend can resolve the API Service through DNS"
if kubectl exec -n "$NAMESPACE" "$FRONTEND_TEST_POD" -- nslookup api >/dev/null; then
  pass "Frontend DNS lookup for 'api' succeeded"
else
  fail "Frontend could not resolve 'api'. Check CoreDNS health, labels, and the allow-dns policy."
fi

log "2/4: Frontend can reach the API on TCP/80"
if kubectl exec -n "$NAMESPACE" "$FRONTEND_TEST_POD" -- \
  wget -qO- -T 5 http://api >/dev/null; then
  pass "Frontend -> API TCP/80 is allowed"
else
  fail "Frontend -> API failed. Check both frontend egress and API ingress policies, labels, and Service endpoints."
fi

log "3/4: API can reach the database on TCP/6379"
if kubectl exec -n "$NAMESPACE" "$API_TEST_POD" -- \
  nc -z -w 5 database 6379; then
  pass "API -> Database TCP/6379 is allowed"
else
  fail "API -> Database failed. Check API egress and database ingress policies, labels, DNS, and Service endpoints."
fi

log "4/4: Frontend cannot reach the database on TCP/6379"
set +e
blocked_output=$(kubectl exec -n "$NAMESPACE" "$FRONTEND_TEST_POD" -- \
  sh -c 'if nc -z -w 3 database 6379; then echo POLICY_VIOLATION; exit 42; else echo CONNECTION_BLOCKED; exit 0; fi' 2>&1)
blocked_status=$?
set -e

if [[ "$blocked_status" -eq 0 && "$blocked_output" == *"CONNECTION_BLOCKED"* ]]; then
  pass "Frontend -> Database TCP/6379 is blocked"
else
  printf '%s\n' "$blocked_output" >&2
  fail "Could not confirm that frontend-to-database traffic is blocked. A successful connection or kubectl execution error is a failure."
fi

log "All connectivity checks passed."
