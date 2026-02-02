# Week 2: Istio Multi-Cluster Installation - Completion Summary

**Completion Date**: 2026-02-02  
**Status**: ✅ **COMPLETE**  
**Istio Version**: 1.28.3

---

## Executive Summary

Week 2 Istio multi-cluster service mesh installation is complete with full cross-cluster service discovery and load balancing validated. Both clusters are now running Istio 1.28.3 with shared root CA, east-west gateways for cross-cluster communication, and remote secrets exchanged for service discovery.

**Key Achievement**: Successfully demonstrated cross-cluster load balancing with traffic distributed between services running in us-sanjose-1 and us-chicago-1 regions through Istio's service mesh.

---

## Infrastructure Components

### Istio Installation

**Version**: 1.28.3 (latest stable as of 2026-02-02)  
**Mesh ID**: `oke-mesh`  
**Profile**: `default`

**Primary Cluster (us-sanjose-1):**
- **Cluster Name**: `primary-cluster`
- **Network**: `primary-network`
- **Istiod**: Running (1 pod)
- **Ingress Gateway**: Running with external IP `163.192.53.128`
- **East-West Gateway**: Running with external IP `150.230.37.157`

**Secondary Cluster (us-chicago-1):**
- **Cluster Name**: `secondary-cluster`
- **Network**: `secondary-network`
- **Istiod**: Running (1 pod)
- **Ingress Gateway**: Running with external IP `207.211.166.34`
- **East-West Gateway**: Running with external IP `170.9.229.9`

> **Note**: Ingress and east-west gateway IPs can change if services are removed/recreated. Use the commands below to fetch current values:

```bash
PRIMARY_INGRESS_IP=$(kubectl --context=primary-cluster-context get svc -n istio-system istio-ingressgateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
SECONDARY_INGRESS_IP=$(kubectl --context=secondary-cluster get svc -n istio-system istio-ingressgateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
PRIMARY_EASTWEST_IP=$(kubectl --context=primary-cluster-context get svc -n istio-system istio-eastwestgateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
SECONDARY_EASTWEST_IP=$(kubectl --context=secondary-cluster get svc -n istio-system istio-eastwestgateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "Primary ingress: $PRIMARY_INGRESS_IP"
echo "Secondary ingress: $SECONDARY_INGRESS_IP"
echo "Primary east-west: $PRIMARY_EASTWEST_IP"
echo "Secondary east-west: $SECONDARY_EASTWEST_IP"
```

### Certificate Authority (CA) Configuration

**Shared Trust Domain**: `oke.local`

**CA Certificates Generated**:
- Root CA (shared between clusters)
- Primary cluster intermediate CA
- Secondary cluster intermediate CA

**Location**: `/home/opc/BICE/oke-multicluster-ingress/istio-1.28.3/`
  - `primary-cluster/` - CA certs for primary
  - `secondary-cluster/` - CA certs for secondary

### LoadBalancer Configuration

**Critical Fix Applied**: Added OCI-specific subnet annotations to all LoadBalancer services

**Primary Cluster LoadBalancers**:
- **Subnet**: `oke-svclbsubnet-quick-dalquint-oke-cluster-eb757eec8-regional`
- **Subnet OCID**: `ocid1.subnet.oc1.us-sanjose-1.aaaaaaaaydads5e35xkxhkiajee77j5qlqtpzd77czjwonncahblx6pvrdza`
- **CIDR**: 10.0.20.0/24

**Secondary Cluster LoadBalancers**:
- **Subnet**: `public subnet-dalquint-vcn`
- **Subnet OCID**: `ocid1.subnet.oc1.us-chicago-1.aaaaaaaawz55bexqtooqsjc6zsdcscdeccpwbubg5367kjuzi3coasxgvz3q`
- **CIDR**: 10.1.0.0/24

**Annotation Used**: `service.beta.kubernetes.io/oci-load-balancer-subnet1=<SUBNET_OCID>`

---

## Installation Steps Executed

### 1. Istio CLI Installation ✅

