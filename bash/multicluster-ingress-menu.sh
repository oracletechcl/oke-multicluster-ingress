#!/usr/bin/env bash
set -euo pipefail

PRIMARY_CTX="${PRIMARY_CTX:-primary-cluster-context}"
SECONDARY_CTX="${SECONDARY_CTX:-secondary-cluster}"
BOOKINFO_NS="${BOOKINFO_NS:-bookinfo}"
ISTIO_NS="${ISTIO_NS:-istio-system}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BOOKINFO_APP_FILE="${BOOKINFO_APP_FILE:-${ROOT_DIR}/istio-1.28.3/samples/bookinfo/platform/kube/bookinfo.yaml}"
GATEWAY_FILE="${GATEWAY_FILE:-${ROOT_DIR}/istio-1.28.3/samples/bookinfo/networking/bookinfo-gateway.yaml}"
INGRESS_SVC_MANIFEST="${INGRESS_SVC_MANIFEST:-}"
INGRESS_SVC_MANIFEST_PRIMARY="${INGRESS_SVC_MANIFEST_PRIMARY:-${ROOT_DIR}/yaml/istio-ingressgateway-oci-lb-primary.yaml}"
INGRESS_SVC_MANIFEST_SECONDARY="${INGRESS_SVC_MANIFEST_SECONDARY:-${ROOT_DIR}/yaml/istio-ingressgateway-oci-lb-secondary.yaml}"
ISTIO_VERSION="${ISTIO_VERSION:-1.28.3}"
ISTIO_DIR="${ROOT_DIR}/istio-${ISTIO_VERSION}"

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

get_ip() {
  local ctx="$1" svc="$2" ns="$3"
  local ip
  ip=$(kctx "$ctx" get svc "$svc" -n "$ns" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "$ip" ]]; then
    echo "$ip"
    return 0
  fi
  kctx "$ctx" get svc "$svc" -n "$ns" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true
}

wait_for_ips() {
  local ctx="$1" svc="$2" ns="$3" timeout=180 elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local ip
    ip=$(get_ip "$ctx" "$svc" "$ns")
    if [[ -n "$ip" ]]; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}

print_ips() {
  log "Current LoadBalancer IPs"
  local p_ingress s_ingress p_east s_east
  p_ingress=$(get_ip "$PRIMARY_CTX" istio-ingressgateway "$ISTIO_NS")
  s_ingress=$(get_ip "$SECONDARY_CTX" istio-ingressgateway "$ISTIO_NS")
  p_east=$(get_ip "$PRIMARY_CTX" istio-eastwestgateway "$ISTIO_NS")
  s_east=$(get_ip "$SECONDARY_CTX" istio-eastwestgateway "$ISTIO_NS")

  echo -e "${C_GREEN}Primary ingress IP:${C_RESET}   ${p_ingress:-<pending>}"
  echo -e "${C_GREEN}Secondary ingress IP:${C_RESET} ${s_ingress:-<pending>}"
  echo -e "${C_BLUE}Primary east-west IP:${C_RESET} ${p_east:-<pending>}"
  echo -e "${C_BLUE}Secondary east-west IP:${C_RESET} ${s_east:-<pending>}"

  echo ""
  echo -e "${C_BOLD}Browser test URLs:${C_RESET}"
  if [[ -n "${p_ingress:-}" ]]; then
    echo -e "  ${C_GREEN}Primary Bookinfo:${C_RESET}   http://${p_ingress}/productpage"
    echo -e "  ${C_GREEN}Primary HelloWorld:${C_RESET} http://${p_ingress}/hello"
  else
    echo "  Primary Bookinfo:   <pending>"
    echo "  Primary HelloWorld: <pending>"
  fi

  if [[ -n "${s_ingress:-}" ]]; then
    echo -e "  ${C_GREEN}Secondary Bookinfo:${C_RESET}   http://${s_ingress}/productpage"
    echo -e "  ${C_GREEN}Secondary HelloWorld:${C_RESET} http://${s_ingress}/hello"
  else
    echo "  Secondary Bookinfo:   <pending>"
    echo "  Secondary HelloWorld: <pending>"
  fi
}

