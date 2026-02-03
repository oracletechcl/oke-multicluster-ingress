# Multi-Cluster Ingress Menu Guide

This guide explains how to use the `multicluster-ingress-menu.sh` script to manage and rebuild the multi-cluster ingress infrastructure from scratch.

## Overview

The enhanced script provides a menu-driven interface to:
- **Status Checking**: View current ingress gateway status and LoadBalancer IPs
- **Full-Stack Setup**: Rebuild the entire infrastructure from scratch (useful after cluster deletion)
- **Cluster-Specific Setup**: Configure ingress for primary or secondary cluster independently
- **Ingress Management**: Enable/disable ingress with flexible load balancer service handling
- **IP Lookup**: Retrieve current LoadBalancer IPs for testing

## Prerequisites

1. **kubectl** installed and configured with access to both OKE clusters
2. **KUBECONFIG** pointing to both cluster contexts or proper context configuration
3. **Istio 1.28.3** already installed on both clusters (required for full setup)
4. **Bookinfo app manifests** available at default location or via custom path

## Configuration

### Environment Variables

The script respects these environment variables for flexibility:

```bash
# Cluster contexts
PRIMARY_CTX="${PRIMARY_CTX:-primary-cluster-context}"
SECONDARY_CTX="${SECONDARY_CTX:-secondary-cluster}"

# Application configuration
BOOKINFO_NS="${BOOKINFO_NS:-bookinfo}"
ISTIO_NS="${ISTIO_NS:-istio-system}"

# File paths (auto-computed relative to script location)
BOOKINFO_APP_FILE="${BOOKINFO_APP_FILE:-${ROOT_DIR}/istio-1.28.3/samples/bookinfo/platform/kube/bookinfo.yaml}"
GATEWAY_FILE="${GATEWAY_FILE:-${ROOT_DIR}/istio-1.28.3/samples/bookinfo/networking/bookinfo-gateway.yaml}"

# LoadBalancer service recreation
INGRESS_SVC_MANIFEST="${INGRESS_SVC_MANIFEST:-}"

# Istio version
ISTIO_VERSION="${ISTIO_VERSION:-1.28.3}"
```

### Setting Custom Contexts

```bash
# Export before running script
export PRIMARY_CTX="my-primary-cluster"
export SECONDARY_CTX="my-secondary-cluster"
./bash/multicluster-ingress-menu.sh
```

### Using a Different App

```bash
# Deploy a different application instead of Bookinfo
export BOOKINFO_APP_FILE="/path/to/my-app.yaml"
./bash/multicluster-ingress-menu.sh
# Then select option 2 (Setup entire stack) or 3/4 (single cluster setup)
```

## Menu Options

### 1. Status Check + Current IPs
Displays:
- Ingress gateway deployment status for both clusters
- Bookinfo Gateway and VirtualService status
- Current LoadBalancer IPs (ingress and east-west)
- Browser URLs for testing

### 2. Setup Entire Stack From Scratch
Performs complete multi-cluster ingress infrastructure setup:

```
For PRIMARY_CTX:
  ✓ Verify Istio is installed
  ✓ Create/verify bookinfo namespace with sidecar injection
  ✓ Deploy application (Bookinfo by default)
  ✓ Wait for application pods to be ready
  ✓ Ensure ingress LoadBalancer service exists
  ✓ Scale ingress gateway to 1 replica
  ✓ Apply Bookinfo Gateway/VirtualService configuration

For SECONDARY_CTX:
  ✓ Repeat all above steps

Final Result:
  ✓ Multi-cluster ingress fully operational
  ✓ LoadBalancer IPs assigned (may take 30-60 seconds)
  ✓ Display current IPs for testing
```

**Use Case**: Complete infrastructure rebuild after cluster deletion

**Idempotent**: Yes - safe to re-run, won't duplicate resources

**Timeout**: 180 seconds per cluster for pod readiness

### 3. Setup Cluster (Primary)
Configures ingress stack for primary cluster only. Same steps as option 2 but only for `PRIMARY_CTX`.

**Use Case**: Recover single cluster or apply setup to only one cluster

### 4. Setup Cluster (Secondary)
Configures ingress stack for secondary cluster only. Same steps as option 3 but for `SECONDARY_CTX`.

### 5. Enable Ingress (Submenu)

```
-- Enable Ingress Submenu --
1) Enable ingress (primary)
2) Enable ingress (secondary)
3) Enable ingress (all)
4) Enable ingress (primary) + recreate LB service
5) Enable ingress (secondary) + recreate LB service
6) Enable ingress (all) + recreate LB services
```