```bash
# Downloaded Istio 1.28.3
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.28.3 sh -

# Added to PATH
export PATH="/home/opc/BICE/oke-multicluster-ingress/istio-1.28.3/bin:$PATH"

# Verified version
istioctl version
# Output: client version: 1.28.3
```

### 2. CA Certificate Generation ✅

Used Istio's built-in certificate generation tool (fixed initial certificate issues):

```bash
cd /home/opc/BICE/oke-multicluster-ingress/istio-1.28.3

# Generate root CA
make -f tools/certs/Makefile.selfsigned.mk root-ca

# Generate cluster-specific intermediate CAs
make -f tools/certs/Makefile.selfsigned.mk primary-cluster-cacerts
make -f tools/certs/Makefile.selfsigned.mk secondary-cluster-cacerts
```

**Issue Resolved**: Initial manual certificate generation lacked CA extensions, causing istiod crashes. Switched to Istio's Makefile-based generation.

### 3. CA Secrets Deployment ✅

```bash
# Primary cluster
kubectl --context=primary-cluster-context create namespace istio-system
kubectl --context=primary-cluster-context create secret generic cacerts \
  -n istio-system \
  --from-file=ca-cert.pem=primary-cluster/ca-cert.pem \
  --from-file=ca-key.pem=primary-cluster/ca-key.pem \
  --from-file=root-cert.pem=primary-cluster/root-cert.pem \
  --from-file=cert-chain.pem=primary-cluster/cert-chain.pem

# Secondary cluster
kubectl --context=secondary-cluster create namespace istio-system
kubectl --context=secondary-cluster create secret generic cacerts \
  -n istio-system \
  --from-file=ca-cert.pem=secondary-cluster/ca-cert.pem \
  --from-file=ca-key.pem=secondary-cluster/ca-key.pem \
  --from-file=root-cert.pem=secondary-cluster/root-cert.pem \
  --from-file=cert-chain.pem=secondary-cluster/cert-chain.pem
```

### 4. Istio Control Plane Installation ✅

```bash
# Primary cluster
istioctl install --context=primary-cluster-context -y \
  --set profile=default \
  --set values.global.meshID=oke-mesh \
  --set values.global.multiCluster.clusterName=primary-cluster \
  --set values.global.network=primary-network \
  --log_output_level=default:info

# Secondary cluster
istioctl install --context=secondary-cluster -y \
  --set profile=default \
  --set values.global.meshID=oke-mesh \
  --set values.global.multiCluster.clusterName=secondary-cluster \
  --set values.global.network=secondary-network \
  --log_output_level=default:info
```

**Note**: Added `--log_output_level=default:info` to provide visibility during installation instead of stagnant screen.

### 5. East-West Gateway Installation ✅

```bash
# Primary cluster
cd istio-1.28.3/samples/multicluster
./gen-eastwest-gateway.sh \
  --mesh oke-mesh \
  --cluster primary-cluster \
  --network primary-network | \
  istioctl --context=primary-cluster-context install -y -f -

# Secondary cluster
./gen-eastwest-gateway.sh \
  --mesh oke-mesh \
  --cluster secondary-cluster \
  --network secondary-network | \
  istioctl --context=secondary-cluster install -y -f -
```

### 6. LoadBalancer Subnet Annotation ✅

**Critical Fix**: OCI requires explicit subnet specification for LoadBalancers

```bash
# Primary cluster gateways
kubectl --context=primary-cluster-context annotate svc istio-eastwestgateway \
  -n istio-system \
  service.beta.kubernetes.io/oci-load-balancer-subnet1=ocid1.subnet.oc1.us-sanjose-1.aaaaaaaaydads5e35xkxhkiajee77j5qlqtpzd77czjwonncahblx6pvrdza \
  --overwrite

kubectl --context=primary-cluster-context annotate svc istio-ingressgateway \
  -n istio-system \
  service.beta.kubernetes.io/oci-load-balancer-subnet1=ocid1.subnet.oc1.us-sanjose-1.aaaaaaaaydads5e35xkxhkiajee77j5qlqtpzd77czjwonncahblx6pvrdza \
  --overwrite

# Secondary cluster gateways
kubectl --context=secondary-cluster annotate svc istio-eastwestgateway \
  -n istio-system \
  service.beta.kubernetes.io/oci-load-balancer-subnet1=ocid1.subnet.oc1.us-chicago-1.aaaaaaaawz55bexqtooqsjc6zsdcscdeccpwbubg5367kjuzi3coasxgvz3q \
  --overwrite

kubectl --context=secondary-cluster annotate svc istio-ingressgateway \
  -n istio-system \
  service.beta.kubernetes.io/oci-load-balancer-subnet1=ocid1.subnet.oc1.us-chicago-1.aaaaaaaawz55bexqtooqsjc6zsdcscdeccpwbubg5367kjuzi3coasxgvz3q \
  --overwrite
```