scale_ingress_gateway() {
  local ctx="$1" replicas="$2"
  if kctx "$ctx" get deploy istio-ingressgateway -n "$ISTIO_NS" >/dev/null 2>&1; then
    local current
    current=$(kctx "$ctx" get deploy istio-ingressgateway -n "$ISTIO_NS" -o jsonpath='{.spec.replicas}')
    if [[ "$current" == "$replicas" ]]; then
      log "istio-ingressgateway already at replicas=$replicas in $ctx"
      return 0
    fi
    log "Scaling istio-ingressgateway to replicas=$replicas in $ctx"
    kctx "$ctx" scale deploy istio-ingressgateway -n "$ISTIO_NS" --replicas="$replicas"
    if [[ "$replicas" -gt 0 ]]; then
      kctx "$ctx" rollout status deploy istio-ingressgateway -n "$ISTIO_NS" --timeout=180s
    fi
  else
    log "istio-ingressgateway deployment not found in $ISTIO_NS on $ctx"
  fi
}

ensure_ingress_service() {
  local ctx="$1"
  if kctx "$ctx" get svc istio-ingressgateway -n "$ISTIO_NS" >/dev/null 2>&1; then
    log "istio-ingressgateway service already present in $ctx"
    return 0
  fi

  local manifest
  if [[ "$ctx" == "$PRIMARY_CTX" ]]; then
    manifest="$INGRESS_SVC_MANIFEST_PRIMARY"
  elif [[ "$ctx" == "$SECONDARY_CTX" ]]; then
    manifest="$INGRESS_SVC_MANIFEST_SECONDARY"
  else
    manifest="$INGRESS_SVC_MANIFEST"
  fi

  if [[ -n "$manifest" ]] && [[ -f "$manifest" ]]; then
    log "Recreating ingress LoadBalancer service in $ctx using $manifest"
    kctx "$ctx" apply -f "$manifest" -n "$ISTIO_NS"
    return 0
  fi

  # Create a LoadBalancer service for ingress gateway
  log "Creating ingress LoadBalancer service in $ctx"
  kctx "$ctx" apply -f - -n "$ISTIO_NS" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: istio-ingressgateway
  namespace: istio-system
spec:
  type: LoadBalancer
  selector:
    istio: ingressgateway
  ports:
  - name: http2
    port: 80
    targetPort: 8080
    protocol: TCP
  - name: https
    port: 443
    targetPort: 8443
    protocol: TCP
EOF
}

delete_ingress_service() {
  local ctx="$1"
  if kctx "$ctx" get svc istio-ingressgateway -n "$ISTIO_NS" >/dev/null 2>&1; then
    log "Deleting ingress LoadBalancer service in $ctx"
    kctx "$ctx" delete svc istio-ingressgateway -n "$ISTIO_NS" --ignore-not-found
  else
    log "Ingress LoadBalancer service already absent in $ctx"
  fi
}

apply_gateway() {
  local ctx="$1"
  log "Applying Bookinfo Gateway/VirtualService in $ctx"
  kctx "$ctx" apply -f "$GATEWAY_FILE" -n "$BOOKINFO_NS"
}

delete_gateway() {
  local ctx="$1"
  log "Deleting Bookinfo Gateway/VirtualService in $ctx (if present)"
  kctx "$ctx" delete -f "$GATEWAY_FILE" -n "$BOOKINFO_NS" --ignore-not-found
}

enable_primary() {
  ensure_ingress_service "$PRIMARY_CTX"
  scale_ingress_gateway "$PRIMARY_CTX" 1
  apply_gateway "$PRIMARY_CTX"
}

enable_secondary() {
  ensure_ingress_service "$SECONDARY_CTX"
  scale_ingress_gateway "$SECONDARY_CTX" 1
  apply_gateway "$SECONDARY_CTX"
}

enable_all() {
  enable_primary
  enable_secondary
}

disable_primary() {
  delete_gateway "$PRIMARY_CTX"
  scale_ingress_gateway "$PRIMARY_CTX" 0
}

disable_secondary() {
  delete_gateway "$SECONDARY_CTX"
  scale_ingress_gateway "$SECONDARY_CTX" 0
}

disable_all() {
  disable_primary
  disable_secondary
}

enable_primary_with_lb() {
  ensure_ingress_service "$PRIMARY_CTX"
  scale_ingress_gateway "$PRIMARY_CTX" 1
  apply_gateway "$PRIMARY_CTX"
}

enable_secondary_with_lb() {
  ensure_ingress_service "$SECONDARY_CTX"
  scale_ingress_gateway "$SECONDARY_CTX" 1
  apply_gateway "$SECONDARY_CTX"
}

enable_all_with_lb() {
  enable_primary_with_lb
  enable_secondary_with_lb
}

