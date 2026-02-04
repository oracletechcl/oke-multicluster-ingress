#!/usr/bin/env bash
set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
MAGENTA="\033[0;35m"
BOLD="\033[1m"
NC="\033[0m"

# Load environment variables from .env file
ENV_FILE="$PROJECT_ROOT/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo -e "${RED}✗ ERROR: Environment file not found: $ENV_FILE${NC}"
  echo ""
  echo -e "${YELLOW}Creating .env file with auto-detected configuration...${NC}"
  
  # Auto-detect subnet OCIDs from existing manifests
  PRIMARY_SUBNET=""
  SECONDARY_SUBNET=""
  
  if [ -f "$PROJECT_ROOT/yaml/istio-ingressgateway-oci-lb-primary.yaml" ]; then
    PRIMARY_SUBNET=$(grep "oci-load-balancer-subnet1:" "$PROJECT_ROOT/yaml/istio-ingressgateway-oci-lb-primary.yaml" | awk '{print $2}' | tr -d '"' || echo "")
    echo -e "${CYAN}  Detected PRIMARY subnet from manifest: ${PRIMARY_SUBNET:-not found}${NC}"
  fi
  
  if [ -f "$PROJECT_ROOT/yaml/istio-ingressgateway-oci-lb-secondary.yaml" ]; then
    SECONDARY_SUBNET=$(grep "oci-load-balancer-subnet1:" "$PROJECT_ROOT/yaml/istio-ingressgateway-oci-lb-secondary.yaml" | awk '{print $2}' | tr -d '"' || echo "")
    echo -e "${CYAN}  Detected SECONDARY subnet from manifest: ${SECONDARY_SUBNET:-not found}${NC}"
  fi
  
  # If not found in manifests, try OCI CLI
  if [ -z "$PRIMARY_SUBNET" ] && command -v oci >/dev/null 2>&1; then
    echo -e "${CYAN}  Attempting to detect subnets via OCI CLI...${NC}"
    PRIMARY_SUBNET=$(oci network subnet list --all --query 'data[?contains("display-name", `Public`) || contains("display-name", `public`)].id | [0]' --raw-output 2>/dev/null || echo "")
    if [ -n "$PRIMARY_SUBNET" ]; then
      echo -e "${CYAN}  Detected PUBLIC subnet via OCI CLI: ${PRIMARY_SUBNET}${NC}"
    fi
  fi
  
  # Use detected values or placeholders
  PRIMARY_SUBNET="${PRIMARY_SUBNET:-ocid1.subnet.oc1..your-primary-subnet-id}"
  SECONDARY_SUBNET="${SECONDARY_SUBNET:-ocid1.subnet.oc1..your-secondary-subnet-id}"
  
  cat > "$ENV_FILE" <<EOF
# OKE Multi-Cluster Ingress Demo - Environment Configuration
# Edit these values to match your Kubernetes clusters

# Kubernetes Contexts
export PRIMARY_CTX="primary-cluster-context"
export SECONDARY_CTX="secondary-cluster"

# Namespaces
export BOOKINFO_NS="bookinfo"
export ISTIO_NS="istio-system"

# Istio Configuration
export ISTIO_VERSION="1.28.3"

# OCI LoadBalancer Configuration (required for OKE)
# Auto-detected from existing manifests or OCI CLI
export OCI_LB_SUBNET_PRIMARY="$PRIMARY_SUBNET"
export OCI_LB_SUBNET_SECONDARY="$SECONDARY_SUBNET"

# Optional: Custom manifest paths (leave empty for defaults)
export INGRESS_SVC_MANIFEST_PRIMARY=""
export INGRESS_SVC_MANIFEST_SECONDARY=""
EOF
  echo -e "${GREEN}✓${NC} Template created at: ${BOLD}$ENV_FILE${NC}"
  echo ""
  echo -e "${YELLOW}Please review and edit the .env file, then run again.${NC}"
  echo -e "${CYAN}Required values to verify:${NC}"
  echo -e "  • PRIMARY_CTX (Kubernetes context for primary cluster)"
  echo -e "  • SECONDARY_CTX (Kubernetes context for secondary cluster)"
  echo -e "  • OCI_LB_SUBNET_PRIMARY (subnet OCID for primary cluster LB)"
  echo -e "  • OCI_LB_SUBNET_SECONDARY (subnet OCID for secondary cluster LB)"
  exit 1
fi

# Source environment file
echo -e "${CYAN}Loading configuration from: $ENV_FILE${NC}"
source "$ENV_FILE"

# Validate required variables
REQUIRED_VARS=("PRIMARY_CTX" "SECONDARY_CTX")
MISSING_VARS=()

for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var:-}" ]; then
    MISSING_VARS+=("$var")
  fi
done

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
  echo -e "${RED}✗ ERROR: Missing required environment variables in $ENV_FILE${NC}"
  echo -e "${YELLOW}Missing variables:${NC}"
  for var in "${MISSING_VARS[@]}"; do
    echo -e "  • $var"
  done
  echo ""
  echo -e "${YELLOW}Please edit $ENV_FILE and set the missing values.${NC}"
  exit 1
fi

echo -e "${GREEN}✓${NC} Configuration loaded successfully"
echo -e "${CYAN}  PRIMARY_CTX:${NC} $PRIMARY_CTX"
echo -e "${CYAN}  SECONDARY_CTX:${NC} $SECONDARY_CTX"
echo -e "${CYAN}  BOOKINFO_NS:${NC} ${BOOKINFO_NS:-bookinfo}"
echo -e "${CYAN}  ISTIO_NS:${NC} ${ISTIO_NS:-istio-system}"
echo ""

# Default values
BOOKINFO_NS="${BOOKINFO_NS:-bookinfo}"
ISTIO_NS="${ISTIO_NS:-istio-system}"
ISTIO_VERSION="${ISTIO_VERSION:-1.28.3}"
ISTIO_DIR="${PROJECT_ROOT}/istio-${ISTIO_VERSION}"
BOOKINFO_APP_FILE="${PROJECT_ROOT}/istio-${ISTIO_VERSION}/samples/bookinfo/platform/kube/bookinfo.yaml"
GATEWAY_FILE="${PROJECT_ROOT}/istio-${ISTIO_VERSION}/samples/bookinfo/networking/bookinfo-gateway.yaml"
INGRESS_SVC_MANIFEST_PRIMARY="${INGRESS_SVC_MANIFEST_PRIMARY:-${PROJECT_ROOT}/yaml/istio-ingressgateway-oci-lb-primary.yaml}"
INGRESS_SVC_MANIFEST_SECONDARY="${INGRESS_SVC_MANIFEST_SECONDARY:-${PROJECT_ROOT}/yaml/istio-ingressgateway-oci-lb-secondary.yaml}"

# Helper functions
run_cmd() {
  echo -e "${CYAN}▶ Running:${NC} ${BOLD}$*${NC}"
  "$@"
}

show_step() {
  echo ""
  echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${MAGENTA}  $1${NC}"
  echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════${NC}"
  echo ""
}

log() {
  echo -e "${CYAN}[$(date +"%Y-%m-%d %H:%M:%S")]${NC} $*"
}

kctx() {
  local ctx="$1"; shift
  echo -e "${CYAN}▶ kubectl --context=$ctx $*${NC}" >&2
  kubectl --context="$ctx" "$@"
}

ensure_contexts() {
  echo -e "${CYAN}Verifying Kubernetes contexts...${NC}"
  
  if ! kctx "$PRIMARY_CTX" get ns >/dev/null 2>&1; then
    echo -e "${RED}✗ ERROR: Primary context not reachable: $PRIMARY_CTX${NC}"
    echo -e "${YELLOW}Available contexts:${NC}"
    run_cmd kubectl config get-contexts
    exit 1
  fi
  echo -e "${GREEN}✓${NC} Primary cluster accessible: $PRIMARY_CTX"
  
  if ! kctx "$SECONDARY_CTX" get ns >/dev/null 2>&1; then
    echo -e "${RED}✗ ERROR: Secondary context not reachable: $SECONDARY_CTX${NC}"
    echo -e "${YELLOW}Available contexts:${NC}"
    run_cmd kubectl config get-contexts
    exit 1
  fi
  echo -e "${GREEN}✓${NC} Secondary cluster accessible: $SECONDARY_CTX"
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
  echo -e "${CYAN}Waiting for LoadBalancer IP for $svc in $ctx (max ${timeout}s)...${NC}"
  while [[ $elapsed -lt $timeout ]]; do
    local ip
    ip=$(get_ip "$ctx" "$svc" "$ns")
    if [[ -n "$ip" ]]; then
      echo -e "${GREEN}✓${NC} LoadBalancer IP assigned: $ip"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    echo -e "${YELLOW}⏳${NC} Still waiting... ($elapsed/${timeout}s)"
  done
  echo -e "${YELLOW}⚠  Timeout waiting for LoadBalancer IP${NC}"
  return 1
}