### 7. Cross-Network Gateway Exposure ✅

```bash
# Expose services for cross-cluster discovery
kubectl --context=primary-cluster-context apply -n istio-system \
  -f istio-1.28.3/samples/multicluster/expose-services.yaml

kubectl --context=secondary-cluster apply -n istio-system \
  -f istio-1.28.3/samples/multicluster/expose-services.yaml
```

### 8. Remote Secret Exchange ✅

```bash
# Install primary cluster secret in secondary
istioctl create-remote-secret \
  --context=primary-cluster-context \
  --name=primary-cluster | \
  kubectl apply -f - --context=secondary-cluster

# Install secondary cluster secret in primary
istioctl create-remote-secret \
  --context=secondary-cluster \
  --name=secondary-cluster | \
  kubectl apply -f - --context=primary-cluster-context
```

---

## Validation Testing

### Test Application Deployment

Deployed HelloWorld sample application:
- **Service**: Deployed in both clusters
- **v1 deployment**: Primary cluster only
- **v2 deployment**: Secondary cluster only
- **Sleep pod**: Primary cluster (for testing)

```bash
# Create namespaces with Istio injection
kubectl create --context=primary-cluster-context namespace sample
kubectl label --context=primary-cluster-context namespace sample istio-injection=enabled

kubectl create --context=secondary-cluster namespace sample
kubectl label --context=secondary-cluster namespace sample istio-injection=enabled

# Deploy services
kubectl apply --context=primary-cluster-context -n sample \
  -f istio-1.28.3/samples/helloworld/helloworld.yaml -l service=helloworld

kubectl apply --context=secondary-cluster -n sample \
  -f istio-1.28.3/samples/helloworld/helloworld.yaml -l service=helloworld

# Deploy v1 in primary
kubectl apply --context=primary-cluster-context -n sample \
  -f istio-1.28.3/samples/helloworld/helloworld.yaml -l version=v1

# Deploy v2 in secondary
kubectl apply --context=secondary-cluster -n sample \
  -f istio-1.28.3/samples/helloworld/helloworld.yaml -l version=v2

# Deploy test client
kubectl apply --context=primary-cluster-context -n sample \
  -f istio-1.28.3/samples/sleep/sleep.yaml
```

### Cross-Cluster Load Balancing Test Results

**Test Command**:
```bash
for i in {1..10}; do 
  kubectl exec --context=primary-cluster-context -n sample \
    -c sleep deploy/sleep -- curl -sS helloworld.sample:5000/hello
done | sort | uniq -c
```

**Results**:
```
4 Hello version: v1, instance: helloworld-v1-7c56bdc7b5-848n8
6 Hello version: v2, instance: helloworld-v2-86b89467fc-dkrdx
```

**Analysis**:
- ✅ **v1** (primary cluster): 4 requests (40%)
- ✅ **v2** (secondary cluster): 6 requests (60%)
- ✅ **Cross-cluster routing**: Working perfectly
- ✅ **Load balancing**: Traffic distributed across both clusters
- ✅ **Service discovery**: Secondary cluster services visible from primary

### Pod Status Verification

**Primary Cluster**:
```
NAME                             READY   STATUS    RESTARTS
helloworld-v1-7c56bdc7b5-848n8   2/2     Running   0
sleep-7cccf64445-pw6rr           2/2     Running   0
```