disable_primary_with_lb() {
  delete_gateway "$PRIMARY_CTX"
  scale_ingress_gateway "$PRIMARY_CTX" 0
  delete_ingress_service "$PRIMARY_CTX"
}

disable_secondary_with_lb() {
  delete_gateway "$SECONDARY_CTX"
  scale_ingress_gateway "$SECONDARY_CTX" 0
  delete_ingress_service "$SECONDARY_CTX"
}

disable_all_with_lb() {
  disable_primary_with_lb
  disable_secondary_with_lb
}

status_check() {
  log "Ingress gateway deployment status"
  kctx "$PRIMARY_CTX" get deploy -n "$ISTIO_NS" istio-ingressgateway || true
  kctx "$SECONDARY_CTX" get deploy -n "$ISTIO_NS" istio-ingressgateway || true

  log "Bookinfo Gateway/VirtualService status"
  kctx "$PRIMARY_CTX" get gateway,virtualservice -n "$BOOKINFO_NS" | grep -E "bookinfo-gateway|bookinfo" || true
  kctx "$SECONDARY_CTX" get gateway,virtualservice -n "$BOOKINFO_NS" | grep -E "bookinfo-gateway|bookinfo" || true

  print_ips
}

verify_istio() {
  local ctx="$1"
  if kctx "$ctx" get ns istio-system >/dev/null 2>&1; then
    if kctx "$ctx" get deploy istiod -n istio-system >/dev/null 2>&1; then
      log "Istio already installed in $ctx"
      return 0
    fi
  fi
  log "ERROR: Istio not found in $ctx. Please install Istio first."
  return 1
}

verify_app_namespace() {
  local ctx="$1"
  if kctx "$ctx" get ns "$BOOKINFO_NS" >/dev/null 2>&1; then
    log "Namespace $BOOKINFO_NS exists in $ctx"
    return 0
  fi
  log "Creating namespace $BOOKINFO_NS in $ctx"
  kctx "$ctx" create ns "$BOOKINFO_NS" 2>/dev/null || true
  kctx "$ctx" label ns "$BOOKINFO_NS" istio-injection=enabled 2>/dev/null || {
    log "WARNING: Could not label namespace. Sidecar injection may not work."
  }
  return 0
}

deploy_app() {
  local ctx="$1"
  if [[ ! -f "$BOOKINFO_APP_FILE" ]]; then
    log "ERROR: App file not found: $BOOKINFO_APP_FILE"
    return 1
  fi
  log "Deploying app to $ctx from $BOOKINFO_APP_FILE"
  kctx "$ctx" apply -f "$BOOKINFO_APP_FILE" -n "$BOOKINFO_NS"
  log "Waiting for app pods to be ready in $ctx (timeout: 180s)"
  kctx "$ctx" wait --for=condition=ready pod -l app=productpage -n "$BOOKINFO_NS" --timeout=180s 2>/dev/null || {
    log "WARNING: App pods not ready yet in $ctx. Continuing anyway."
  }
}

setup_cluster_ingress() {
  local ctx="$1"
  log "Setting up full ingress stack for $ctx"
  verify_istio "$ctx" || return 1
  verify_app_namespace "$ctx"
  deploy_app "$ctx"
  ensure_ingress_service "$ctx"
  scale_ingress_gateway "$ctx" 1
  apply_gateway "$ctx"
  log "✓ Setup complete for $ctx"
}

setup_all_from_scratch() {
  log "Starting: Setting up entire multi-cluster ingress infrastructure from scratch"
  setup_cluster_ingress "$PRIMARY_CTX" || {
    log "ERROR: Primary cluster setup failed"
    return 1
  }
  setup_cluster_ingress "$SECONDARY_CTX" || {
    log "ERROR: Secondary cluster setup failed"
    return 1
  }
  log "✓ Multi-cluster ingress fully configured!"
    log "Waiting for LoadBalancer IPs to be assigned (this may take 30-60 seconds)..."
    wait_for_ips "$PRIMARY_CTX" "istio-ingressgateway" "$ISTIO_NS" >/dev/null 2>&1 || true
    wait_for_ips "$SECONDARY_CTX" "istio-ingressgateway" "$ISTIO_NS" >/dev/null 2>&1 || true
  print_ips
}

teardown_cluster_ingress() {
  local ctx="$1"
  log "Tearing down ingress stack for $ctx"
  delete_gateway "$ctx"
  scale_ingress_gateway "$ctx" 0
  delete_ingress_service "$ctx"
  log "Deleting application namespace $BOOKINFO_NS in $ctx"
  kctx "$ctx" delete ns "$BOOKINFO_NS" --ignore-not-found 2>/dev/null || true
  log "✓ Teardown complete for $ctx"
}