print_ips() {
  show_step "CURRENT LOADBALANCER IPS & ACCESS URLS"
  
  local p_ingress s_ingress p_east s_east
  p_ingress=$(get_ip "$PRIMARY_CTX" istio-ingressgateway "$ISTIO_NS")
  s_ingress=$(get_ip "$SECONDARY_CTX" istio-ingressgateway "$ISTIO_NS")
  p_east=$(get_ip "$PRIMARY_CTX" istio-eastwestgateway "$ISTIO_NS")
  s_east=$(get_ip "$SECONDARY_CTX" istio-eastwestgateway "$ISTIO_NS")

  echo -e "${BOLD}LoadBalancer IPs:${NC}"
  echo -e "  ${GREEN}Primary ingress IP:${NC}   ${p_ingress:-<pending>}"
  echo -e "  ${GREEN}Secondary ingress IP:${NC} ${s_ingress:-<pending>}"
  echo -e "  ${BLUE}Primary east-west IP:${NC} ${p_east:-<pending>}"
  echo -e "  ${BLUE}Secondary east-west IP:${NC} ${s_east:-<pending>}"

  echo ""
  echo -e "${BOLD}${MAGENTA}Browser Test URLs:${NC}"
  if [[ -n "${p_ingress:-}" ]]; then
    echo -e "  ${GREEN}Primary Bookinfo:${NC}   http://${p_ingress}/productpage"
    echo -e "  ${GREEN}Primary HelloWorld:${NC} http://${p_ingress}/hello"
  else
    echo -e "  ${YELLOW}Primary Bookinfo:   <pending>${NC}"
    echo -e "  ${YELLOW}Primary HelloWorld: <pending>${NC}"
  fi

  if [[ -n "${s_ingress:-}" ]]; then
    echo -e "  ${GREEN}Secondary Bookinfo:${NC}   http://${s_ingress}/productpage"
    echo -e "  ${GREEN}Secondary HelloWorld:${NC} http://${s_ingress}/hello"
  else
    echo -e "  ${YELLOW}Secondary Bookinfo:   <pending>${NC}"
    echo -e "  ${YELLOW}Secondary HelloWorld: <pending>${NC}"
  fi
}