**Secondary Cluster**:
```
NAME                             READY   STATUS    RESTARTS
helloworld-v2-86b89467fc-dkrdx   2/2     Running   0
```

**Note**: All pods show `2/2` Ready (application container + Istio sidecar proxy)

### Istio Proxy Status

```bash
istioctl --context=primary-cluster-context proxy-status
```

**Output**:
```
NAME                                                   CLUSTER             ISTIOD                      VERSION
helloworld-v1-7c56bdc7b5-848n8.sample                  primary-cluster     istiod-7cc586b766-k6nkf     1.28.3
istio-eastwestgateway-95cc8579c-9cf6z.istio-system     primary-cluster     istiod-7cc586b766-k6nkf     1.28.3
istio-ingressgateway-756bbbdfb5-46ss4.istio-system     primary-cluster     istiod-7cc586b766-k6nkf     1.28.3
sleep-7cccf64445-pw6rr.sample                          primary-cluster     istiod-7cc586b766-k6nkf     1.28.3
```

All proxies synchronized with istiod control plane ✅

---

## Issues Encountered and Resolutions

### Issue 1: Istio Version Outdated
**Problem**: Initial download got Istio 1.20.2 (out of support)  
**Solution**: Downloaded latest version 1.28.3
```bash
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.28.3 sh -
```

### Issue 2: Stagnant Installation Screen
**Problem**: `istioctl install` appeared stuck with no output  
**Solution**: Added verbose logging flag `--log_output_level=default:info` and piped to `tee` for real-time output visibility

### Issue 3: Certificate Authority Error
**Problem**: 
```
Error: failed to create discovery service: failed to create CA: 
failed to create an istiod CA: certificate is not authorized to sign other certificates
```
**Root Cause**: Manually created certificates lacked proper CA extensions  
**Solution**: Used Istio's built-in certificate generation tool via Makefile:
```bash
make -f tools/certs/Makefile.selfsigned.mk root-ca
make -f tools/certs/Makefile.selfsigned.mk primary-cluster-cacerts
make -f tools/certs/Makefile.selfsigned.mk secondary-cluster-cacerts
```

### Issue 4: LoadBalancer Creation Failure
**Problem**:
```
Error syncing load balancer: failed to ensure load balancer: 
a subnet must be specified for creating a load balancer
```
**Root Cause**: OCI requires explicit subnet annotation for LoadBalancer services  
**Solution**: Added OCI-specific annotations to all LoadBalancer services:
```bash
kubectl annotate svc <service-name> \
  service.beta.kubernetes.io/oci-load-balancer-subnet1=<SUBNET_OCID>
```

---

## Service Endpoints

### Primary Cluster (us-sanjose-1)

| Service | Type | Cluster IP | External IP | Ports |
|---------|------|------------|-------------|-------|
| istiod | ClusterIP | 10.96.75.58 | - | 15010, 15012, 443, 15014 |
| istio-ingressgateway | LoadBalancer | 10.96.196.183 | **163.192.53.128** | 80, 443, 15021 |
| istio-eastwestgateway | LoadBalancer | 10.96.238.79 | **150.230.37.157** | 15021, 15443, 15012, 15017 |

### Secondary Cluster (us-chicago-1)

| Service | Type | Cluster IP | External IP | Ports |
|---------|------|------------|-------------|-------|
| istiod | ClusterIP | 10.96.52.67 | - | 15010, 15012, 443, 15014 |
| istio-ingressgateway | LoadBalancer | 10.96.4.134 | **207.211.166.34** | 80, 443, 15021 |
| istio-eastwestgateway | LoadBalancer | 10.96.66.28 | **170.9.229.9** | 15021, 15443, 15012, 15017 |

---

## Key Learnings

### 1. OCI-Specific LoadBalancer Requirements
- OCI LoadBalancer services **require** explicit subnet annotation
- Annotation: `service.beta.kubernetes.io/oci-load-balancer-subnet1`
- Without this, LoadBalancers remain in `<pending>` state with errors