teardown_all_from_scratch() {
  log "Starting: Removing entire multi-cluster ingress infrastructure from scratch"
  teardown_cluster_ingress "$PRIMARY_CTX" || {
    log "ERROR: Primary cluster teardown failed"
    return 1
  }
  teardown_cluster_ingress "$SECONDARY_CTX" || {
    log "ERROR: Secondary cluster teardown failed"
    return 1
  }
  log "✓ Multi-cluster ingress fully removed!"
}

menu() {
  while true; do
    echo ""
    echo -e "${C_BOLD}${C_CYAN}==== Multi-Cluster Ingress Menu ====${C_RESET}"
    echo -e "${C_YELLOW}1)${C_RESET} Status check + current IPs"
    echo -e "${C_YELLOW}2)${C_RESET} Setup entire stack from scratch"
    echo -e "${C_YELLOW}3)${C_RESET} Remove entire stack from scratch"
    echo -e "${C_YELLOW}4)${C_RESET} Setup cluster (primary)"
    echo -e "${C_YELLOW}5)${C_RESET} Setup cluster (secondary)"
    echo -e "${C_YELLOW}6)${C_RESET} Enable ingress (submenu)"
    echo -e "${C_YELLOW}7)${C_RESET} Disable ingress (submenu)"
    echo -e "${C_YELLOW}8)${C_RESET} Print current IPs"
    echo -e "${C_YELLOW}0)${C_RESET} Exit"
    echo ""
    read -r -p "Select an option: " choice

    case "$choice" in
      1) status_check ;;
      2) setup_all_from_scratch ;;
      3) teardown_all_from_scratch ;;
      4) setup_cluster_ingress "$PRIMARY_CTX" ;;
      5) setup_cluster_ingress "$SECONDARY_CTX" ;;
      6) enable_submenu ;;
      7) disable_submenu ;;
      8) print_ips ;;
      0) exit 0 ;;
      *) echo "Invalid option" ;;
    esac
  done
}

enable_submenu() {
  while true; do
    echo ""
    echo -e "${C_BOLD}${C_GREEN}-- Enable Ingress --${C_RESET}"
    echo -e "${C_YELLOW}1)${C_RESET} Enable ingress (primary)"
    echo -e "${C_YELLOW}2)${C_RESET} Enable ingress (secondary)"
    echo -e "${C_YELLOW}3)${C_RESET} Enable ingress (all)"
    echo -e "${C_YELLOW}4)${C_RESET} Enable ingress (primary) + recreate LB service"
    echo -e "${C_YELLOW}5)${C_RESET} Enable ingress (secondary) + recreate LB service"
    echo -e "${C_YELLOW}6)${C_RESET} Enable ingress (all) + recreate LB services"
    echo -e "${C_YELLOW}0)${C_RESET} Back"
    echo ""
    read -r -p "Select an option: " choice

    case "$choice" in
      1) enable_primary ;;
      2) enable_secondary ;;
      3) enable_all ;;
      4) enable_primary_with_lb ;;
      5) enable_secondary_with_lb ;;
      6) enable_all_with_lb ;;
      0) break ;;
      *) echo "Invalid option" ;;
    esac
  done
}

disable_submenu() {
  while true; do
    echo ""
    echo -e "${C_BOLD}${C_RED}-- Disable Ingress --${C_RESET}"
    echo -e "${C_YELLOW}1)${C_RESET} Disable ingress (primary)"
    echo -e "${C_YELLOW}2)${C_RESET} Disable ingress (secondary)"
    echo -e "${C_YELLOW}3)${C_RESET} Disable ingress (all)"
    echo -e "${C_YELLOW}4)${C_RESET} Disable ingress (primary) + delete LB service"
    echo -e "${C_YELLOW}5)${C_RESET} Disable ingress (secondary) + delete LB service"
    echo -e "${C_YELLOW}6)${C_RESET} Disable ingress (all) + delete LB services"
    echo -e "${C_YELLOW}0)${C_RESET} Back"
    echo ""
    read -r -p "Select an option: " choice

    case "$choice" in
      1) disable_primary ;;
      2) disable_secondary ;;
      3) disable_all ;;
      4) disable_primary_with_lb ;;
      5) disable_secondary_with_lb ;;
      6) disable_all_with_lb ;;
      0) break ;;
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