**1-3: Standard Enable**
- Ensures LoadBalancer service exists (prerequisite)
- Scales ingress gateway to 1 replica
- Applies Gateway/VirtualService configuration

**4-6: Enable with LB Recreation**
- Deletes and recreates LoadBalancer service
- New external IP will be assigned
- Useful when LoadBalancer service was deleted or corrupted

**Idempotent**: Yes - multiple runs safe

### 6. Disable Ingress (Submenu)

```
-- Disable Ingress Submenu --
1) Disable ingress (primary)
2) Disable ingress (secondary)
3) Disable ingress (all)
4) Disable ingress (primary) + delete LB service
5) Disable ingress (secondary) + delete LB service
6) Disable ingress (all) + delete LB services
```

**1-3: Standard Disable**
- Deletes Gateway/VirtualService
- Scales ingress gateway to 0 replicas
- Preserves LoadBalancer service

**4-6: Disable with LB Deletion**
- Deletes Gateway/VirtualService
- Scales ingress gateway to 0 replicas
- Deletes LoadBalancer service completely
- IPs will be released (useful for cleanup)

**Idempotent**: Yes - multiple runs safe

### 7. Print Current IPs
Displays current LoadBalancer IPs and browser test URLs without performing any changes.

### 0. Exit
Exits the menu script.

## Common Workflows

### Workflow 1: Complete Rebuild After Cluster Deletion

```bash
# Both clusters are destroyed, you've recreated OKE instances
# Istio is already installed on both new clusters

export PRIMARY_CTX="primary-cluster"
export SECONDARY_CTX="secondary-cluster"
./bash/multicluster-ingress-menu.sh

# At menu, select: 2 (Setup entire stack from scratch)
# Wait for completion (~5 minutes total)
# Script displays LoadBalancer IPs automatically
```

### Workflow 2: Deploy Different Application

```bash
# You have a new microservices app to deploy instead of Bookinfo
# App YAML follows standard Kubernetes deployment format
# Should have pod label for readiness check (e.g., app=myapp)

export BOOKINFO_APP_FILE="/path/to/my-app.yaml"
./bash/multicluster-ingress-menu.sh

# Option 2: Setup entire stack from scratch
# Or option 3/4 for single cluster
```

### Workflow 3: Recover Primary Cluster Only

```bash
# Primary cluster had issues, secondary is operational
./bash/multicluster-ingress-menu.sh

# Option 3: Setup cluster (primary)
# Secondary remains unchanged
```

### Workflow 4: Disable for Maintenance

```bash
./bash/multicluster-ingress-menu.sh

# Option 6: Disable ingress (submenu)
#   Option 6: Disable all + delete LB services
# Maintenance work...
# Option 5: Enable ingress (submenu)
#   Option 6: Enable all + recreate LB services
```

### Workflow 5: Check Status Only

```bash
./bash/multicluster-ingress-menu.sh

# Option 1: Status check + current IPs
# View current configuration without making changes
```

## Debugging

### Script Execution with Verbose Output

```bash
bash -x ./bash/multicluster-ingress-menu.sh
```

### Check Istio Installation

```bash
# Verify Istio is installed
kubectl --context=primary-cluster get ns istio-system
kubectl --context=primary-cluster get deploy istiod -n istio-system
```

### Verify App File Exists

```bash
# Check BOOKINFO_APP_FILE
ls -la $BOOKINFO_APP_FILE

# Or with custom path
ls -la /path/to/my-app.yaml
```

### Check LoadBalancer IP Status

```bash
# Get ingress IP
kubectl --context=primary-cluster get svc istio-ingressgateway -n istio-system

# Get east-west IP
kubectl --context=primary-cluster get svc istio-eastwestgateway -n istio-system

# Wait for external IP to be assigned
kubectl --context=primary-cluster get svc istio-ingressgateway -n istio-system --watch
```

### Verify Pods are Ready

```bash
# Check app pod status
kubectl --context=primary-cluster get pods -n bookinfo
kubectl --context=primary-cluster describe pod -n bookinfo | grep -E "Ready|Status"
```

## Important Notes

### Istio Prerequisite

The script **requires Istio to be pre-installed** on both clusters. If Istio is not found, the script will:
- Log an error message
- Return failure status
- Not continue with app/ingress setup

**To install Istio manually**:
```bash
# Using istioctl
istioctl install --set profile=production -y --context=primary-cluster

# Or using Istio operator (helm)
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm install istio-base istio/base -n istio-system --create-namespace
```

### Pod Readiness Timeout

App deployment waits 180 seconds for `app=productpage` pods to be ready (Bookinfo default). If using a different app:
- Ensure pods have appropriate labels
- Modify `deploy_app()` function if label differs
- Or monitor manually: `kubectl get pods -n bookinfo --watch`

