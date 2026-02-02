# Incident Response Playbooks

**Purpose**: Step-by-step procedures to respond to common incidents in production

**Owner**: Operations Team  
**Last Updated**: February 2, 2026  
**Review Frequency**: Quarterly

---

## Table of Contents

1. [High Error Rate Incident](#high-error-rate-incident)
2. [High Latency Incident](#high-latency-incident)
3. [Circuit Breaker Triggered](#circuit-breaker-triggered)
4. [Pod Crash Loop](#pod-crash-loop)
5. [Ingress Gateway Unavailable](#ingress-gateway-unavailable)
6. [Cross-Cluster Connectivity Loss](#cross-cluster-connectivity-loss)
7. [Control Plane Degradation](#control-plane-degradation)
8. [Memory Leak Detection](#memory-leak-detection)
9. [DNS Resolution Failure](#dns-resolution-failure)
10. [Certificate Expiration](#certificate-expiration)

---

## High Error Rate Incident

**Alert**: `HighErrorRate` (>5% for 5 minutes)

**Priority**: Critical  
**Response Time**: Immediately  
**Severity**: Production Down

### Initial Response (0-2 minutes)

```bash
# 1. Acknowledge alert in AlertManager
# - Open http://localhost:9093
# - Click on alert → Silence (1 hour) to prevent alert spam

# 2. Check if issue is widespread
ERROR_RATE=$(curl -s http://localhost:9090/api/v1/query?query='(sum(rate(istio_requests_total{response_code=~"5.."}[5m])) / sum(rate(istio_requests_total[5m]))) * 100' | jq '.data.result[0].value[1]')
echo "Current error rate: $ERROR_RATE%"

# 3. Identify affected service
curl -s 'http://localhost:9090/api/v1/query?query=rate(istio_requests_total{response_code=~"5.."}[5m])' | \
  jq '.data.result[] | {service: .metric.destination_service, rate: .value[1]}' | \
  head -5
```

### Investigation (2-5 minutes)

```bash
# 1. Get pod status for affected service
# Example: if "reviews" service is failing
kubectl --context=primary-cluster-context get pods -n bookinfo -l app=reviews -o wide
# Check for:
# - Pods in Pending/Failed state
# - Pods with READY < 2/2
# - Restart count > 0 in last 5 minutes

# 2. Check logs for errors
FAILED_POD=$(kubectl --context=primary-cluster-context get pods -n bookinfo \
  -l app=reviews -o jsonpath='{.items[?(@.status.phase!="Running")].metadata.name}' | head -1)

if [ ! -z "$FAILED_POD" ]; then
  kubectl --context=primary-cluster-context logs -n bookinfo $FAILED_POD --tail=50
fi

# 3. Check pod events
kubectl --context=primary-cluster-context describe pod -n bookinfo $FAILED_POD | grep -A 20 "Events:"

# 4. Check memory/CPU usage
kubectl --context=primary-cluster-context top pods -n bookinfo

# 5. Check application logs (non-sidecar container)
RUNNING_POD=$(kubectl --context=primary-cluster-context get pods -n bookinfo \
  -l app=reviews --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')

kubectl --context=primary-cluster-context logs -n bookinfo $RUNNING_POD -c reviews --tail=100 | grep ERROR
```

### Determine Root Cause

**Possible Causes**:

1. **Service Dependency Down** → Check downstream service
2. **Resource Exhaustion** → Check node resources
3. **Memory Leak** → Check pod memory trend
4. **Configuration Error** → Check DestinationRule/VirtualService
5. **External Service Issue** → Check logs for external dependency errors

**Diagnostic Commands**:

```bash
# Check all services health
for svc in productpage reviews ratings details; do
  status=$(kubectl --context=primary-cluster-context exec -n bookinfo deploy/productpage-v1 -c istio-proxy -- \
    timeout 2 curl -s http://$svc:8080 | head -c 100)
  if [ -z "$status" ]; then
    echo "✗ $svc: FAILED"
  else
    echo "✓ $svc: RESPONDING"
  fi
done

# Check Envoy admin interface for details service
kubectl --context=primary-cluster-context exec -n bookinfo deploy/details-v1 -c istio-proxy -- \
  curl -s localhost:15000/stats | grep upstream_cx | head -10
```

### Remediation (5-15 minutes)

**If Service Down**:
```bash
# Restart the failing service
kubectl --context=primary-cluster-context rollout restart deployment/reviews -n bookinfo

# Monitor rollout
kubectl --context=primary-cluster-context rollout status deployment/reviews -n bookinfo --timeout=5m

# Wait 2 minutes, check error rate
sleep 120
ERROR_RATE=$(curl -s 'http://localhost:9090/api/v1/query?query=rate(istio_requests_total{response_code=~"5.."}[1m])' | jq '.data.result[0].value[1] // 0')
echo "Error rate after restart: $ERROR_RATE"
```

**If Resource Exhaustion**:
```bash
# Increase replica count
kubectl --context=primary-cluster-context scale deployment reviews-v1 -n bookinfo --replicas=3

# If still failing, check if nodes have resources
kubectl --context=primary-cluster-context top nodes
# If <10% free memory or CPU, add nodes or reduce workload

# Check for memory leaks - request pod resource limits increase
# or investigate application code
```

**If Dependency Chain Broken**:
```bash
# Test each hop in the call chain
# productpage → reviews → ratings

# Check productpage can reach reviews
kubectl --context=primary-cluster-context exec -n bookinfo deploy/productpage-v1 -c productpage -- \
  curl -v http://reviews:9080/reviews/1 2>&1 | grep -E "Connected|Connection|response"

# Check reviews can reach ratings
kubectl --context=primary-cluster-context exec -n bookinfo deploy/reviews-v1 -c reviews -- \
  curl -v http://ratings:9080/ratings/1 2>&1 | grep -E "Connected|Connection|response"

# If connection fails, check DestinationRule/VirtualService
kubectl --context=primary-cluster-context get destinationrule -n bookinfo
kubectl --context=primary-cluster-context get virtualservice -n bookinfo
```

### Validation (15-20 minutes)

```bash
# 1. Verify error rate returned to normal (<1%)
curl -s 'http://localhost:9090/api/v1/query?query=(sum(rate(istio_requests_total{response_code=~"5.."}[5m])) / sum(rate(istio_requests_total[5m]))) * 100' | jq '.data.result[0].value[1]'

# 2. Check all pods are Ready
kubectl --context=primary-cluster-context get pods -n bookinfo | grep -E "READY|reviews"

# 3. Test application end-to-end
for i in {1..10}; do
  curl -s http://163.192.53.128/productpage -o /dev/null -w "Status: %{http_code}\n"
done

# 4. Verify cross-cluster traffic (if applicable)
kubectl --context=primary-cluster-context exec -n bookinfo deploy/productpage-v1 -c istio-proxy -- \
  curl -s localhost:15000/clusters | grep "reviews.*::10\." | grep "10.1" | head -3
```

### Post-Incident (20+ minutes)

```bash
# 1. Remove alert silence (if configured)
# Go to AlertManager UI and end the silence

# 2. Document incident
# Update INCIDENT_LOG with:
# - Time detected
# - Root cause
# - Duration (time to detection + time to resolution)
# - Resolution steps
# - Follow-up actions (if needed)

# 3. Schedule follow-up review if needed
# If cause was preventable, create ticket for code/config fix
```

**Success Criteria**: ✅ Error rate <1%, all pods Running, application responsive

---

## High Latency Incident

**Alert**: `HighLatency` (P99 >1000ms for 5 minutes)

**Priority**: High  
**Response Time**: 5 minutes  
**Severity**: Degraded Performance

### Initial Response

```bash
# 1. Acknowledge alert
# AlertManager UI → Silence alert for 1 hour

# 2. Confirm latency issue
P99_LATENCY=$(curl -s 'http://localhost:9090/api/v1/query?query=histogram_quantile(0.99,rate(istio_request_duration_milliseconds_bucket[5m]))' | jq '.data.result[0].value[1]')
echo "Current P99 latency: ${P99_LATENCY}ms"

# 3. Check which service is slow
curl -s 'http://localhost:9090/api/v1/query?query=histogram_quantile(0.99,rate(istio_request_duration_milliseconds_bucket[5m])) by (destination_service)' | \
  jq '.data.result[] | {service: .metric.destination_service, p99_ms: .value[1]}'
```

### Investigation

```bash
# 1. Check pod CPU/memory
kubectl --context=primary-cluster-context top pods -n bookinfo

# 2. Check node resources
kubectl --context=primary-cluster-context top nodes

# 3. Check if network is congested
kubectl --context=primary-cluster-context exec -n bookinfo \
  $(kubectl --context=primary-cluster-context get pods -n bookinfo -l app=reviews \
  -o jsonpath='{.items[0].metadata.name}') -c istio-proxy -- \
  curl -s localhost:15000/stats | grep "upstream_rq" | tail -5

# 4. Check if dependent service is slow
# Test details service latency directly
time kubectl --context=primary-cluster-context exec -n bookinfo deploy/productpage-v1 -c istio-proxy -- \
  curl -s http://details:9080/details/1 > /dev/null

# 5. Check Envoy logs for upstream_rq_time
kubectl --context=primary-cluster-context logs -n bookinfo \
  -l app=productpage -c istio-proxy --tail=100 | grep "upstream_rq_time"
```

### Remediation

**If Pod/Service Slow**:
```bash
# Increase replicas to distribute load
kubectl --context=primary-cluster-context scale deployment details-v1 -n bookinfo --replicas=3

# Monitor latency
sleep 60
P99_LATENCY=$(curl -s 'http://localhost:9090/api/v1/query?query=histogram_quantile(0.99,rate(istio_request_duration_milliseconds_bucket{destination_service="details.bookinfo.svc.cluster.local"}[5m]))' | jq '.data.result[0].value[1]')
echo "P99 after scaling: ${P99_LATENCY}ms"
```

**If Resource Exhaustion**:
```bash
# Check available resources
kubectl --context=primary-cluster-context describe node $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') | \
  grep -A 5 "Allocated resources"

# If low memory, restart non-critical pods
# or trigger horizontal pod autoscaler
```

**If Cross-Cluster Call Slow**:
```bash
# Measure latency to secondary cluster
kubectl --context=primary-cluster-context exec -n bookinfo deploy/reviews-v1 -c reviews -- \
  time timeout 5 curl -s http://ratings:9080/ratings/1 > /dev/null

# Check if RPC/DRG has high latency
kubectl run test-ping --image=nicolaka/netshoot -it --rm -- \
  ping -c 5 10.1.1.50 2>/dev/null | grep "avg"
```

### Validation

```bash
# 1. Check P99 latency
P99_LATENCY=$(curl -s 'http://localhost:9090/api/v1/query?query=histogram_quantile(0.99,rate(istio_request_duration_milliseconds_bucket[5m]))' | jq '.data.result[0].value[1]')
if [ $(echo "$P99_LATENCY < 800" | bc) -eq 1 ]; then
  echo "✓ Latency NORMALIZED: ${P99_LATENCY}ms"
else
  echo "✗ Latency still high: ${P99_LATENCY}ms"
fi

# 2. Check error rate didn't increase
ERROR_RATE=$(curl -s 'http://localhost:9090/api/v1/query?query=rate(istio_requests_total{response_code=~"5.."}[5m])' | jq '.data.result[0].value[1] // 0')
echo "Error rate: ${ERROR_RATE}"

# 3. Perform end-to-end test
for i in {1..5}; do
  time curl -s http://163.192.53.128/productpage > /dev/null
done
```

**Success Criteria**: ✅ P99 latency <800ms, error rate unchanged, user experience improved

---

## Circuit Breaker Triggered

**Alert**: `CircuitBreakerTriggered` (UO flags present for 2 minutes)

**Priority**: High  
**Response Time**: 5 minutes

### Initial Response

```bash
# 1. Check which service has circuit breaker active
curl -s 'http://localhost:9090/api/v1/query?query=rate(istio_requests_total{response_flags=~".*UO.*"}[5m])' | \
  jq '.data.result[] | {service: .metric.destination_service, rate: .value[1]}'

# 2. Check if it's expected (e.g., during deployment)
kubectl --context=primary-cluster-context get pods -n bookinfo -l app=details
```

### Investigation

```bash
# 1. Check health of downstream service
# Example: If circuit breaker on details service
kubectl --context=primary-cluster-context get pods -n bookinfo -l app=details

# 2. Check if pods are available
AVAILABLE=$(kubectl --context=primary-cluster-context get deployment details-v1 \
  -n bookinfo -o jsonpath='{.status.availableReplicas}')
DESIRED=$(kubectl --context=primary-cluster-context get deployment details-v1 \
  -n bookinfo -o jsonpath='{.spec.replicas}')
echo "Available replicas: $AVAILABLE / $DESIRED"

# 3. Check if service is responding
kubectl --context=primary-cluster-context exec -n bookinfo deploy/productpage-v1 -c istio-proxy -- \
  timeout 3 curl -s http://details:9080/details/1 | head -c 100

# 4. Check DestinationRule connection pool settings
kubectl --context=primary-cluster-context get destinationrule details -n bookinfo -o yaml | \
  grep -A 10 "connectionPool"
```

### Remediation

**If Service Unhealthy**:
```bash
# Restart the service
kubectl --context=primary-cluster-context rollout restart deployment/details-v1 -n bookinfo

# Increase connection pool limit (if configured too low)
# Edit DestinationRule and increase max connections
kubectl --context=primary-cluster-context get destinationrule details -n bookinfo -o yaml
# Check: trafficPolicy.connectionPool.tcp.maxConnections
```

**If Spike in Requests**:
```bash
# Increase replica count
kubectl --context=primary-cluster-context scale deployment details-v1 -n bookinfo --replicas=5

# Monitor circuit breaker recovery
sleep 30
CB_RATE=$(curl -s 'http://localhost:9090/api/v1/query?query=rate(istio_requests_total{destination_service="details.bookinfo.svc.cluster.local",response_flags=~".*UO.*"}[5m])' | jq '.data.result[0].value[1] // 0')
echo "Circuit breaker trigger rate: $CB_RATE"
```

### Validation

```bash
# 1. Check circuit breaker is no longer triggering
CB_RATE=$(curl -s 'http://localhost:9090/api/v1/query?query=rate(istio_requests_total{response_flags=~".*UO.*"}[5m])' | jq '.data.result[0].value[1] // 0')
if [ $(echo "$CB_RATE < 0.1" | bc) -eq 1 ]; then
  echo "✓ Circuit breaker RECOVERED: Rate < 0.1 req/s"
fi

# 2. Verify service is healthy
kubectl --context=primary-cluster-context get pods -n bookinfo -l app=details

# 3. Check error rates
curl -s 'http://localhost:9090/api/v1/query?query=rate(istio_requests_total{destination_service="details.bookinfo.svc.cluster.local",response_code=~"5.."}[5m])' | jq '.data.result[0].value[1] // 0'
```

**Success Criteria**: ✅ No UO flags in response, service responding, error rate <1%

---

## Pod Crash Loop

**Alert**: Pod repeatedly restarting (RESTART count increasing)

**Priority**: High  
**Response Time**: 5 minutes

### Initial Response

```bash
# 1. Identify crashing pod
CRASHING_POD=$(kubectl --context=primary-cluster-context get pods -n bookinfo \
  -o jsonpath='{range .items[?(@.status.containerStatuses[0].restartCount>3)]}{.metadata.name},{.status.containerStatuses[0].restartCount},\n{end}')

echo "Crashing pods:"
echo "$CRASHING_POD"

# 2. Get pod details
POD_NAME=$(echo "$CRASHING_POD" | head -1 | cut -d',' -f1)
kubectl --context=primary-cluster-context describe pod -n bookinfo $POD_NAME | tail -20
```

### Investigation

```bash
# 1. Check current pod logs (from last restart)
kubectl --context=primary-cluster-context logs -n bookinfo $POD_NAME --tail=50
# or if pod exited:
kubectl --context=primary-cluster-context logs -n bookinfo $POD_NAME --previous --tail=50

# 2. Check init container logs
kubectl --context=primary-cluster-context logs -n bookinfo $POD_NAME -c istio-init --tail=50

# 3. Check pod events
kubectl --context=primary-cluster-context describe pod -n bookinfo $POD_NAME | grep -A 20 "Events:"

# 4. Check available disk space
kubectl --context=primary-cluster-context exec -n bookinfo $POD_NAME -c $(POD_APP_CONTAINER) -- df -h

# 5. Check if it's a sidecar issue
# Check if istio-proxy container is crashing
kubectl --context=primary-cluster-context logs -n bookinfo $POD_NAME -c istio-proxy --tail=50
```

### Remediation

**Application Crash** (non-sidecar):
```bash
# Check if configuration changed
kubectl --context=primary-cluster-context get configmap -n bookinfo

# Restart pod to get fresh logs
kubectl --context=primary-cluster-context delete pod -n bookinfo $POD_NAME

# Monitor if new pod crashes
sleep 10
RESTART_COUNT=$(kubectl --context=primary-cluster-context get pod -n bookinfo $POD_NAME \
  -o jsonpath='{.status.containerStatuses[0].restartCount}')
echo "Restart count: $RESTART_COUNT"

# If keeps crashing, investigate application logs
```

**Sidecar (Envoy) Crash**:
```bash
# Check sidecar memory usage
kubectl --context=primary-cluster-context top pod -n bookinfo $POD_NAME

# Increase sidecar memory limits
# Edit pod spec (or deployment) to increase sidecar resources:
# resources:
#   limits:
#     memory: 1Gi
#     cpu: 1000m
```

**Disk Space Issue**:
```bash
# Check node disk space
kubectl --context=primary-cluster-context describe node $(kubectl --context=primary-cluster-context get pod -n bookinfo $POD_NAME -o jsonpath='{.spec.nodeName}') | grep -A 5 "Allocatable"

# If disk full, clean up:
# - Delete completed jobs
# - Clean old logs
# - Add new node if persistent
```

### Validation

```bash
# 1. Check pod is stable
sleep 120
RESTART_COUNT=$(kubectl --context=primary-cluster-context get pod -n bookinfo $POD_NAME \
  -o jsonpath='{.status.containerStatuses[0].restartCount}')
STATUS=$(kubectl --context=primary-cluster-context get pod -n bookinfo $POD_NAME \
  -o jsonpath='{.status.phase}')
echo "Pod status: $STATUS, Restart count: $RESTART_COUNT (should not increase)"

# 2. Check service is responding
kubectl --context=primary-cluster-context exec -n bookinfo deploy/productpage-v1 -c istio-proxy -- \
  timeout 3 curl -s http://details:9080/details/1 | head -c 100
```

**Success Criteria**: ✅ Pod running (no new restarts), ready 2/2, service responding

---

## Ingress Gateway Unavailable

**Alert**: `IngressGatewayDown` (Gateway unavailable for 1 minute)

**Priority**: Critical  
**Response Time**: Immediately

### Initial Response

```bash
# 1. Check ingress gateway pods
kubectl --context=primary-cluster-context get pods -n istio-system -l app=istio-ingressgateway

# 2. Check if LoadBalancer service exists and has IP
kubectl --context=primary-cluster-context get svc -n istio-system istio-ingressgateway

# 3. Test application access
curl -v http://163.192.53.128/productpage 2>&1 | grep -E "Connected|Connection refused|response"
```

### Remediation

**Pod Not Running**:
```bash
# Check pod status
kubectl --context=primary-cluster-context describe pod -n istio-system \
  -l app=istio-ingressgateway

# Delete pod to trigger recreation
kubectl --context=primary-cluster-context delete pod -n istio-system \
  -l app=istio-ingressgateway

# Wait for new pod
sleep 30
kubectl --context=primary-cluster-context wait --for=condition=ready pod \
  -l app=istio-ingressgateway -n istio-system --timeout=120s
```

**Service Issue**:
```bash
# Check service endpoints
kubectl --context=primary-cluster-context get endpoints -n istio-system istio-ingressgateway

# If no endpoints, restart gateway pods
kubectl --context=primary-cluster-context rollout restart deployment istio-ingressgateway -n istio-system
```

### Validation

```bash
# 1. Check pod is ready
kubectl --context=primary-cluster-context get pods -n istio-system -l app=istio-ingressgateway

# 2. Check service has external IP
kubectl --context=primary-cluster-context get svc -n istio-system istio-ingressgateway

# 3. Test application access
curl -s http://163.192.53.128/productpage | grep "<title>"
# Expected: <title>Simple Bookstore App</title>
```

**Success Criteria**: ✅ Gateway pod running, external IP assigned, application accessible

---

## Cross-Cluster Connectivity Loss

**Alert**: `CrossClusterConnectivityIssue` (No cross-cluster traffic for 5 minutes)

**Priority**: High  
**Response Time**: 10 minutes

### Initial Response

```bash
# 1. Verify RPC status in primary cluster
kubectl --context=primary-cluster-context get pods -n istio-system -l app=istio-eastwestgateway

# 2. Verify RPC status in secondary cluster
kubectl --context=secondary-cluster get pods -n istio-system -l app=istio-eastwestgateway

# 3. Check if secondary endpoints visible
kubectl --context=primary-cluster-context exec -n bookinfo deploy/productpage-v1 -c istio-proxy -- \
  curl -s localhost:15000/clusters | grep "reviews.*::10.1" | head -3
```

### Investigation

```bash
# 1. Check east-west gateway service IPs
kubectl --context=primary-cluster-context get svc -n istio-system -l istio=eastwestgateway
kubectl --context=secondary-cluster get svc -n istio-system -l istio=eastwestgateway

# 2. Test connectivity from primary to secondary east-west gateway
SECONDARY_EW_IP=$(kubectl --context=secondary-cluster get svc -n istio-system \
  -l istio=eastwestgateway -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')

kubectl --context=primary-cluster-context run test-pod --image=nicolaka/netshoot -it --rm -- \
  timeout 5 curl -s -k https://$SECONDARY_EW_IP:15443 2>&1 | head -5

# 3. Check istiod can reach secondary istiod
SECONDARY_ISTIOD_IP=$(kubectl --context=secondary-cluster get svc -n istio-system istiod \
  -o jsonpath='{.spec.clusterIP}')

kubectl --context=primary-cluster-context run test-pod --image=nicolaka/netshoot -it --rm -- \
  timeout 5 curl -v https://$SECONDARY_ISTIOD_IP:15010 2>&1 | grep -E "Connected|Connection"

# 4. Check network latency
kubectl run test-ping --image=nicolaka/netshoot -it --rm -- \
  ping -c 5 10.1.1.50 2>/dev/null | grep "avg"
```

### Remediation

**If East-West Gateway Down**:
```bash
# Restart in secondary cluster
kubectl --context=secondary-cluster rollout restart deployment istio-eastwestgateway -n istio-system

# Wait for pod
sleep 30
kubectl --context=secondary-cluster wait --for=condition=ready pod \
  -l istio=eastwestgateway -n istio-system --timeout=120s

# Check primary cluster sees endpoint
sleep 10
kubectl --context=primary-cluster-context exec -n bookinfo deploy/productpage-v1 -c istio-proxy -- \
  curl -s localhost:15000/clusters | grep "reviews.*::10.1" | wc -l
```

**If Network/RPC Down**:
```bash
# Check DRG route tables
# This typically requires OCI CLI or console

# Test if pod-to-pod communication works
PRIMARY_POD_IP=$(kubectl --context=primary-cluster-context get pod -n bookinfo \
  -l app=productpage -o jsonpath='{.items[0].status.podIP}')

kubectl --context=secondary-cluster run test-pod --image=nicolaka/netshoot -it --rm -- \
  timeout 5 ping -c 3 $PRIMARY_POD_IP

# If this fails, RPC/DRG issue - escalate to network team
```

### Validation

```bash
# 1. Verify cross-cluster endpoints visible
kubectl --context=primary-cluster-context exec -n bookinfo deploy/productpage-v1 -c istio-proxy -- \
  curl -s localhost:15000/clusters | grep "reviews.*::10.1" | head -5

# 2. Generate traffic and check distribution
for i in {1..20}; do
  curl -s http://163.192.53.128/productpage > /dev/null
done

# 3. Check metrics show cross-cluster traffic
curl -s 'http://localhost:9090/api/v1/query?query=istio_requests_total{source_cluster="primary-cluster",destination_cluster="secondary-cluster"}' | jq '.data.result | length'
# Should be > 0
```

**Success Criteria**: ✅ Cross-cluster endpoints visible, cross-cluster traffic flowing, metrics show data

---

## Control Plane Degradation

**Alert**: `IstiodDown` (Control plane unavailable for 2 minutes) or no new sidecars injecting

**Priority**: Critical  
**Response Time**: Immediately

### Initial Response

```bash
# 1. Check istiod status
kubectl --context=primary-cluster-context get pods -n istio-system -l app=istiod

# 2. Check istiod logs for errors
kubectl --context=primary-cluster-context logs -n istio-system -l app=istiod --tail=50

# 3. Try to check istiod health
kubectl --context=primary-cluster-context get pods -n istio-system -l app=istiod -o jsonpath='{.items[0].metadata.name}' | \
  xargs -I {} kubectl --context=primary-cluster-context exec -n istio-system {} -- \
  curl -s http://localhost:8080/debug/pprof/
```

### Investigation

```bash
# 1. Check if webhook is operational
kubectl --context=primary-cluster-context get validatingwebhookconfigurations | grep istio

# 2. Check istiod readiness probe
kubectl --context=primary-cluster-context get pod -n istio-system -l app=istiod \
  -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")]}'

# 3. Check if there are pending mutating webhooks
kubectl --context=primary-cluster-context get mutatingwebhookconfigurations | grep -i istio

# 4. Check certificate expiry
kubectl --context=primary-cluster-context get secret -n istio-system -l istio=ca-root-cert \
  -o jsonpath='{.items[0].data.cert}' | base64 -d | openssl x509 -noout -enddate

# 5. Check pod resource usage
kubectl --context=primary-cluster-context top pod -n istio-system -l app=istiod
```

### Remediation

**If Pod Unhealthy**:
```bash
# Restart istiod
kubectl --context=primary-cluster-context rollout restart deployment istiod -n istio-system

# Wait for readiness
kubectl --context=primary-cluster-context rollout status deployment istiod -n istio-system --timeout=5m

# Monitor if new pods are getting sidecars injected
kubectl --context=primary-cluster-context apply -f test-sidecar.yaml
```

**If Certificate Expired**:
```bash
# This requires regenerating certificates (see docs)
# Temporary: reduce certificate check (NOT RECOMMENDED FOR PRODUCTION)

# Better: regenerate certs and restart istiod
```

### Validation

```bash
# 1. Check istiod is ready
kubectl --context=primary-cluster-context get pods -n istio-system -l app=istiod

# 2. Deploy a test pod and verify sidecar injection
kubectl --context=primary-cluster-context run test-injection --image=nginx -n bookinfo

# 3. Check if sidecar was injected
sleep 5
kubectl --context=primary-cluster-context get pod -n bookinfo test-injection -o wide
# Should show READY: 2/2

# 4. Verify existing services still working
curl -s http://163.192.53.128/productpage | grep "<title>"
```

**Success Criteria**: ✅ istiod pod running, new pods getting sidecars, existing traffic unaffected

---

## Memory Leak Detection

**Symptom**: Pod memory usage continuously increasing, eventual OOMKilled

**Priority**: High  
**Response Time**: 30 minutes

### Initial Response

```bash
# 1. Identify pod with memory leak
kubectl --context=primary-cluster-context get pods -n bookinfo -o custom-columns=NAME:.metadata.name,MEMORY:.spec.containers[0].resources.limits.memory

# 2. Monitor memory over time
for i in {1..10}; do
  echo "$(date): $(kubectl top pod -n bookinfo PODNAME | tail -1)"
  sleep 60
done

# 3. Check if memory is continuously increasing
kubectl --context=primary-cluster-context exec -n bookinfo PODNAME -c CONTAINER -- free -m
```

### Investigation

```bash
# 1. Check pod logs for memory-related warnings
kubectl --context=primary-cluster-context logs -n bookinfo PODNAME -c CONTAINER | grep -i "memory\|leak\|oom"

# 2. Check for sidecar memory leak
kubectl --context=primary-cluster-context logs -n bookinfo PODNAME -c istio-proxy | tail -50

# 3. Check Envoy stats for connection accumulation (sign of leak)
kubectl --context=primary-cluster-context exec -n bookinfo PODNAME -c istio-proxy -- \
  curl -s localhost:15000/stats | grep "upstream_cx" | tail -20

# 4. Check if heap is growing
kubectl --context=primary-cluster-context exec -n bookinfo PODNAME -c CONTAINER -- \
  jmap -histo <PID> | head -30 2>/dev/null || echo "Not a Java app"
```

### Remediation

**Sidecar Memory Leak**:
```bash
# Increase sidecar memory limits temporarily
kubectl --context=primary-cluster-context patch pod PODNAME -n bookinfo --type json \
  -p='[{"op":"replace","path":"/spec/containers/1/resources/limits/memory","value":"1Gi"}]'

# Upgrade Istio (if available)
# or restart pods periodically (not ideal)

# Schedule pod restart during maintenance window
kubectl --context=primary-cluster-context annotate pod PODNAME -n bookinfo \
  restart-policy=daily-02-00
```

**Application Memory Leak**:
```bash
# If leak in application container, likely needs code fix
# Temporary mitigation:
# 1. Increase pod memory limit
# 2. Reduce replica count (or move to faster machine)
# 3. Schedule pod restart periodically

# Get heap dump
kubectl --context=primary-cluster-context exec -n bookinfo PODNAME -c CONTAINER -- \
  jmap -dump:live,format=b,file=/tmp/heap.bin <PID>

# Download and analyze (for Java apps)
kubectl --context=primary-cluster-context cp bookinfo/PODNAME:/tmp/heap.bin ./heap.bin -c CONTAINER
# Analyze with Eclipse MAT or jhat
```

### Validation

```bash
# 1. Monitor memory trend after fix
for i in {1..5}; do
  MEMORY=$(kubectl --context=primary-cluster-context top pod -n bookinfo PODNAME --no-headers | awk '{print $2}')
  echo "$(date): $MEMORY"
  sleep 300  # Check every 5 minutes
done

# 2. Verify pod not OOMKilled
kubectl --context=primary-cluster-context get pod -n bookinfo PODNAME
# Check Status is "Running", not "OOMKilled"

# 3. Check application still responsive
curl -s http://163.192.53.128/productpage | grep "<title>"
```

**Success Criteria**: ✅ Memory usage stable, no OOMKilled events, application responsive

---

## DNS Resolution Failure

**Symptom**: Services can't reach each other, "name resolution failed"

**Priority**: High  
**Response Time**: 5 minutes

### Initial Response

```bash
# 1. Test DNS from pod
kubectl --context=primary-cluster-context exec -n bookinfo deploy/productpage-v1 -c productpage -- \
  nslookup details.bookinfo.svc.cluster.local

# 2. Test DNS to other cluster service
kubectl --context=primary-cluster-context exec -n bookinfo deploy/productpage-v1 -c productpage -- \
  nslookup reviews.bookinfo.svc.cluster.local

# 3. Check CoreDNS pods
kubectl --context=primary-cluster-context get pods -n kube-system -l k8s-app=kube-dns
```

### Investigation

```bash
# 1. Check if CoreDNS is responding
kubectl --context=primary-cluster-context run dns-test --image=nicolaka/netshoot -it --rm -- \
  dig reviews.bookinfo.svc.cluster.local @10.96.0.10

# 2. Check CoreDNS logs
kubectl --context=primary-cluster-context logs -n kube-system -l k8s-app=kube-dns --tail=50

# 3. Check if DNS endpoints exist
kubectl --context=primary-cluster-context get endpoints -n kube-system kube-dns

# 4. Check if services have clusterIPs
kubectl --context=primary-cluster-context get svc -n bookinfo reviews
# Should show CLUSTER-IP assigned
```

### Remediation

**If CoreDNS Down**:
```bash
# Restart CoreDNS
kubectl --context=primary-cluster-context rollout restart deployment coredns -n kube-system

# Wait for readiness
sleep 30
kubectl --context=primary-cluster-context wait --for=condition=ready pod \
  -l k8s-app=kube-dns -n kube-system --timeout=120s
```

**If Service Endpoint Missing**:
```bash
# Check if service selector matches pods
kubectl --context=primary-cluster-context get svc reviews -n bookinfo -o yaml | grep selector -A 5

# Check if pods have matching labels
kubectl --context=primary-cluster-context get pods -n bookinfo -l app=reviews --show-labels

# If labels mismatch, fix labels or service selector
```

### Validation

```bash
# 1. Test DNS resolution
kubectl --context=primary-cluster-context exec -n bookinfo deploy/productpage-v1 -c productpage -- \
  nslookup reviews.bookinfo.svc.cluster.local
# Should return IP address

# 2. Test service access
kubectl --context=primary-cluster-context exec -n bookinfo deploy/productpage-v1 -c istio-proxy -- \
  timeout 3 curl -s http://reviews:9080/reviews/1 | head -c 100

# 3. Test cross-cluster DNS
kubectl --context=primary-cluster-context exec -n bookinfo deploy/productpage-v1 -c productpage -- \
  nslookup ratings.bookinfo.svc.cluster.local
```

**Success Criteria**: ✅ DNS returns IPs, services accessible by name, cross-cluster resolution working

---

## Certificate Expiration

**Alert**: Certificate expiring (typically from monitoring certificate manager)

**Priority**: Medium  
**Response Time**: 24 hours before expiration

### Initial Response

```bash
# 1. Check certificate expiration
kubectl --context=primary-cluster-context get secret -n istio-system cacerts -o yaml | \
  grep -A 1 "ca.crt:" | tail -1 | base64 -d | openssl x509 -noout -enddate

# 2. Check if cert is self-signed (expected for this setup)
kubectl --context=primary-cluster-context get secret -n istio-system cacerts -o yaml | \
  grep -A 1 "ca.crt:" | tail -1 | base64 -d | openssl x509 -noout -issuer
```

### Remediation

**Before Expiration (24+ hours)**:
```bash
# 1. Generate new certificates
cd istio-1.28.3
make -f tools/certs/Makefile.selfsigned.mk root-ca
make -f tools/certs/Makefile.selfsigned.mk primary-cluster-cacerts
make -f tools/certs/Makefile.selfsigned.mk secondary-cluster-cacerts

# 2. Update secrets in primary cluster
kubectl --context=primary-cluster-context delete secret cacerts -n istio-system
kubectl --context=primary-cluster-context create secret generic cacerts \
  -n istio-system \
  --from-file=primary-cluster/ca-cert.pem \
  --from-file=primary-cluster/ca-key.pem \
  --from-file=primary-cluster/root-cert.pem \
  --from-file=primary-cluster/cert-chain.pem

# 3. Restart istiod
kubectl --context=primary-cluster-context rollout restart deployment istiod -n istio-system

# 4. Repeat for secondary cluster
kubectl --context=secondary-cluster delete secret cacerts -n istio-system
kubectl --context=secondary-cluster create secret generic cacerts \
  -n istio-system \
  --from-file=secondary-cluster/ca-cert.pem \
  --from-file=secondary-cluster/ca-key.pem \
  --from-file=secondary-cluster/root-cert.pem \
  --from-file=secondary-cluster/cert-chain.pem

kubectl --context=secondary-cluster rollout restart deployment istiod -n istio-system
```

### Validation

```bash
# 1. Verify new certificate
kubectl --context=primary-cluster-context get secret -n istio-system cacerts -o yaml | \
  grep -A 1 "ca.crt:" | tail -1 | base64 -d | openssl x509 -noout -enddate

# 2. Check istiod is running
kubectl --context=primary-cluster-context get pods -n istio-system -l app=istiod

# 3. Verify mTLS still working
curl -s http://163.192.53.128/productpage | grep "<title>"

# 4. Check cross-cluster communication
kubectl --context=primary-cluster-context exec -n bookinfo deploy/productpage-v1 -c istio-proxy -- \
  curl -s localhost:15000/clusters | grep "reviews.*::10.1" | wc -l
```

**Success Criteria**: ✅ New certificate deployed, applications running, cross-cluster working

---

## Escalation Paths

### If Incident Cannot Be Resolved in 15 Minutes

1. **First Escalation** (5-15 min window):
   - Page on-call Platform Lead
   - Start incident bridge call
   - Document all actions taken

2. **Second Escalation** (15-30 min window):
   - Escalate to Engineering Lead
   - Notify affected stakeholders
   - Prepare rollback plan

3. **Third Escalation** (30+ min window):
   - Escalate to VP Engineering
   - Contact external vendor support if needed
   - Prepare public status update

---

## Incident Log Template

```
Date/Time: [When]
Alert: [Alert name]
Detected: [Detection method]
Duration: [Start to End time]
Root Cause: [What caused it]
Resolution: [What fixed it]
Impact: [Users/services affected]
Follow-up: [Any preventive measures]
Post-Mortem: [Schedule within 48 hours]
```

---

**Document Version**: 1.0  
**Last Updated**: February 2, 2026  
**Next Review**: May 2, 2026 (Quarterly)  
**Status**: ✅ PRODUCTION READY
