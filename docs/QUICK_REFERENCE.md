# Quick Reference: Operational Scripts

## One-Command Infrastructure Rebuild

After complete cluster deletion, rebuild everything from scratch:

```bash
export PRIMARY_CTX="primary-cluster"
export SECONDARY_CTX="secondary-cluster"
./bash/multicluster-ingress-menu.sh
# Select: 2 (Setup entire stack from scratch)
# Wait ~5-10 minutes for completion
```

## Environment Variables

```bash
# Cluster contexts
PRIMARY_CTX="primary-cluster"           # Primary OKE cluster context
SECONDARY_CTX="secondary-cluster"       # Secondary OKE cluster context

# Kubernetes namespaces
BOOKINFO_NS="bookinfo"                  # Application namespace
ISTIO_NS="istio-system"                 # Istio system namespace

# Application files
BOOKINFO_APP_FILE="/path/to/app.yaml"   # Custom app deployment YAML
GATEWAY_FILE="/path/to/gateway.yaml"    # Gateway/VirtualService YAML

# Service manifests
INGRESS_SVC_MANIFEST="/path/to/svc.yaml" # LoadBalancer service YAML

# Version
ISTIO_VERSION="1.28.3"                  # Istio version
```

## Common Tasks

### Full Infrastructure Rebuild (After Cluster Deletion)

```bash
# Option 1: Interactive menu
./bash/multicluster-ingress-menu.sh
# Select: 2

# Option 2: Non-interactive
bash -c 'source ./bash/multicluster-ingress-menu.sh; setup_all_from_scratch'
```

### Deploy Custom Application

```bash
# Set custom app file
export BOOKINFO_APP_FILE="/path/to/my-app.yaml"

# Run menu or direct setup
./bash/multicluster-ingress-menu.sh
# Select: 2 (Setup from scratch) or 3/4 (Single cluster)
```

### Recover Single Cluster

```bash
# Primary cluster recovery
./bash/multicluster-ingress-menu.sh
# Select: 3 (Setup cluster primary)

# Secondary cluster recovery
./bash/multicluster-ingress-menu.sh
# Select: 4 (Setup cluster secondary)
```

### Enable/Disable Ingress

```bash
./bash/multicluster-ingress-menu.sh

# Enable both clusters
# Select: 5 (Enable ingress submenu)
#   Then: 3 (Enable all)

# Disable both clusters
# Select: 6 (Disable ingress submenu)
#   Then: 3 (Disable all)
```

### Get Current LoadBalancer IPs

```bash
# Option 1: Check status and IPs
./bash/multicluster-ingress-menu.sh
# Select: 1 or 7

# Option 2: Direct command
kubectl get svc istio-ingressgateway -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

## DR Drill Scenarios

```bash
# Run interactive DR drills
./bash/dr-drill-menu.sh

# Available scenarios:
# 1. Ingress failover test
# 2. Control plane failover test
# 3. Pod failure test
# 4. East-west gateway failover test
# 5. Latency injection test
# 6. Run all scenarios
# 7. Partial recovery
# 8. Total recovery
```

## Function Reference

### Setup Functions

```bash
# Verify Istio installation
verify_istio "primary-cluster"

# Create app namespace
verify_app_namespace "primary-cluster"

# Deploy application
deploy_app "primary-cluster"

# Complete cluster setup
setup_cluster_ingress "primary-cluster"

# Full multi-cluster setup
setup_all_from_scratch
```

### Ingress Management Functions

```bash
# Enable ingress
enable_primary
enable_secondary
enable_all

# Disable ingress
disable_primary
disable_secondary
disable_all

# With LoadBalancer service recreation
enable_primary_with_lb
disable_primary_with_lb
```

### Utility Functions

```bash
# Get LoadBalancer IP
get_ip "primary-cluster" "istio-ingressgateway" "istio-system"

# Display all IPs and browser URLs
print_ips

# Check status
status_check

# Execute kubectl with specific context
kctx "primary-cluster" get pods -n bookinfo
```

## Pre-Requisites Check

Before running setup scripts:

```bash
# Verify kubectl is installed
which kubectl

# Verify cluster contexts are configured
kubectl config get-contexts

# Verify Istio is installed on both clusters
kubectl --context=primary-cluster get ns istio-system
kubectl --context=primary-cluster get deploy istiod -n istio-system

