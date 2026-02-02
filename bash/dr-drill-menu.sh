#!/usr/bin/env bash
set -u

PRIMARY_CTX="${PRIMARY_CTX:-primary-cluster-context}"
SECONDARY_CTX="${SECONDARY_CTX:-secondary-cluster}"
BOOKINFO_NS="${BOOKINFO_NS:-bookinfo}"
ISTIO_NS="${ISTIO_NS:-istio-system}"

LATENCY_VS_NAME="dr-latency-injection"

log() {
  printf "%b[%s]%b %s\n" "${C_CYAN}" "$(date +"%Y-%m-%d %H:%M:%S")" "${C_RESET}" "$*"
}

if [[ -t 1 ]]; then
  C_RESET="\033[0m"
  C_RED="\033[0;31m"
  C_GREEN="\033[0;32m"
  C_YELLOW="\033[0;33m"
  C_BLUE="\033[0;34m"
  C_CYAN="\033[0;36m"
  C_BOLD="\033[1m"
else
  C_RESET=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_CYAN=""
  C_BOLD=""
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

kctx() {
  local ctx="$1"; shift
  kubectl --context="$ctx" "$@"
}

ensure_contexts() {
  kctx "$PRIMARY_CTX" get ns >/dev/null 2>&1 || {
    echo "Primary context not reachable: $PRIMARY_CTX" >&2
    exit 1
  }
  kctx "$SECONDARY_CTX" get ns >/dev/null 2>&1 || {
    echo "Secondary context not reachable: $SECONDARY_CTX" >&2
    exit 1
  }
}

wait_for_ready() {
  local ctx="$1" selector="$2" namespace="$3" timeout="$4"
  kctx "$ctx" wait --for=condition=ready pod -l "$selector" -n "$namespace" --timeout="$timeout" >/dev/null 2>&1
}

restart_deployment() {
  local ctx="$1" name="$2" namespace="$3"
  if kctx "$ctx" get deploy "$name" -n "$namespace" >/dev/null 2>&1; then
    log "Restarting deployment $name in $namespace ($ctx)"
    kctx "$ctx" rollout restart deploy "$name" -n "$namespace" >/dev/null 2>&1
    kctx "$ctx" rollout status deploy "$name" -n "$namespace" --timeout=180s
  fi
}

status_check() {
  log "Checking istio-system pods"
  kctx "$PRIMARY_CTX" get pods -n "$ISTIO_NS" | grep -E "istiod|ingress|eastwest|prometheus|grafana|kiali|jaeger" || true
  kctx "$SECONDARY_CTX" get pods -n "$ISTIO_NS" | grep -E "istiod|ingress|eastwest|prometheus" || true

  log "Checking bookinfo pods"
  kctx "$PRIMARY_CTX" get pods -n "$BOOKINFO_NS" || true
  kctx "$SECONDARY_CTX" get pods -n "$BOOKINFO_NS" || true
}

scenario_ingress_failover() {
  log "Scenario 1: Ingress gateway failover (primary)"
  local pods
  pods=$(kctx "$PRIMARY_CTX" get pods -n "$ISTIO_NS" -l app=istio-ingressgateway -o name 2>/dev/null || true)
  if [[ -z "$pods" ]]; then
    log "No ingress gateway pods found in $ISTIO_NS on $PRIMARY_CTX"
    return 0
  fi
  kctx "$PRIMARY_CTX" delete pod -n "$ISTIO_NS" -l app=istio-ingressgateway --ignore-not-found
  log "Waiting for ingress gateway to become Ready..."
  wait_for_ready "$PRIMARY_CTX" "app=istio-ingressgateway" "$ISTIO_NS" "120s" || true
  log "Ingress gateway failover drill complete"
}