### LoadBalancer Service Creation

If `INGRESS_SVC_MANIFEST` is not set:
- Script assumes LoadBalancer service already exists
- Or will be created by Istio during ingress gateway scaling
- Set `INGRESS_SVC_MANIFEST` to a manifest file to explicitly create the service

### Sidecar Injection

The script automatically labels the application namespace with `istio-injection=enabled` to enable automatic sidecar injection. Ensure:
- Istio is installed with sidecar controller enabled
- Namespace exists before pod deployment (handled by script)

## Function Reference

### Idempotent Functions

These functions can be safely called multiple times:

| Function | Behavior | Safe to Re-run |
|----------|----------|---|
| `verify_istio(ctx)` | Check Istio installation | Yes |
| `verify_app_namespace(ctx)` | Create namespace if missing | Yes |
| `deploy_app(ctx)` | Apply app manifests idempotently | Yes |
| `setup_cluster_ingress(ctx)` | Full setup for one cluster | Yes |
| `setup_all_from_scratch()` | Full multi-cluster setup | Yes |
| `enable_primary/secondary/all()` | Enable ingress | Yes |
| `disable_primary/secondary/all()` | Disable ingress | Yes |
| `scale_ingress_gateway()` | Scale to specific replica count | Yes |
| `apply_gateway()` | Apply Gateway/VirtualService | Yes |
| `delete_gateway()` | Delete Gateway/VirtualService | Yes |

### Helper Functions

| Function | Purpose |
|----------|---------|
| `get_ip(ctx, svc, ns)` | Retrieve LoadBalancer external IP |
| `print_ips()` | Display all current LoadBalancer IPs |
| `log()` | Timestamped colored logging |
| `kctx(ctx, ...)` | Execute kubectl with specific context |
| `ensure_contexts()` | Verify both cluster contexts are accessible |

## Performance

- **Full setup (both clusters)**: ~5-10 minutes
  - Includes waiting for pod readiness (180s per cluster)
  - LoadBalancer IP assignment may take 30-60 seconds
- **Single cluster setup**: ~2-5 minutes
- **Enable/disable operations**: 10-30 seconds
- **Status check**: < 5 seconds

## Security Considerations

- Script uses current kubectl authentication (respects KUBECONFIG)
- No credentials stored in script or environment
- Sidecar injection configured automatically (mTLS via Istio)
- Uses `--ignore-not-found` for safe deletion of non-existent resources
- All file operations validate file existence before use

## Troubleshooting Quick Reference

| Issue | Solution |
|-------|----------|
| "Primary context not reachable" | Update `PRIMARY_CTX` env var or KUBECONFIG |
| "Istio not found" | Install Istio: `istioctl install --set profile=production -y` |
| "App file not found" | Set `BOOKINFO_APP_FILE` to correct path |
| "LoadBalancer IP <pending>" | Wait 30-60 seconds, then check option 1 again |
| "Pods not ready" | Check pod logs: `kubectl logs -n bookinfo <pod>` |
| "Gateway not created" | Verify namespace exists and sidecar injection enabled |
| Menu not showing colors | Script auto-detects TTY; may need to source differently |

## Advanced Usage

### Scripting the Menu

```bash
# Run setup without interactive menu
PRIMARY_CTX="primary" SECONDARY_CTX="secondary" \
  bash -c 'source ./bash/multicluster-ingress-menu.sh; setup_all_from_scratch'
```

### Custom Application with Different Labels

Edit `deploy_app()` function to match your pod labels:

```bash
# Before: app=productpage
# After: app=myapp

# In deploy_app() function, change:
kctx "$ctx" wait --for=condition=ready pod -l app=myapp -n "$BOOKINFO_NS" ...
```

### Integration with CI/CD

```bash
# Makefile example
setup-infra:
	export BOOKINFO_APP_FILE=$(APP_MANIFEST); \
	export PRIMARY_CTX=$(PRIMARY_CONTEXT); \
	export SECONDARY_CTX=$(SECONDARY_CONTEXT); \
	bash -c 'source ./bash/multicluster-ingress-menu.sh; setup_all_from_scratch'
```

## Related Documentation

- [README.md](../README.md) - Project overview
- [QUICKSTART.md](QUICKSTART.md) - Getting started guide
- [WEEK5_DR_DRILLS_AND_HANDOFF.md](WEEK5_DR_DRILLS_AND_HANDOFF.md) - DR procedures
- [bash/dr-drill-menu.sh](../bash/dr-drill-menu.sh) - DR scenario testing script
