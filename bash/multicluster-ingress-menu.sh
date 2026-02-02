#!/usr/bin/env bash
set -euo pipefail

PRIMARY_CTX="${PRIMARY_CTX:-primary-cluster-context}"
SECONDARY_CTX="${SECONDARY_CTX:-secondary-cluster}"
BOOKINFO_NS="${BOOKINFO_NS:-bookinfo}"
ISTIO_NS="${ISTIO_NS:-istio-system}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
GATEWAY_FILE="${GATEWAY_FILE:-${ROOT_DIR}/istio-1.28.3/samples/bookinfo/networking/bookinfo-gateway.yaml}"
INGRESS_SVC_MANIFEST="${INGRESS_SVC_MANIFEST:-}"

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
  kctx "$ctx" get svc "$svc" -n "$ns" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
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

  if [[ -z "$INGRESS_SVC_MANIFEST" ]]; then
    log "Ingress service missing in $ctx. Set INGRESS_SVC_MANIFEST to recreate the LoadBalancer service."
    return 0
  fi

  log "Recreating ingress LoadBalancer service in $ctx using $INGRESS_SVC_MANIFEST"
  kctx "$ctx" apply -f "$INGRESS_SVC_MANIFEST" -n "$ISTIO_NS"
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

menu() {
  while true; do
    echo ""
    echo -e "${C_BOLD}${C_CYAN}==== Multi-Cluster Ingress Menu ====${C_RESET}"
    echo -e "${C_YELLOW}1)${C_RESET} Status check + current IPs"
    echo -e "${C_YELLOW}2)${C_RESET} Enable ingress (submenu)"
    echo -e "${C_YELLOW}3)${C_RESET} Disable ingress (submenu)"
    echo -e "${C_YELLOW}4)${C_RESET} Print current IPs"
    echo -e "${C_YELLOW}0)${C_RESET} Exit"
    echo ""
    read -r -p "Select an option: " choice

    case "$choice" in
      1) status_check ;;
      2) enable_submenu ;;
      3) disable_submenu ;;
      4) print_ips ;;
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