scenario_control_plane_failover() {
  log "Scenario 2: Control plane failover (primary istiod)"
  local replicas
  replicas=$(kctx "$PRIMARY_CTX" get deploy istiod -n "$ISTIO_NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
  if [[ -z "$replicas" ]]; then
    log "istiod deployment not found in $ISTIO_NS on $PRIMARY_CTX"
    return 0
  fi

  if [[ "$replicas" -eq 0 ]]; then
    log "istiod already scaled to 0; scaling back to 1"
    kctx "$PRIMARY_CTX" scale deploy istiod -n "$ISTIO_NS" --replicas=1
    wait_for_ready "$PRIMARY_CTX" "app=istiod" "$ISTIO_NS" "120s" || true
    return 0
  fi

  log "Scaling istiod to 0"
  kctx "$PRIMARY_CTX" scale deploy istiod -n "$ISTIO_NS" --replicas=0
  sleep 20
  log "Scaling istiod back to $replicas"
  kctx "$PRIMARY_CTX" scale deploy istiod -n "$ISTIO_NS" --replicas="$replicas"
  wait_for_ready "$PRIMARY_CTX" "app=istiod" "$ISTIO_NS" "120s" || true
  log "Control plane failover drill complete"
}

scenario_pod_failure() {
  log "Scenario 3: Data plane pod failure (reviews-v1)"
  local pod
  pod=$(kctx "$PRIMARY_CTX" get pods -n "$BOOKINFO_NS" -l app=reviews,version=v1 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$pod" ]]; then
    log "No reviews-v1 pod found in $BOOKINFO_NS on $PRIMARY_CTX"
    return 0
  fi
  log "Deleting pod $pod"
  kctx "$PRIMARY_CTX" delete pod -n "$BOOKINFO_NS" "$pod" --ignore-not-found
  wait_for_ready "$PRIMARY_CTX" "app=reviews,version=v1" "$BOOKINFO_NS" "120s" || true
  log "Data plane pod failure drill complete"
}

scenario_eastwest_failover() {
  log "Scenario 4: East-west gateway failover (primary)"
  local pods
  pods=$(kctx "$PRIMARY_CTX" get pods -n "$ISTIO_NS" -l istio=eastwestgateway -o name 2>/dev/null || true)
  if [[ -z "$pods" ]]; then
    log "No east-west gateway pods found in $ISTIO_NS on $PRIMARY_CTX"
    return 0
  fi
  kctx "$PRIMARY_CTX" delete pod -n "$ISTIO_NS" -l istio=eastwestgateway --ignore-not-found
  wait_for_ready "$PRIMARY_CTX" "istio=eastwestgateway" "$ISTIO_NS" "120s" || true
  log "East-west gateway failover drill complete"
}

apply_latency_injection() {
  log "Scenario 5: Apply latency injection via VirtualService"
  kctx "$PRIMARY_CTX" apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: ${LATENCY_VS_NAME}
  namespace: ${BOOKINFO_NS}
spec:
  hosts:
  - reviews
  http:
  - fault:
      delay:
        percentage:
          value: 100
        fixedDelay: 2s
    route:
    - destination:
        host: reviews
EOF
  log "Latency injection applied (2s fixed delay)"
}

remove_latency_injection() {
  log "Removing latency injection VirtualService (if present)"
  kctx "$PRIMARY_CTX" delete virtualservice "$LATENCY_VS_NAME" -n "$BOOKINFO_NS" --ignore-not-found
}

partial_recovery() {
  log "Partial recovery: restart bookinfo deployments"
  local deployments=(productpage-v1 reviews-v1 reviews-v2 reviews-v3 ratings-v1 details-v1)
  for d in "${deployments[@]}"; do
    restart_deployment "$PRIMARY_CTX" "$d" "$BOOKINFO_NS"
    restart_deployment "$SECONDARY_CTX" "$d" "$BOOKINFO_NS"
  done
  log "Partial recovery complete"
}

total_recovery() {
  log "Total recovery: restart Istio control plane and gateways + bookinfo"
  remove_latency_injection

  local istio_deploys=(istiod istio-ingressgateway istio-eastwestgateway)
  for d in "${istio_deploys[@]}"; do
    restart_deployment "$PRIMARY_CTX" "$d" "$ISTIO_NS"
    restart_deployment "$SECONDARY_CTX" "$d" "$ISTIO_NS"
  done

  partial_recovery
  log "Total recovery complete"
}

run_all() {
  scenario_ingress_failover
  scenario_control_plane_failover
  scenario_pod_failure
  scenario_eastwest_failover
  apply_latency_injection
  sleep 10
  remove_latency_injection
  log "All scenarios executed"
}

menu() {
  while true; do
    echo ""
    echo -e "${C_BOLD}${C_CYAN}==== DR Drill Menu ====${C_RESET}"
    echo -e "${C_YELLOW}1)${C_RESET} Status check"
    echo -e "${C_YELLOW}2)${C_RESET} Scenario 1: Ingress gateway failover"
    echo -e "${C_YELLOW}3)${C_RESET} Scenario 2: Control plane failover"
    echo -e "${C_YELLOW}4)${C_RESET} Scenario 3: Data plane pod failure"
    echo -e "${C_YELLOW}5)${C_RESET} Scenario 4: East-west gateway failover"
    echo -e "${C_YELLOW}6)${C_RESET} Scenario 5: Apply latency injection"
    echo -e "${C_YELLOW}7)${C_RESET} Remove latency injection"
    echo -e "${C_YELLOW}8)${C_RESET} Run all scenarios"
    echo -e "${C_YELLOW}9)${C_RESET} Partial recovery (bookinfo restart)"
    echo -e "${C_YELLOW}10)${C_RESET} Total recovery (Istio + bookinfo)"
    echo -e "${C_YELLOW}0)${C_RESET} Exit"
    echo ""
    read -r -p "Select an option: " choice

    case "$choice" in
      1) status_check ;;
      2) scenario_ingress_failover ;;
      3) scenario_control_plane_failover ;;
      4) scenario_pod_failure ;;
      5) scenario_eastwest_failover ;;
      6) apply_latency_injection ;;
      7) remove_latency_injection ;;
      8) run_all ;;
      9) partial_recovery ;;
      10) total_recovery ;;
      0) exit 0 ;;
      *) echo "Invalid option" ;;
    esac
  done
}

main() {
  require_cmd kubectl
  ensure_contexts
  menu
}

main