### 2. Certificate Generation Best Practices
- Use Istio's built-in certificate tools instead of manual OpenSSL commands
- Manual certificates often lack required extensions (CA:TRUE, keyUsage, etc.)
- Istio's Makefile ensures proper certificate hierarchy and constraints

### 3. Installation Visibility
- Add `--log_output_level=default:info` for verbose installation logs
- Use `tee` to capture logs while displaying real-time progress
- Prevents appearance of "stuck" installation

### 4. Multi-Cluster Service Mesh Architecture
- **Shared Root CA**: Ensures mTLS trust across clusters
- **East-West Gateways**: Handle cross-cluster service-to-service traffic
- **Remote Secrets**: Enable each cluster's istiod to discover the other cluster's services
- **Network Labels**: Distinguish different networks within the mesh

---

## Network Topology (Final State)

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Istio Multi-Cluster Service Mesh                  │
│                         Mesh ID: oke-mesh                            │
│                                                                      │
│   us-sanjose-1 (primary-network)    us-chicago-1 (secondary-network)│
│                                                                      │
│  ┌─────────────────────┐           ┌──────────────────────┐         │
│  │  Primary Cluster    │           │  Secondary Cluster   │         │
│  │                     │           │                      │         │
│  │  ┌──────────────┐   │           │   ┌──────────────┐  │         │
│  │  │ Istiod       │   │           │   │ Istiod       │  │         │
│  │  │ (Control)    │   │           │   │ (Control)    │  │         │
│  │  └──────────────┘   │           │   └──────────────┘  │         │
│  │                     │           │                      │         │
│  │  ┌──────────────┐   │           │   ┌──────────────┐  │         │
│  │  │ Ingress GW   │   │           │   │ Ingress GW   │  │         │
│  │  │ 163.192.x.x  │   │           │   │ 207.211.x.x  │  │         │
│  │  └──────────────┘   │           │   └──────────────┘  │         │
│  │                     │           │                      │         │
│  │  ┌──────────────┐   │◄─────────►│   ┌──────────────┐  │         │
│  │  │ East-West GW │   │  mTLS     │   │ East-West GW │  │         │
│  │  │ 150.230.x.x  │───┼───────────┼───│ 170.9.x.x    │  │         │
│  │  └──────────────┘   │  15443    │   └──────────────┘  │         │
│  │                     │           │                      │         │
│  │  ┌──────────────┐   │           │   ┌──────────────┐  │         │
│  │  │ helloworld   │   │           │   │ helloworld   │  │         │
│  │  │ v1 (pod)     │   │           │   │ v2 (pod)     │  │         │
│  │  │ 10.0.10.x    │   │           │   │ 10.1.1.x     │  │         │
│  │  └──────────────┘   │           │   └──────────────┘  │         │
│  │                     │           │                      │         │
│  │  Service: helloworld.sample     │  Service: helloworld.sample   │
│  │  Load-balanced across both clusters via Istio mesh              │
│  └─────────────────────┘           └──────────────────────┘         │
│                                                                      │
│  Traffic Flow:                                                       │
│  sleep pod → helloworld.sample → Istio routes to v1 OR v2          │
│  (40% v1 in primary, 60% v2 in secondary - cross-cluster routing!) │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Completion Checklist

### Infrastructure Tasks
- [x] Download and install Istio CLI (istioctl 1.28.3)
- [x] Generate shared root CA certificate
- [x] Generate intermediate CA certificates for both clusters
- [x] Deploy CA secrets to primary cluster
- [x] Deploy CA secrets to secondary cluster
- [x] Install Istio control plane on primary cluster
- [x] Install Istio control plane on secondary cluster
- [x] Install east-west gateway on primary cluster
- [x] Install east-west gateway on secondary cluster
- [x] Fix LoadBalancer subnet annotations (OCI-specific)
- [x] Verify all LoadBalancers have external IPs

### Multi-Cluster Configuration
- [x] Expose Istio services for cross-network discovery
- [x] Create remote secret from primary cluster
- [x] Apply primary remote secret to secondary cluster
- [x] Create remote secret from secondary cluster
- [x] Apply secondary remote secret to primary cluster
- [x] Verify remote secrets installed in both clusters