verify_istio() {
  local ctx="$1"
  echo -e "${CYAN}Verifying Istio installation in $ctx...${NC}"
  
  if kctx "$ctx" get ns istio-system >/dev/null 2>&1; then
    if kctx "$ctx" get deploy istiod -n istio-system >/dev/null 2>&1; then
      local ready_replicas
      ready_replicas=$(kctx "$ctx" get deploy istiod -n istio-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
      if [ "$ready_replicas" -gt 0 ]; then
        echo -e "${GREEN}✓${NC} Istio installed and running in $ctx"
        return 0
      fi
    fi
  fi
  
  echo -e "${RED}✗ ERROR: Istio not found or not ready in $ctx${NC}"
  echo -e "${YELLOW}Please install Istio first:${NC}"
  echo -e "  1. Download Istio: curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -"
  echo -e "  2. Install Istio: istioctl install --context=$ctx --set profile=demo -y"
  echo -e "  3. Verify: kubectl --context=$ctx get pods -n istio-system"
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
  kctx "$ctx" label ns "$BOOKINFO_NS" istio-injection=enabled --overwrite 2>/dev/null || {
    log "WARNING: Could not label namespace. Sidecar injection may not work."
  }
  echo -e "${GREEN}✓${NC} Namespace $BOOKINFO_NS created and labeled for Istio injection"
  return 0
}

deploy_bookinfo() {
  local ctx="$1"
  
  # Determine cluster name for visual identification
  local cluster_display_name
  if [[ "$ctx" == "$PRIMARY_CTX" ]]; then
    cluster_display_name="PRIMARY (San Jose)"
  elif [[ "$ctx" == "$SECONDARY_CTX" ]]; then
    cluster_display_name="SECONDARY (Chicago)"
  else
    cluster_display_name="$ctx"
  fi
  
  # Use cluster-aware deployment if exists, otherwise fallback to standard
  local deployment_file="${PROJECT_ROOT}/yaml/bookinfo-with-cluster-info.yaml"
  
  if [[ -f "$deployment_file" ]]; then
    log "Deploying Bookinfo application with cluster info to $ctx"
    # Replace placeholder with actual cluster name
    sed "s/REPLACE_CLUSTER_NAME/${cluster_display_name}/g" "$deployment_file" | \
      kctx "$ctx" apply -f - -n "$BOOKINFO_NS"
  elif [[ -f "$BOOKINFO_APP_FILE" ]]; then
    log "Deploying standard Bookinfo application to $ctx"
    kctx "$ctx" apply -f "$BOOKINFO_APP_FILE" -n "$BOOKINFO_NS"
  else
    echo -e "${RED}✗ ERROR: No Bookinfo deployment file found${NC}"
    echo -e "${YELLOW}Checked: $deployment_file${NC}"
    echo -e "${YELLOW}And: $BOOKINFO_APP_FILE${NC}"
    return 1
  fi
  
  log "Waiting for Bookinfo pods to be ready in $ctx (timeout: 180s)"
  if kctx "$ctx" wait --for=condition=ready pod -l app=productpage -n "$BOOKINFO_NS" --timeout=180s 2>/dev/null; then
    echo -e "${GREEN}✓${NC} Bookinfo application ready in $ctx"
  else
    echo -e "${YELLOW}⚠  Bookinfo pods not ready yet in $ctx. Continuing anyway.${NC}"
  fi
}

apply_gateway() {
  local ctx="$1"
  
  if [[ ! -f "$GATEWAY_FILE" ]]; then
    echo -e "${RED}✗ ERROR: Gateway file not found: $GATEWAY_FILE${NC}"
    return 1
  fi
  
  log "Applying Bookinfo Gateway/VirtualService in $ctx"
  kctx "$ctx" apply -f "$GATEWAY_FILE" -n "$BOOKINFO_NS"
  echo -e "${GREEN}✓${NC} Gateway and VirtualService applied in $ctx"
}

delete_gateway() {
  local ctx="$1"
  log "Deleting Bookinfo Gateway/VirtualService in $ctx (if present)"
  kctx "$ctx" delete -f "$GATEWAY_FILE" -n "$BOOKINFO_NS" --ignore-not-found 2>/dev/null || true
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
  fi

  if [[ -n "$manifest" ]] && [[ -f "$manifest" ]]; then
    log "Creating ingress LoadBalancer service in $ctx using $manifest"
    kctx "$ctx" apply -f "$manifest"
    echo -e "${GREEN}✓${NC} LoadBalancer service created in $ctx"
    return 0
  fi

  # Create a LoadBalancer service for ingress gateway
  log "Creating ingress LoadBalancer service in $ctx (auto-configured)"
  
  # Get subnet OCID based on cluster context
  local subnet_ocid
  if [[ "$ctx" == "$PRIMARY_CTX" ]]; then
    subnet_ocid="${OCI_LB_SUBNET_PRIMARY:-}"
  elif [[ "$ctx" == "$SECONDARY_CTX" ]]; then
    subnet_ocid="${OCI_LB_SUBNET_SECONDARY:-}"
  fi
  
  # Validate subnet OCID
  if [[ -z "$subnet_ocid" ]] || [[ "$subnet_ocid" == *"your-"*"-subnet-id"* ]]; then
    echo -e "${RED}✗ ERROR: Valid subnet OCID not configured for $ctx${NC}"
    echo -e "${YELLOW}   Update .env file with OCI_LB_SUBNET_PRIMARY or OCI_LB_SUBNET_SECONDARY${NC}"
    echo -e "${YELLOW}   Or set INGRESS_SVC_MANIFEST_PRIMARY/SECONDARY to use custom manifest${NC}"
    return 1
  fi
  
  echo -e "${CYAN}  Using subnet: $subnet_ocid${NC}"
  
  kctx "$ctx" apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: istio-ingressgateway
  namespace: $ISTIO_NS
  annotations:
    service.beta.kubernetes.io/oci-load-balancer-internal: "false"
    service.beta.kubernetes.io/oci-load-balancer-shape: "flexible"
    service.beta.kubernetes.io/oci-load-balancer-shape-flex-min: "10"
    service.beta.kubernetes.io/oci-load-balancer-shape-flex-max: "100"
    service.beta.kubernetes.io/oci-load-balancer-subnet1: "$subnet_ocid"
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
  echo -e "${GREEN}✓${NC} LoadBalancer service created in $ctx"
}

delete_ingress_service() {
  local ctx="$1"
  if kctx "$ctx" get svc istio-ingressgateway -n "$ISTIO_NS" >/dev/null 2>&1; then
    log "Deleting ingress LoadBalancer service in $ctx"
    kctx "$ctx" delete svc istio-ingressgateway -n "$ISTIO_NS" --ignore-not-found
    echo -e "${GREEN}✓${NC} LoadBalancer service deleted in $ctx"
  else
    log "Ingress LoadBalancer service already absent in $ctx"
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
      echo -e "${GREEN}✓${NC} Ingress gateway scaled to $replicas in $ctx"
    fi
  else
    echo -e "${YELLOW}⚠  istio-ingressgateway deployment not found in $ISTIO_NS on $ctx${NC}"
  fi
}

# Step 1: Install/Verify Prerequisites
install_prerequisites() {
  show_step "STEP 1: INSTALL/VERIFY PREREQUISITES"
  
  echo -e "${CYAN}Checking required commands...${NC}"
  local missing_cmds=()
  
  for cmd in kubectl curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_cmds+=("$cmd")
    else
      echo -e "${GREEN}✓${NC} $cmd is installed"
    fi
  done
  
  if [ ${#missing_cmds[@]} -gt 0 ]; then
    echo -e "${RED}✗ ERROR: Missing required commands:${NC}"
    for cmd in "${missing_cmds[@]}"; do
      echo -e "  • $cmd"
    done
    echo -e "${YELLOW}Please install these commands and try again${NC}"
    return 1
  fi
  
  echo ""
  ensure_contexts
  
  echo ""
  echo -e "${CYAN}Checking Istio sample files...${NC}"
  if [[ ! -d "$ISTIO_DIR" ]]; then
    echo -e "${YELLOW}⚠  Istio ${ISTIO_VERSION} not found locally${NC}"
    echo ""
    read -r -p "Download Istio ${ISTIO_VERSION}? (yes/no): " download_istio
    
    if [ "$download_istio" = "yes" ]; then
      echo -e "${CYAN}Downloading Istio ${ISTIO_VERSION}...${NC}"
      cd "$PROJECT_ROOT"
      run_cmd curl -L https://istio.io/downloadIstio -o /tmp/downloadIstio.sh
      run_cmd bash -c "ISTIO_VERSION=${ISTIO_VERSION} bash /tmp/downloadIstio.sh"
      rm -f /tmp/downloadIstio.sh
      
      if [[ -d "$ISTIO_DIR" ]]; then
        echo -e "${GREEN}✓${NC} Istio ${ISTIO_VERSION} downloaded successfully"
      else
        echo -e "${RED}✗ ERROR: Failed to download Istio${NC}"
        return 1
      fi
    else
      echo -e "${YELLOW}Skipping Istio download${NC}"
      echo -e "${YELLOW}Manual download:${NC}"
      echo -e "  cd $PROJECT_ROOT"
      echo -e "  curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -"
      return 1
    fi
  else
    echo -e "${GREEN}✓${NC} Istio ${ISTIO_VERSION} found at: $ISTIO_DIR"
  fi
  
  if [[ ! -f "$BOOKINFO_APP_FILE" ]]; then
    echo -e "${RED}✗ ERROR: Bookinfo app file not found: $BOOKINFO_APP_FILE${NC}"
    return 1
  fi
  echo -e "${GREEN}✓${NC} Bookinfo sample files found"
  
  if [[ ! -f "$GATEWAY_FILE" ]]; then
    echo -e "${RED}✗ ERROR: Gateway file not found: $GATEWAY_FILE${NC}"
    return 1
  fi
  echo -e "${GREEN}✓${NC} Gateway configuration files found"
  
  echo ""
  echo -e "${CYAN}Checking Istio installation on clusters...${NC}"
  
  # First, check and generate certificates if needed
  echo ""
  echo -e "${CYAN}Checking/Generating CA certificates for multi-cluster mTLS...${NC}"
  
  CERTS_DIR="$PROJECT_ROOT/certs"
  
  if [[ ! -d "$CERTS_DIR/primary-cluster" ]] || [[ ! -d "$CERTS_DIR/secondary-cluster" ]]; then
    echo -e "${YELLOW}⚠  CA certificates not found - generating new certificates${NC}"
    
    cd "${ISTIO_DIR}"
    
    # Generate root CA
    echo -e "${CYAN}Generating root CA certificate...${NC}"
    run_cmd make -f tools/certs/Makefile.selfsigned.mk root-ca
    
    # Generate cluster-specific intermediate CAs
    echo -e "${CYAN}Generating primary cluster CA certificates...${NC}"
    run_cmd make -f tools/certs/Makefile.selfsigned.mk primary-cluster-cacerts
    
    echo -e "${CYAN}Generating secondary cluster CA certificates...${NC}"
    run_cmd make -f tools/certs/Makefile.selfsigned.mk secondary-cluster-cacerts
    
    # Copy certificates to project certs directory
    echo -e "${CYAN}Copying certificates to ${CERTS_DIR}...${NC}"
    mkdir -p "$CERTS_DIR"
    cp -r primary-cluster "$CERTS_DIR/"
    cp -r secondary-cluster "$CERTS_DIR/"
    cp root-*.pem "$CERTS_DIR/" 2>/dev/null || true
    
    cd "$PROJECT_ROOT"
    echo -e "${GREEN}✓${NC} CA certificates generated successfully"
  else
    echo -e "${GREEN}✓${NC} CA certificates found in ${CERTS_DIR}"
  fi
  
  # Deploy cacerts secret to primary cluster if Istio namespace exists
  if kctx "$PRIMARY_CTX" get ns istio-system >/dev/null 2>&1; then
    if ! kctx "$PRIMARY_CTX" get secret cacerts -n istio-system >/dev/null 2>&1; then
      echo -e "${CYAN}Deploying CA certificates secret to PRIMARY cluster...${NC}"
      run_cmd kubectl --context="$PRIMARY_CTX" create secret generic cacerts -n istio-system \
        --from-file=ca-cert.pem="${CERTS_DIR}/primary-cluster/ca-cert.pem" \
        --from-file=ca-key.pem="${CERTS_DIR}/primary-cluster/ca-key.pem" \
        --from-file=root-cert.pem="${CERTS_DIR}/primary-cluster/root-cert.pem" \
        --from-file=cert-chain.pem="${CERTS_DIR}/primary-cluster/cert-chain.pem"
    else
      echo -e "${GREEN}✓${NC} CA certificates secret already exists in PRIMARY cluster"
    fi
  else
    echo -e "${CYAN}Creating istio-system namespace in PRIMARY cluster...${NC}"
    run_cmd kubectl --context="$PRIMARY_CTX" create namespace istio-system
    
    echo -e "${CYAN}Deploying CA certificates secret to PRIMARY cluster...${NC}"
    run_cmd kubectl --context="$PRIMARY_CTX" create secret generic cacerts -n istio-system \
      --from-file=ca-cert.pem="${CERTS_DIR}/primary-cluster/ca-cert.pem" \
      --from-file=ca-key.pem="${CERTS_DIR}/primary-cluster/ca-key.pem" \
      --from-file=root-cert.pem="${CERTS_DIR}/primary-cluster/root-cert.pem" \
      --from-file=cert-chain.pem="${CERTS_DIR}/primary-cluster/cert-chain.pem"
  fi
  
  # Deploy cacerts secret to secondary cluster if Istio namespace exists
  if kctx "$SECONDARY_CTX" get ns istio-system >/dev/null 2>&1; then
    if ! kctx "$SECONDARY_CTX" get secret cacerts -n istio-system >/dev/null 2>&1; then
      echo -e "${CYAN}Deploying CA certificates secret to SECONDARY cluster...${NC}"
      run_cmd kubectl --context="$SECONDARY_CTX" create secret generic cacerts -n istio-system \
        --from-file=ca-cert.pem="${CERTS_DIR}/secondary-cluster/ca-cert.pem" \
        --from-file=ca-key.pem="${CERTS_DIR}/secondary-cluster/ca-key.pem" \
        --from-file=root-cert.pem="${CERTS_DIR}/secondary-cluster/root-cert.pem" \
        --from-file=cert-chain.pem="${CERTS_DIR}/secondary-cluster/cert-chain.pem"
    else
      echo -e "${GREEN}✓${NC} CA certificates secret already exists in SECONDARY cluster"
    fi
  else
    echo -e "${CYAN}Creating istio-system namespace in SECONDARY cluster...${NC}"
    run_cmd kubectl --context="$SECONDARY_CTX" create namespace istio-system
    
    echo -e "${CYAN}Deploying CA certificates secret to SECONDARY cluster...${NC}"
    run_cmd kubectl --context="$SECONDARY_CTX" create secret generic cacerts -n istio-system \
      --from-file=ca-cert.pem="${CERTS_DIR}/secondary-cluster/ca-cert.pem" \
      --from-file=ca-key.pem="${CERTS_DIR}/secondary-cluster/ca-key.pem" \
      --from-file=root-cert.pem="${CERTS_DIR}/secondary-cluster/root-cert.pem" \
      --from-file=cert-chain.pem="${CERTS_DIR}/secondary-cluster/cert-chain.pem"
  fi
  
  echo ""
  local primary_istio_ok=false
  local secondary_istio_ok=false
  
  if kctx "$PRIMARY_CTX" get ns istio-system >/dev/null 2>&1; then
    if kctx "$PRIMARY_CTX" get deploy istiod -n istio-system >/dev/null 2>&1; then
      local ready_replicas
      ready_replicas=$(kctx "$PRIMARY_CTX" get deploy istiod -n istio-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
      if [ "$ready_replicas" -gt 0 ]; then
        echo -e "${GREEN}✓${NC} Istio installed and running on PRIMARY cluster"
        primary_istio_ok=true
      fi
    fi
  fi
  
  if ! $primary_istio_ok; then
    echo -e "${YELLOW}⚠  Istio not installed on PRIMARY cluster${NC}"
    echo ""
    read -r -p "Install Istio on PRIMARY cluster? (yes/no): " install_primary
    
    if [ "$install_primary" = "yes" ]; then
      echo -e "${CYAN}Installing Istio on PRIMARY cluster...${NC}"
      run_cmd "${ISTIO_DIR}/bin/istioctl" install --context="$PRIMARY_CTX" --set profile=demo -y
      
      echo ""
      echo -e "${CYAN}Annotating ingress gateway with OCI subnet on PRIMARY...${NC}"
      local primary_subnet="${OCI_LB_SUBNET_PRIMARY:-}"
      if [[ -n "$primary_subnet" ]] && [[ "$primary_subnet" != *"your-"*"-subnet-id"* ]]; then
        run_cmd kubectl --context="$PRIMARY_CTX" annotate svc istio-ingressgateway -n istio-system \
          service.beta.kubernetes.io/oci-load-balancer-subnet1="$primary_subnet" \
          service.beta.kubernetes.io/oci-load-balancer-shape="flexible" \
          service.beta.kubernetes.io/oci-load-balancer-shape-flex-min="10" \
          service.beta.kubernetes.io/oci-load-balancer-shape-flex-max="100" \
          --overwrite
        echo -e "${GREEN}✓${NC} Ingress gateway annotated with subnet"
      else
        echo -e "${RED}✗ ERROR: Valid subnet OCID not configured${NC}"
        echo -e "${YELLOW}   The ingress gateway LoadBalancer will fail without subnet annotation${NC}"
      fi
      
      echo ""
      echo -e "${CYAN}Installing east-west gateway on PRIMARY cluster...${NC}"
      cd "${ISTIO_DIR}/samples/multicluster"
      run_cmd bash -c "./gen-eastwest-gateway.sh --mesh oke-mesh --cluster primary-cluster --network primary-network | ${ISTIO_DIR}/bin/istioctl --context=$PRIMARY_CTX install -y -f -"
      cd "$PROJECT_ROOT"
      
      echo ""
      echo -e "${CYAN}Annotating east-west gateway with OCI subnet on PRIMARY...${NC}"
      if [[ -n "$primary_subnet" ]] && [[ "$primary_subnet" != *"your-"*"-subnet-id"* ]]; then
        run_cmd kubectl --context="$PRIMARY_CTX" annotate svc istio-eastwestgateway -n istio-system \
          service.beta.kubernetes.io/oci-load-balancer-subnet1="$primary_subnet" \
          service.beta.kubernetes.io/oci-load-balancer-shape="flexible" \
          service.beta.kubernetes.io/oci-load-balancer-shape-flex-min="10" \
          service.beta.kubernetes.io/oci-load-balancer-shape-flex-max="100" \
          --overwrite
        echo -e "${GREEN}✓${NC} East-west gateway annotated with subnet"
      fi
      
      echo ""
      echo -e "${CYAN}Exposing services for cross-cluster discovery on PRIMARY...${NC}"
      run_cmd kubectl --context="$PRIMARY_CTX" apply -n istio-system -f "${ISTIO_DIR}/samples/multicluster/expose-services.yaml"
      
      echo -e "${GREEN}✓${NC} Istio and east-west gateway installed on PRIMARY cluster"
    else
      echo -e "${YELLOW}Skipping PRIMARY cluster Istio installation${NC}"
      echo -e "${YELLOW}Manual install: ${ISTIO_DIR}/bin/istioctl install --context=$PRIMARY_CTX --set profile=demo -y${NC}"
    fi
  fi
  
  if kctx "$SECONDARY_CTX" get ns istio-system >/dev/null 2>&1; then
    if kctx "$SECONDARY_CTX" get deploy istiod -n istio-system >/dev/null 2>&1; then
      local ready_replicas
      ready_replicas=$(kctx "$SECONDARY_CTX" get deploy istiod -n istio-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
      if [ "$ready_replicas" -gt 0 ]; then
        echo -e "${GREEN}✓${NC} Istio installed and running on SECONDARY cluster"
        secondary_istio_ok=true
      fi
    fi
  fi
  
  if ! $secondary_istio_ok; then
    echo -e "${YELLOW}⚠  Istio not installed on SECONDARY cluster${NC}"
    echo ""
    read -r -p "Install Istio on SECONDARY cluster? (yes/no): " install_secondary
    
    if [ "$install_secondary" = "yes" ]; then
      echo -e "${CYAN}Installing Istio on SECONDARY cluster...${NC}"
      run_cmd "${ISTIO_DIR}/bin/istioctl" install --context="$SECONDARY_CTX" --set profile=demo -y
      
      echo ""
      echo -e "${CYAN}Annotating ingress gateway with OCI subnet on SECONDARY...${NC}"
      local secondary_subnet="${OCI_LB_SUBNET_SECONDARY:-}"
      if [[ -n "$secondary_subnet" ]] && [[ "$secondary_subnet" != *"your-"*"-subnet-id"* ]]; then
        run_cmd kubectl --context="$SECONDARY_CTX" annotate svc istio-ingressgateway -n istio-system \
          service.beta.kubernetes.io/oci-load-balancer-subnet1="$secondary_subnet" \
          service.beta.kubernetes.io/oci-load-balancer-shape="flexible" \
          service.beta.kubernetes.io/oci-load-balancer-shape-flex-min="10" \
          service.beta.kubernetes.io/oci-load-balancer-shape-flex-max="100" \
          --overwrite
        echo -e "${GREEN}✓${NC} Ingress gateway annotated with subnet"
      else
        echo -e "${RED}✗ ERROR: Valid subnet OCID not configured${NC}"
        echo -e "${YELLOW}   The ingress gateway LoadBalancer will fail without subnet annotation${NC}"
      fi
      
      echo ""
      echo -e "${CYAN}Installing east-west gateway on SECONDARY cluster...${NC}"
      cd "${ISTIO_DIR}/samples/multicluster"
      run_cmd bash -c "./gen-eastwest-gateway.sh --mesh oke-mesh --cluster secondary-cluster --network secondary-network | ${ISTIO_DIR}/bin/istioctl --context=$SECONDARY_CTX install -y -f -"
      cd "$PROJECT_ROOT"
      
      echo ""
      echo -e "${CYAN}Annotating east-west gateway with OCI subnet on SECONDARY...${NC}"
      if [[ -n "$secondary_subnet" ]] && [[ "$secondary_subnet" != *"your-"*"-subnet-id"* ]]; then
        run_cmd kubectl --context="$SECONDARY_CTX" annotate svc istio-eastwestgateway -n istio-system \
          service.beta.kubernetes.io/oci-load-balancer-subnet1="$secondary_subnet" \
          service.beta.kubernetes.io/oci-load-balancer-shape="flexible" \
          service.beta.kubernetes.io/oci-load-balancer-shape-flex-min="10" \
          service.beta.kubernetes.io/oci-load-balancer-shape-flex-max="100" \
          --overwrite
        echo -e "${GREEN}✓${NC} East-west gateway annotated with subnet"
      fi
      
      echo ""
      echo -e "${CYAN}Exposing services for cross-cluster discovery on SECONDARY...${NC}"
      run_cmd kubectl --context="$SECONDARY_CTX" apply -n istio-system -f "${ISTIO_DIR}/samples/multicluster/expose-services.yaml"
      
      echo -e "${GREEN}✓${NC} Istio and east-west gateway installed on SECONDARY cluster"
    else
      echo -e "${YELLOW}Skipping SECONDARY cluster Istio installation${NC}"
      echo -e "${YELLOW}Manual install: ${ISTIO_DIR}/bin/istioctl install --context=$SECONDARY_CTX --set profile=demo -y${NC}"
    fi
  fi
  
  echo ""
  echo -e "${CYAN}Setting up cross-cluster remote secrets for multi-cluster mesh...${NC}"
  
  # Check if remote secrets already exist
  if kubectl --context="$SECONDARY_CTX" get secret istio-remote-secret-primary-cluster -n istio-system >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠  Remote secret for primary cluster already exists in secondary${NC}"
  else
    echo -e "${CYAN}Creating remote secret for primary cluster in secondary...${NC}"
    run_cmd bash -c "${ISTIO_DIR}/bin/istioctl create-remote-secret --context=$PRIMARY_CTX --name=primary-cluster | kubectl apply -f - --context=$SECONDARY_CTX"
  fi
  
  if kubectl --context="$PRIMARY_CTX" get secret istio-remote-secret-secondary-cluster -n istio-system >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠  Remote secret for secondary cluster already exists in primary${NC}"
  else
    echo -e "${CYAN}Creating remote secret for secondary cluster in primary...${NC}"
    run_cmd bash -c "${ISTIO_DIR}/bin/istioctl create-remote-secret --context=$SECONDARY_CTX --name=secondary-cluster | kubectl apply -f - --context=$PRIMARY_CTX"
  fi
  
  echo ""
  echo -e "${GREEN}✓${NC} Prerequisites setup complete!"
}

# Apply EnvoyFilter to add cluster identification header
apply_cluster_header() {
  local ctx="$1"
  local cluster_name="$2"
  
  local filter_file="${PROJECT_ROOT}/yaml/envoy-filter-cluster-header.yaml"
  
  if [[ ! -f "$filter_file" ]]; then
    log "Cluster header filter not found, skipping"
    return 0
  fi
  
  log "Applying cluster identification header to $ctx"
  # Replace placeholder with actual cluster name
  sed "s/REPLACE_CLUSTER_NAME/${cluster_name}/g" "$filter_file" | \
    kctx "$ctx" apply -f -
  
  echo -e "${GREEN}✓${NC} Cluster identification header configured for $cluster_name"
}

# Step 1: Setup cluster infrastructure
setup_cluster() {
  local ctx="$1"
  local cluster_name="$2"
  
  show_step "SETTING UP $cluster_name CLUSTER"
  
  verify_istio "$ctx" || return 1
  verify_app_namespace "$ctx"
  deploy_bookinfo "$ctx"
  ensure_ingress_service "$ctx"
  scale_ingress_gateway "$ctx" 1
  apply_gateway "$ctx"
  apply_cluster_header "$ctx" "$cluster_name"
  
  echo ""
  echo -e "${GREEN}✓${NC} $cluster_name cluster setup complete!"
}

# Step 2: Setup primary cluster
setup_primary() {
  setup_cluster "$PRIMARY_CTX" "PRIMARY"
}

# Step 3: Setup secondary cluster
setup_secondary() {
  setup_cluster "$SECONDARY_CTX" "SECONDARY"
}

# Step 4: Verify deployment and get IPs
verify_deployment() {
  show_step "STEP 4: VERIFYING DEPLOYMENT"
  
  echo -e "${CYAN}Checking ingress gateway status...${NC}"
  echo ""
  echo -e "${BOLD}Primary cluster:${NC}"
  kctx "$PRIMARY_CTX" get deploy -n "$ISTIO_NS" istio-ingressgateway || true
  
  echo ""
  echo -e "${BOLD}Secondary cluster:${NC}"
  kctx "$SECONDARY_CTX" get deploy -n "$ISTIO_NS" istio-ingressgateway || true
  
  echo ""
  echo -e "${CYAN}Checking Bookinfo pods...${NC}"
  echo ""
  echo -e "${BOLD}Primary cluster:${NC}"
  kctx "$PRIMARY_CTX" get pods -n "$BOOKINFO_NS" || true
  
  echo ""
  echo -e "${BOLD}Secondary cluster:${NC}"
  kctx "$SECONDARY_CTX" get pods -n "$BOOKINFO_NS" || true
  
  echo ""
  echo -e "${CYAN}Checking Gateway/VirtualService status...${NC}"
  echo ""
  echo -e "${BOLD}Primary cluster:${NC}"
  kctx "$PRIMARY_CTX" get gateway,virtualservice -n "$BOOKINFO_NS" || true
  
  echo ""
  echo -e "${BOLD}Secondary cluster:${NC}"
  kctx "$SECONDARY_CTX" get gateway,virtualservice -n "$BOOKINFO_NS" || true
  
  echo ""
  echo -e "${CYAN}Waiting for LoadBalancer IPs (this may take 30-60 seconds)...${NC}"
  wait_for_ips "$PRIMARY_CTX" "istio-ingressgateway" "$ISTIO_NS" || true
  wait_for_ips "$SECONDARY_CTX" "istio-ingressgateway" "$ISTIO_NS" || true
  
  echo ""
  print_ips
  
  echo ""
  echo -e "${GREEN}✓${NC} Deployment verification complete!"
}

# Step 5: Test connectivity
test_connectivity() {
  show_step "STEP 5: TESTING CONNECTIVITY"
  
  local p_ingress s_ingress
  p_ingress=$(get_ip "$PRIMARY_CTX" istio-ingressgateway "$ISTIO_NS")
  s_ingress=$(get_ip "$SECONDARY_CTX" istio-ingressgateway "$ISTIO_NS")
  
  if [[ -n "${p_ingress:-}" ]]; then
    echo -e "${CYAN}Testing Primary cluster Bookinfo...${NC}"
    echo -e "${CYAN}▶ curl -s -o /dev/null -w '%{http_code}' http://${p_ingress}/productpage${NC}"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${p_ingress}/productpage" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" == "200" ]; then
      echo -e "${GREEN}✓${NC} Primary Bookinfo is ${GREEN}accessible${NC} (HTTP $HTTP_CODE)"
      
      # Show cluster identification header
      echo -e "${CYAN}▶ curl -sI http://${p_ingress}/productpage | grep X-Served-By-Cluster${NC}"
      CLUSTER_HEADER=$(curl -sI "http://${p_ingress}/productpage" 2>/dev/null | grep -i "X-Served-By-Cluster" || echo "")
      if [[ -n "$CLUSTER_HEADER" ]]; then
        echo -e "${GREEN}  ${CLUSTER_HEADER}${NC}"
      fi
    else
      echo -e "${YELLOW}⚠${NC}  Primary Bookinfo returned HTTP $HTTP_CODE"
    fi
  else
    echo -e "${YELLOW}⚠  Primary cluster LoadBalancer IP not assigned yet${NC}"
  fi
  
  echo ""
  if [[ -n "${s_ingress:-}" ]]; then
    echo -e "${CYAN}Testing Secondary cluster Bookinfo...${NC}"
    echo -e "${CYAN}▶ curl -s -o /dev/null -w '%{http_code}' http://${s_ingress}/productpage${NC}"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${s_ingress}/productpage" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" == "200" ]; then
      echo -e "${GREEN}✓${NC} Secondary Bookinfo is ${GREEN}accessible${NC} (HTTP $HTTP_CODE)"
      
      # Show cluster identification header
      echo -e "${CYAN}▶ curl -sI http://${s_ingress}/productpage | grep X-Served-By-Cluster${NC}"
      CLUSTER_HEADER=$(curl -sI "http://${s_ingress}/productpage" 2>/dev/null | grep -i "X-Served-By-Cluster" || echo "")
      if [[ -n "$CLUSTER_HEADER" ]]; then
        echo -e "${GREEN}  ${CLUSTER_HEADER}${NC}"
      fi
    else
      echo -e "${YELLOW}⚠${NC}  Secondary Bookinfo returned HTTP $HTTP_CODE"
    fi
  else
    echo -e "${YELLOW}⚠  Secondary cluster LoadBalancer IP not assigned yet${NC}"
  fi
  
  echo ""
  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${GREEN}  HOW TO DEMONSTRATE MULTI-CLUSTER SERVICE MESH${NC}"
  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${YELLOW}Open your browser and access the productpage:${NC}"
  if [[ -n "${p_ingress:-}" ]]; then
    echo -e "  ${GREEN}Primary:${NC}   http://${p_ingress}/productpage"
  fi
  if [[ -n "${s_ingress:-}" ]]; then
    echo -e "  ${GREEN}Secondary:${NC} http://${s_ingress}/productpage"
  fi
  echo ""
  echo -e "${YELLOW}What to show customers:${NC}"
  echo -e "  ${BOLD}1. Star Ratings Change${NC} - Refresh the page multiple times"
  echo -e "     • ${CYAN}No stars${NC}       = Reviews v1"
  echo -e "     • ${CYAN}Black stars ★${NC}  = Reviews v2"
  echo -e "     • ${CYAN}Red stars ⭐${NC}    = Reviews v3"
  echo -e "     This demonstrates Istio ${BOLD}load balancing${NC} across service versions"
  echo ""
  echo -e "  ${BOLD}2. Cluster Identification${NC} - Open Browser DevTools (F12)"
  echo -e "     • Go to ${CYAN}Network${NC} tab"
  echo -e "     • Refresh the page"
  echo -e "     • Click on the ${CYAN}productpage${NC} request"
  echo -e "     • Look for ${BOLD}X-Served-By-Cluster${NC} header in Response Headers"
  echo -e "     This shows ${BOLD}which cluster${NC} is serving the request"
  echo ""
  echo -e "  ${BOLD}3. Multi-Cluster Failover${NC} (Advanced)"
  echo -e "     Scale down productpage in primary:"
  echo -e "     ${CYAN}kubectl --context=$PRIMARY_CTX scale deployment productpage-v1 -n bookinfo --replicas=0${NC}"
  echo -e "     Refresh primary URL - requests ${BOLD}automatically route to secondary cluster${NC}!"
  echo ""
  echo -e "${GREEN}✓${NC} Connectivity tests complete!"
}

# Cleanup: Teardown cluster
teardown_cluster() {
  local ctx="$1"
  local cluster_name="$2"
  
  show_step "TEARING DOWN $cluster_name CLUSTER"
  
  delete_gateway "$ctx"
  scale_ingress_gateway "$ctx" 0
  delete_ingress_service "$ctx"
  
  log "Deleting application namespace $BOOKINFO_NS in $ctx"
  kctx "$ctx" delete ns "$BOOKINFO_NS" --ignore-not-found 2>/dev/null || true
  
  echo -e "${GREEN}✓${NC} $cluster_name cluster teardown complete!"
}

# Cleanup: Wipe all
wipe_all() {
  show_step "CLEANUP: REMOVING ALL RESOURCES"
  
  echo -e "${YELLOW}⚠  WARNING: This will remove ALL multi-cluster ingress resources${NC}"
  echo -e "${YELLOW}This operation will:${NC}"
  echo -e "  • Delete all Bookinfo deployments and services"
  echo -e "  • Delete all Gateway and VirtualService configurations"
  echo -e "  • Delete LoadBalancer services (releasing public IPs)"
  echo -e "  • Delete application namespaces"
  echo -e "  • Delete istio-system namespace (including Istio and cacerts)"
  echo -e "  • Delete generated CA certificates"
  echo ""
  read -r -p "Are you sure? Type 'yes' to confirm: " confirm
  
  if [ "$confirm" != "yes" ]; then
    echo -e "${YELLOW}Aborted${NC}"
    return
  fi
  
  teardown_cluster "$PRIMARY_CTX" "PRIMARY"
  echo ""
  teardown_cluster "$SECONDARY_CTX" "SECONDARY"
  
  echo ""
  echo -e "${CYAN}Removing CA certificate secrets from clusters...${NC}"
  run_cmd kubectl --context="$PRIMARY_CTX" delete secret cacerts -n istio-system --ignore-not-found
  run_cmd kubectl --context="$SECONDARY_CTX" delete secret cacerts -n istio-system --ignore-not-found
  echo -e "${GREEN}✓${NC} CA certificate secrets removed from clusters"
  
  echo ""
  echo -e "${CYAN}Removing remote secrets from clusters...${NC}"
  run_cmd kubectl --context="$PRIMARY_CTX" delete secret istio-remote-secret-secondary-cluster -n istio-system --ignore-not-found
  run_cmd kubectl --context="$SECONDARY_CTX" delete secret istio-remote-secret-primary-cluster -n istio-system --ignore-not-found
  echo -e "${GREEN}✓${NC} Remote secrets removed from clusters"
  
  echo ""
  echo -e "${CYAN}Removing istio-system namespace from both clusters...${NC}"
  run_cmd kubectl --context="$PRIMARY_CTX" delete ns istio-system --ignore-not-found
  run_cmd kubectl --context="$SECONDARY_CTX" delete ns istio-system --ignore-not-found
  echo -e "${GREEN}✓${NC} Istio-system namespaces removed"
  
  echo ""
  echo -e "${CYAN}Removing generated CA certificates...${NC}"
  
  # Remove certificates from project certs directory
  if [[ -d "$PROJECT_ROOT/certs/primary-cluster" ]]; then
    run_cmd rm -rf "$PROJECT_ROOT/certs/primary-cluster"
    echo -e "${GREEN}✓${NC} Removed primary-cluster certificates"
  fi
  
  if [[ -d "$PROJECT_ROOT/certs/secondary-cluster" ]]; then
    run_cmd rm -rf "$PROJECT_ROOT/certs/secondary-cluster"
    echo -e "${GREEN}✓${NC} Removed secondary-cluster certificates"
  fi
  
  # Remove root CA files from certs directory
  if [[ -f "$PROJECT_ROOT/certs/root-cert.pem" ]] || [[ -f "$PROJECT_ROOT/certs/root-key.pem" ]]; then
    run_cmd rm -f "$PROJECT_ROOT/certs/root-cert.pem" "$PROJECT_ROOT/certs/root-key.pem" "$PROJECT_ROOT/certs/root-cert.srl"
    echo -e "${GREEN}✓${NC} Removed root CA certificates"
  fi
  
  # Remove certificates from Istio directory
  if [[ -d "${ISTIO_DIR}/primary-cluster" ]]; then
    run_cmd rm -rf "${ISTIO_DIR}/primary-cluster"
  fi
  
  if [[ -d "${ISTIO_DIR}/secondary-cluster" ]]; then
    run_cmd rm -rf "${ISTIO_DIR}/secondary-cluster"
  fi
  
  if [[ -f "${ISTIO_DIR}/root-cert.pem" ]] || [[ -f "${ISTIO_DIR}/root-key.pem" ]]; then
    run_cmd rm -f "${ISTIO_DIR}/root-cert.pem" "${ISTIO_DIR}/root-key.pem" "${ISTIO_DIR}/root-cert.srl"
  fi
  
  echo ""
  echo -e "${GREEN}✓${NC} All resources and certificates removed successfully!"
}

# Full demo automation
run_full_demo() {
  show_step "AUTOMATED FULL DEMO"
  echo -e "${CYAN}This will execute:${NC}"
  echo -e "  Step 1: Install/Verify Prerequisites"
  echo -e "  Step 2: Setup Primary Cluster"
  echo -e "  Step 3: Setup Secondary Cluster"
  echo -e "  Step 4: Verify Deployment"
  echo -e "  Step 5: Test Connectivity"
  echo ""
  read -r -p "Continue? (yes/no): " confirm
  if [ "$confirm" != "yes" ]; then
    echo -e "${YELLOW}Aborted${NC}"
    return
  fi
  
  install_prerequisites || {
    echo -e "${RED}✗ Prerequisites setup failed${NC}"
    return 1
  }
  
  echo ""
  read -r -p "Press Enter to continue to Primary cluster setup..." _
  setup_primary
  
  echo ""
  read -r -p "Press Enter to continue to Secondary cluster setup..." _
  setup_secondary
  
  echo ""
  read -r -p "Press Enter to verify deployment..." _
  verify_deployment
  
  echo ""
  read -r -p "Press Enter to test connectivity..." _
  test_connectivity
  
  echo ""
  show_step "✓ FULL DEMO COMPLETE"
  echo -e "${GREEN}Multi-cluster ingress is now fully operational!${NC}"
  echo ""
  print_ips
}

# Status check
status_check() {
  show_step "STATUS CHECK"
  
  echo -e "${CYAN}Checking cluster connectivity...${NC}"
  ensure_contexts
  
  echo ""
  echo -e "${CYAN}Checking Istio installation...${NC}"
  verify_istio "$PRIMARY_CTX" || echo -e "${RED}✗ Primary cluster Istio check failed${NC}"
  verify_istio "$SECONDARY_CTX" || echo -e "${RED}✗ Secondary cluster Istio check failed${NC}"
  
  echo ""
  verify_deployment
}

# Failure simulation menu
simulate_failures() {
  show_step "FAILURE SIMULATION & RESILIENCE TESTING"
  
  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN}  FAILURE SIMULATION SCENARIOS${NC}"
  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${YELLOW}Select a failure scenario to simulate:${NC}"
  echo ""
  echo -e "  ${BOLD}1${NC}) 💥 Scale down productpage in PRIMARY (test cross-cluster routing)"
  echo -e "  ${BOLD}2${NC}) 💥 Scale down productpage in SECONDARY"
  echo -e "  ${BOLD}3${NC}) 💥 Scale down ALL reviews in PRIMARY (test service failover)"
  echo -e "  ${BOLD}4${NC}) 💥 Scale down ALL reviews in SECONDARY"
  echo -e "  ${BOLD}5${NC}) 💥 Scale down ingress gateway in PRIMARY (test LB failure)"
  echo -e "  ${BOLD}6${NC}) 💥 Scale down ingress gateway in SECONDARY"
  echo -e "  ${BOLD}7${NC}) 🔥 Total PRIMARY cluster failure (all workloads down)"
  echo -e "  ${BOLD}8${NC}) 🔥 Total SECONDARY cluster failure (all workloads down)"
  echo ""
  echo -e "${BOLD}${GREEN}RECOVERY OPTIONS:${NC}"
  echo -e "  ${BOLD}R${NC}) ♻️  Restore productpage in both clusters"
  echo -e "  ${BOLD}A${NC}) ♻️  Restore ALL workloads to normal state"
  echo ""
  echo -e "  ${BOLD}T${NC}) 🧪 Test connectivity after failure"
  echo -e "  ${BOLD}B${NC}) ⬅️  Back to main menu"
  echo ""
  
  read -r -p "$(echo -e "${BOLD}Select failure scenario:${NC} ")" scenario
  
  case "$scenario" in
    1)
      echo ""
      echo -e "${YELLOW}⚠  Simulating productpage failure in PRIMARY cluster...${NC}"
      echo -e "${CYAN}▶ kubectl --context=$PRIMARY_CTX scale deployment productpage-v1 -n $BOOKINFO_NS --replicas=0${NC}"
      kctx "$PRIMARY_CTX" scale deployment productpage-v1 -n "$BOOKINFO_NS" --replicas=0
      echo -e "${GREEN}✓${NC} Productpage scaled to 0 in PRIMARY"
      echo ""
      echo -e "${BOLD}${CYAN}Test this:${NC}"
      echo -e "  1. Access PRIMARY cluster URL: http://$(get_ip "$PRIMARY_CTX" istio-ingressgateway "$ISTIO_NS")/productpage"
      echo -e "  2. Check X-Served-By-Cluster header in browser DevTools"
      echo -e "  3. Traffic should ${BOLD}automatically route to SECONDARY cluster${NC}"
      ;;
    2)
      echo ""
      echo -e "${YELLOW}⚠  Simulating productpage failure in SECONDARY cluster...${NC}"
      echo -e "${CYAN}▶ kubectl --context=$SECONDARY_CTX scale deployment productpage-v1 -n $BOOKINFO_NS --replicas=0${NC}"
      kctx "$SECONDARY_CTX" scale deployment productpage-v1 -n "$BOOKINFO_NS" --replicas=0
      echo -e "${GREEN}✓${NC} Productpage scaled to 0 in SECONDARY"
      echo ""
      echo -e "${BOLD}${CYAN}Test this:${NC}"
      echo -e "  1. Access SECONDARY cluster URL: http://$(get_ip "$SECONDARY_CTX" istio-ingressgateway "$ISTIO_NS")/productpage"
      echo -e "  2. Traffic should ${BOLD}automatically route to PRIMARY cluster${NC}"
      ;;
    3)
      echo ""
      echo -e "${YELLOW}⚠  Simulating reviews service failure in PRIMARY cluster...${NC}"
      echo -e "${CYAN}▶ Scaling down all reviews versions (v1, v2, v3) in PRIMARY${NC}"
      kctx "$PRIMARY_CTX" scale deployment reviews-v1 -n "$BOOKINFO_NS" --replicas=0
      kctx "$PRIMARY_CTX" scale deployment reviews-v2 -n "$BOOKINFO_NS" --replicas=0
      kctx "$PRIMARY_CTX" scale deployment reviews-v3 -n "$BOOKINFO_NS" --replicas=0
      echo -e "${GREEN}✓${NC} All reviews services scaled to 0 in PRIMARY"
      echo ""
      echo -e "${BOLD}${CYAN}Test this:${NC}"
      echo -e "  1. Access PRIMARY cluster URL and refresh multiple times"
      echo -e "  2. Reviews should ${BOLD}come from SECONDARY cluster${NC}"
      echo -e "  3. Star ratings should still change (proving cross-cluster routing)"
      ;;
    4)
      echo ""
      echo -e "${YELLOW}⚠  Simulating reviews service failure in SECONDARY cluster...${NC}"
      echo -e "${CYAN}▶ Scaling down all reviews versions (v1, v2, v3) in SECONDARY${NC}"
      kctx "$SECONDARY_CTX" scale deployment reviews-v1 -n "$BOOKINFO_NS" --replicas=0
      kctx "$SECONDARY_CTX" scale deployment reviews-v2 -n "$BOOKINFO_NS" --replicas=0
      kctx "$SECONDARY_CTX" scale deployment reviews-v3 -n "$BOOKINFO_NS" --replicas=0
      echo -e "${GREEN}✓${NC} All reviews services scaled to 0 in SECONDARY"
      echo ""
      echo -e "${BOLD}${CYAN}Test this:${NC}"
      echo -e "  1. Access SECONDARY cluster URL and refresh multiple times"
      echo -e "  2. Reviews should ${BOLD}come from PRIMARY cluster${NC}"
      ;;
    5)
      echo ""
      echo -e "${YELLOW}⚠  Simulating ingress gateway failure in PRIMARY cluster...${NC}"
      echo -e "${CYAN}▶ kubectl --context=$PRIMARY_CTX scale deployment istio-ingressgateway -n $ISTIO_NS --replicas=0${NC}"
      kctx "$PRIMARY_CTX" scale deployment istio-ingressgateway -n "$ISTIO_NS" --replicas=0
      echo -e "${GREEN}✓${NC} Ingress gateway scaled to 0 in PRIMARY"
      echo ""
      echo -e "${BOLD}${CYAN}Expected behavior:${NC}"
      echo -e "  1. PRIMARY cluster URL will become ${RED}inaccessible${NC}"
      echo -e "  2. OCI LoadBalancer health checks will fail"
      echo -e "  3. ${BOLD}Use SECONDARY cluster URL${NC} for continued access"
      echo -e "  4. This simulates a ${BOLD}complete ingress failure${NC}"
      ;;
    6)
      echo ""
      echo -e "${YELLOW}⚠  Simulating ingress gateway failure in SECONDARY cluster...${NC}"
      echo -e "${CYAN}▶ kubectl --context=$SECONDARY_CTX scale deployment istio-ingressgateway -n $ISTIO_NS --replicas=0${NC}"
      kctx "$SECONDARY_CTX" scale deployment istio-ingressgateway -n "$ISTIO_NS" --replicas=0
      echo -e "${GREEN}✓${NC} Ingress gateway scaled to 0 in SECONDARY"
      echo ""
      echo -e "${BOLD}${CYAN}Expected behavior:${NC}"
      echo -e "  1. SECONDARY cluster URL will become ${RED}inaccessible${NC}"
      echo -e "  2. ${BOLD}Use PRIMARY cluster URL${NC} for continued access"
      ;;
    7)
      echo ""
      echo -e "${RED}🔥 Simulating TOTAL PRIMARY cluster failure...${NC}"
      echo -e "${YELLOW}This will scale down ALL workloads in PRIMARY cluster${NC}"
      echo ""
      read -r -p "Are you sure? (yes/no): " confirm
      if [ "$confirm" != "yes" ]; then
        echo -e "${YELLOW}Aborted${NC}"
        return
      fi
      
      echo -e "${CYAN}▶ Scaling down all Bookinfo workloads in PRIMARY...${NC}"
      kctx "$PRIMARY_CTX" scale deployment productpage-v1 -n "$BOOKINFO_NS" --replicas=0
      kctx "$PRIMARY_CTX" scale deployment details-v1 -n "$BOOKINFO_NS" --replicas=0
      kctx "$PRIMARY_CTX" scale deployment reviews-v1 -n "$BOOKINFO_NS" --replicas=0
      kctx "$PRIMARY_CTX" scale deployment reviews-v2 -n "$BOOKINFO_NS" --replicas=0
      kctx "$PRIMARY_CTX" scale deployment reviews-v3 -n "$BOOKINFO_NS" --replicas=0
      kctx "$PRIMARY_CTX" scale deployment ratings-v1 -n "$BOOKINFO_NS" --replicas=0
      kctx "$PRIMARY_CTX" scale deployment istio-ingressgateway -n "$ISTIO_NS" --replicas=0
      
      echo -e "${RED}💥${NC} PRIMARY cluster completely down"
      echo ""
      echo -e "${BOLD}${CYAN}Test disaster recovery:${NC}"
      echo -e "  1. Try accessing PRIMARY URL - should ${RED}FAIL${NC}"
      echo -e "  2. Access SECONDARY URL - should ${GREEN}WORK PERFECTLY${NC}"
      echo -e "  3. All services running from SECONDARY cluster only"
      echo -e "  4. This demonstrates ${BOLD}active-active DR${NC}"
      ;;
    8)
      echo ""
      echo -e "${RED}🔥 Simulating TOTAL SECONDARY cluster failure...${NC}"
      echo -e "${YELLOW}This will scale down ALL workloads in SECONDARY cluster${NC}"
      echo ""
      read -r -p "Are you sure? (yes/no): " confirm
      if [ "$confirm" != "yes" ]; then
        echo -e "${YELLOW}Aborted${NC}"
        return
      fi
      
      echo -e "${CYAN}▶ Scaling down all Bookinfo workloads in SECONDARY...${NC}"
      kctx "$SECONDARY_CTX" scale deployment productpage-v1 -n "$BOOKINFO_NS" --replicas=0
      kctx "$SECONDARY_CTX" scale deployment details-v1 -n "$BOOKINFO_NS" --replicas=0
      kctx "$SECONDARY_CTX" scale deployment reviews-v1 -n "$BOOKINFO_NS" --replicas=0
      kctx "$SECONDARY_CTX" scale deployment reviews-v2 -n "$BOOKINFO_NS" --replicas=0
      kctx "$SECONDARY_CTX" scale deployment reviews-v3 -n "$BOOKINFO_NS" --replicas=0
      kctx "$SECONDARY_CTX" scale deployment ratings-v1 -n "$BOOKINFO_NS" --replicas=0
      kctx "$SECONDARY_CTX" scale deployment istio-ingressgateway -n "$ISTIO_NS" --replicas=0
      
      echo -e "${RED}💥${NC} SECONDARY cluster completely down"
      echo ""
      echo -e "${BOLD}${CYAN}Test disaster recovery:${NC}"
      echo -e "  1. Try accessing SECONDARY URL - should ${RED}FAIL${NC}"
      echo -e "  2. Access PRIMARY URL - should ${GREEN}WORK PERFECTLY${NC}"
      echo -e "  3. All services running from PRIMARY cluster only"
      ;;
    R|r)
      echo ""
      echo -e "${GREEN}♻️  Restoring productpage in both clusters...${NC}"
      echo -e "${CYAN}▶ kubectl --context=$PRIMARY_CTX scale deployment productpage-v1 -n $BOOKINFO_NS --replicas=1${NC}"
      kctx "$PRIMARY_CTX" scale deployment productpage-v1 -n "$BOOKINFO_NS" --replicas=1
      echo -e "${CYAN}▶ kubectl --context=$SECONDARY_CTX scale deployment productpage-v1 -n $BOOKINFO_NS --replicas=1${NC}"
      kctx "$SECONDARY_CTX" scale deployment productpage-v1 -n "$BOOKINFO_NS" --replicas=1
      
      echo ""
      echo -e "${CYAN}Waiting for pods to be ready...${NC}"
      kctx "$PRIMARY_CTX" wait --for=condition=ready pod -l app=productpage -n "$BOOKINFO_NS" --timeout=60s 2>/dev/null || true
      kctx "$SECONDARY_CTX" wait --for=condition=ready pod -l app=productpage -n "$BOOKINFO_NS" --timeout=60s 2>/dev/null || true
      
      echo -e "${GREEN}✓${NC} Productpage restored in both clusters"
      ;;
    A|a)
      echo ""
      echo -e "${GREEN}♻️  Restoring ALL workloads to normal state...${NC}"
      
      echo -e "${CYAN}Restoring PRIMARY cluster...${NC}"
      kctx "$PRIMARY_CTX" scale deployment productpage-v1 -n "$BOOKINFO_NS" --replicas=1
      kctx "$PRIMARY_CTX" scale deployment details-v1 -n "$BOOKINFO_NS" --replicas=1
      kctx "$PRIMARY_CTX" scale deployment reviews-v1 -n "$BOOKINFO_NS" --replicas=1
      kctx "$PRIMARY_CTX" scale deployment reviews-v2 -n "$BOOKINFO_NS" --replicas=1
      kctx "$PRIMARY_CTX" scale deployment reviews-v3 -n "$BOOKINFO_NS" --replicas=1
      kctx "$PRIMARY_CTX" scale deployment ratings-v1 -n "$BOOKINFO_NS" --replicas=1
      kctx "$PRIMARY_CTX" scale deployment istio-ingressgateway -n "$ISTIO_NS" --replicas=1
      
      echo -e "${CYAN}Restoring SECONDARY cluster...${NC}"
      kctx "$SECONDARY_CTX" scale deployment productpage-v1 -n "$BOOKINFO_NS" --replicas=1
      kctx "$SECONDARY_CTX" scale deployment details-v1 -n "$BOOKINFO_NS" --replicas=1
      kctx "$SECONDARY_CTX" scale deployment reviews-v1 -n "$BOOKINFO_NS" --replicas=1
      kctx "$SECONDARY_CTX" scale deployment reviews-v2 -n "$BOOKINFO_NS" --replicas=1
      kctx "$SECONDARY_CTX" scale deployment reviews-v3 -n "$BOOKINFO_NS" --replicas=1
      kctx "$SECONDARY_CTX" scale deployment ratings-v1 -n "$BOOKINFO_NS" --replicas=1
      kctx "$SECONDARY_CTX" scale deployment istio-ingressgateway -n "$ISTIO_NS" --replicas=1
      
      echo ""
      echo -e "${CYAN}Waiting for pods to be ready...${NC}"
      sleep 5
      echo -e "${GREEN}✓${NC} All workloads restored to normal state"
      echo ""
      echo -e "${YELLOW}Run 'Test Connectivity' (option 5) to verify full recovery${NC}"
      ;;
    T|t)
      test_connectivity
      ;;
    B|b)
      return
      ;;
    *)
      echo -e "${RED}✗ Invalid option${NC}"
      ;;
  esac
  
  echo ""
  echo -e "${BOLD}${CYAN}───────────────────────────────────────────────────────────${NC}"
  read -r -p "$(echo -e "${CYAN}Press Enter to return to failure simulation menu...${NC}")" _
  simulate_failures
}