# Verify application YAML exists
ls -la $BOOKINFO_APP_FILE

# Verify gateway YAML exists
ls -la $GATEWAY_FILE
```

## Timeout Values

| Operation | Timeout | Behavior |
|-----------|---------|----------|
| Pod readiness | 180s | Warns if pods not ready, continues anyway |
| Kubectl operations | Default | Fails if timeout exceeded |
| LoadBalancer IP assignment | None (manual check) | Takes 30-60s typically |

## Troubleshooting

### Script Fails: "Istio not found"

**Solution**: Install Istio on both clusters first

```bash
istioctl install --set profile=production -y --context=primary-cluster
istioctl install --set profile=production -y --context=secondary-cluster
```

### LoadBalancer IPs show `<pending>`

**Solution**: Wait 30-60 seconds, then check again

```bash
# Watch for IP assignment
kubectl get svc istio-ingressgateway -n istio-system --watch
```

### Pods not ready after 180 seconds

**Solution**: Check pod logs and events

```bash
kubectl get pods -n bookinfo
kubectl describe pod <pod-name> -n bookinfo
kubectl logs <pod-name> -n bookinfo
```

### "Context not reachable"

**Solution**: Update kubeconfig and context names

```bash
export PRIMARY_CTX=$(kubectl config current-context)
# Or set manually:
export PRIMARY_CTX="my-primary-cluster"
```

## Security Notes

- Scripts use current kubectl authentication
- No credentials stored in scripts
- Istio mTLS enabled automatically
- Sidecar injection automatic for labeled namespaces
- LoadBalancer services are OCI resources (controlled by OCI networking)

## Performance Expectations

| Operation | Duration |
|-----------|----------|
| Full setup (both clusters) | 5-10 minutes |
| Single cluster setup | 2-5 minutes |
| Enable/disable operations | 10-30 seconds |
| Status check | < 5 seconds |

## Color Codes

| Color | Meaning |
|-------|---------|
| Cyan | Timestamps and headings |
| Green | Ingress gateway info and IPs |
| Blue | East-west gateway info and IPs |
| Yellow | Menu options |
| Red | Error messages |

## Advanced Usage

### Using in Automation

```bash
# Direct function call without menu
source ./bash/multicluster-ingress-menu.sh
setup_cluster_ingress "$PRIMARY_CTX"
```

### Custom Pod Label for Readiness

Edit `deploy_app()` to match your pod labels:

```bash
# Default: app=productpage
# Change to: app=myapp

kctx "$ctx" wait --for=condition=ready pod -l app=myapp -n "$BOOKINFO_NS" --timeout=180s
```

### Integration with Make

```makefile
.PHONY: setup-infra
setup-infra:
	export PRIMARY_CTX=$(PRIMARY_CONTEXT); \
	export SECONDARY_CTX=$(SECONDARY_CONTEXT); \
	bash -c 'source ./bash/multicluster-ingress-menu.sh; setup_all_from_scratch'
```

## Related Documentation

- [Full Usage Guide](../docs/MULTICLUSTER_INGRESS_MENU_GUIDE.md)
- [DR Procedures](../docs/WEEK5_DR_DRILLS_AND_HANDOFF.md)
- [Production Checklist](../docs/PRODUCTION_READINESS_CHECKLIST.md)
- [Incident Playbooks](../docs/INCIDENT_RESPONSE_PLAYBOOKS.md)

## Quick Links

```bash
# Documentation
ls -la docs/

# Scripts
ls -la bash/

# Configuration files
ls -la istio-1.28.3/samples/

# Check script syntax
bash -n bash/multicluster-ingress-menu.sh
bash -n bash/dr-drill-menu.sh
```

## Contact & Support

For questions about:
- **Infrastructure setup**: See docs/WEEK1_COMPLETION_SUMMARY.md
- **Istio configuration**: See docs/WEEK2_COMPLETION_SUMMARY.md
- **Application deployment**: See docs/WEEK3_COMPLETION_SUMMARY.md
- **Observability**: See docs/WEEK4_ENHANCED_OBSERVABILITY.md
- **DR procedures**: See docs/WEEK5_DR_DRILLS_AND_HANDOFF.md
- **Production readiness**: See docs/PRODUCTION_READINESS_CHECKLIST.md