### Validation Testing
- [x] Deploy test application (helloworld)
- [x] Deploy v1 in primary cluster
- [x] Deploy v2 in secondary cluster
- [x] Deploy sleep test pod
- [x] Test cross-cluster service discovery
- [x] Verify cross-cluster load balancing
- [x] Verify Istio proxy synchronization

### Documentation
- [x] Create Week 2 completion summary
- [x] Document installation commands
- [x] Document issues and resolutions
- [x] Document LoadBalancer endpoints
- [x] Document validation test results

---

## Next Steps: Week 3 - Application Deployment & Traffic Management

With Istio multi-cluster mesh complete, proceed to Week 3:

### Prerequisites ✅ Met
- ✅ Cross-cluster service mesh operational
- ✅ mTLS enabled across clusters
- ✅ Service discovery working bidirectionally
- ✅ Load balancing across clusters validated
- ✅ External access via Istio Ingress Gateway configured and tested

---

## External Access Configuration

### Istio Gateway & VirtualService

Successfully configured external HTTP access to the helloworld service through Istio ingress gateways in both clusters.

**Configuration Files**: `/tmp/helloworld-gateway.yaml`

**Gateway Configuration**:
```yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: helloworld-gateway
  namespace: sample
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
```

**VirtualService Configuration**:
```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: helloworld
  namespace: sample
spec:
  hosts:
  - "*"
  gateways:
  - helloworld-gateway
  http:
  - match:
    - uri:
        prefix: /hello
    route:
    - destination:
        host: helloworld
        port:
          number: 5000
```

### External Access Testing

**Primary Ingress Gateway (us-sanjose-1)**:
```bash
curl http://163.192.53.128/hello
```

**Secondary Ingress Gateway (us-chicago-1)**:
```bash
curl http://207.211.166.34/hello
```

**Test Results** (10 requests to each gateway):

**Primary Gateway** (163.192.53.128):
```
6 Hello version: v1, instance: helloworld-v1-7c56bdc7b5-848n8
4 Hello version: v2, instance: helloworld-v2-86b89467fc-dkrdx
```

**Secondary Gateway** (207.211.166.34):
```
6 Hello version: v1, instance: helloworld-v1-7c56bdc7b5-848n8
4 Hello version: v2, instance: helloworld-v2-86b89467fc-dkrdx
```

**Key Observation**: Both ingress gateways distribute traffic across **all** service instances in **both** clusters, demonstrating true multi-cluster service mesh behavior. Regardless of which gateway you access, traffic is load-balanced globally across both regions.

**Browser Testing**: Service is accessible via:
- http://163.192.53.128/hello (Primary - us-sanjose-1)
- http://207.211.166.34/hello (Secondary - us-chicago-1)

**Multi-Request Test**:
```bash
# Test primary gateway
for i in {1..10}; do curl http://163.192.53.128/hello; done | sort | uniq -c

# Test secondary gateway
for i in {1..10}; do curl http://207.211.166.34/hello; done | sort | uniq -c
```

---

### Week 3 Tasks
1. Deploy production application across both clusters
2. Configure Istio VirtualServices for traffic routing
3. Implement traffic splitting strategies
4. Configure DestinationRules for load balancing
5. Set up fault injection for resilience testing
6. Configure circuit breakers
7. Implement retry policies
8. Set up observability (Prometheus, Grafana, Kiali)

### Reference Documents
- [README.md](README.md) - Week 3 implementation guide
- [WEEK1_COMPLETION_SUMMARY.md](WEEK1_COMPLETION_SUMMARY.md) - Network foundation
- [IMPLEMENTATION_LOG.md](IMPLEMENTATION_LOG.md) - Detailed execution log
- [STATUS.md](STATUS.md) - Current infrastructure status

---

**Week 2 Status**: ✅ **COMPLETE AND VALIDATED**  
**Ready for**: Week 3 - Application Deployment & Advanced Traffic Management  
**Istio Mesh**: Fully operational with cross-cluster service discovery and load balancing