# Main menu
show_menu() {
  echo ""
  echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║  OKE MULTI-CLUSTER INGRESS DEMO - END-TO-END RUNNER      ║${NC}"
  echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${BOLD}${YELLOW}CLEANUP OPTIONS:${NC}"
  echo -e "  ${BOLD}0${NC}) 🧹 Wipe All Resources"
  echo ""
  echo -e "${BOLD}${GREEN}SETUP & DEMO WORKFLOW:${NC}"
  echo -e "  ${BOLD}1${NC}) ✅ Install/Verify Prerequisites (Istio, samples)"
  echo -e "  ${BOLD}2${NC}) 🚀 Setup Primary Cluster"
  echo -e "  ${BOLD}3${NC}) 🚀 Setup Secondary Cluster"
  echo -e "  ${BOLD}4${NC}) 🔍 Verify Deployment"
  echo -e "  ${BOLD}5${NC}) 🧪 Test Connectivity"
  echo ""
  echo -e "${BOLD}${BLUE}STATUS & VERIFICATION:${NC}"
  echo -e "  ${BOLD}6${NC}) 📊 Status Check & Current IPs"
  echo -e "  ${BOLD}7${NC}) 📋 Print Current IPs"
  echo ""
  echo -e "${BOLD}${RED}FAILURE SIMULATION & TESTING:${NC}"
  echo -e "  ${BOLD}8${NC}) 💥 Simulate Failures & Test Resilience"
  echo ""
  echo -e "${BOLD}${MAGENTA}AUTOMATED OPTIONS:${NC}"
  echo -e "  ${BOLD}A${NC}) 🎯 Run Full Demo (Steps 1-5)"
  echo ""
  echo -e "${BOLD}Q${NC}) ❌ Exit"
  echo ""
}

# Main loop
main() {
  while true; do
    show_menu
    read -r -p "$(echo -e "${BOLD}Select option:${NC} ")" choice
    
    case "$choice" in
      0) wipe_all ;;
      1) install_prerequisites ;;
      2) setup_primary ;;
      3) setup_secondary ;;
      4) verify_deployment ;;
      5) test_connectivity ;;
      6) status_check ;;
      7) print_ips ;;
      8) simulate_failures ;;
      A|a) run_full_demo ;;
      Q|q) 
        echo -e "${GREEN}Goodbye!${NC}"
        exit 0
        ;;
      *)
        echo -e "${RED}✗ Invalid option${NC}"
        ;;
    esac
    
    echo ""
    echo -e "${BOLD}${CYAN}───────────────────────────────────────────────────────────${NC}"
    read -r -p "$(echo -e "${CYAN}Press Enter to return to menu...${NC}")" _
  done
}

# Entry point
main
