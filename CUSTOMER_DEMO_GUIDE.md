# Customer Demo Guide: Multi-Cluster Service Mesh

## Quick Demo Flow

When demonstrating the multi-cluster Istio service mesh to customers, follow this flow:

### 1. Access the Application
Open browser to the productpage URL (displayed after Step 5):
- **Primary**: `http://<primary-lb-ip>/productpage`
- **Secondary**: `http://<secondary-lb-ip>/productpage`

---

## Visual Proof Points

### ✨ Proof #1: Service Mesh Load Balancing (Star Ratings)

**What to do**: Refresh the page multiple times (5-10 times)

**What customers will see**:
- **No stars** → Reviews v1 serving the request
- **Black stars ★★★★★** → Reviews v2 serving the request  
- **Red stars ⭐⭐⭐⭐⭐** → Reviews v3 serving the request

**Customer explanation**:
> "Notice how the book reviews section changes each time I refresh. Sometimes you see no stars, sometimes black stars, sometimes red stars. This demonstrates Istio's **intelligent load balancing** across three different versions of the reviews microservice.
>
> In production, this enables **canary deployments** and **A/B testing** - you can roll out new features to a percentage of users without changing application code. Istio handles all the routing logic transparently."

---

### 🌍 Proof #2: Multi-Cluster Routing (Cluster Header)

**What to do**: Open Browser DevTools (F12)

**Steps**:
1. Press **F12** to open DevTools
2. Go to the **Network** tab
3. Refresh the page
4. Click on the **productpage** request (first item in the list)
5. Look at **Response Headers** section
6. Find the header: `X-Served-By-Cluster: PRIMARY` or `SECONDARY`

**What customers will see**:
```
X-Served-By-Cluster: PRIMARY (San Jose)
```
or
```
X-Served-By-Cluster: SECONDARY (Chicago)
```

**Customer explanation**:
> "In the response headers, you can see 'X-Served-By-Cluster' which tells us exactly which cluster served this request. Right now we're hitting the PRIMARY cluster in San Jose.
>
> This is a **multi-region deployment** - we have identical services running in both San Jose and Chicago. Istio's service mesh spans both regions, enabling **cross-cluster service discovery** and **automatic failover**."

---

### 💪 Proof #3: Automatic Failover (Advanced Demo)

**What to do**: Simulate a failure in one cluster

**Steps**:
1. Open terminal and run:
   ```bash
   kubectl --context=primary-cluster-context scale deployment productpage-v1 -n bookinfo --replicas=0
   ```
2. Return to browser accessing the PRIMARY cluster URL
3. Refresh the page multiple times

**What customers will see**:
- Page **still works** even though primary productpage is down
- In DevTools, `X-Served-By-Cluster` may show traffic routing differently
- The application remains available despite cluster-level failure

**Customer explanation**:
> "I just scaled down the productpage service in our San Jose cluster to zero replicas - simulating a complete failure. But notice the application is **still working**. 
>
> Istio's multi-cluster mesh automatically routes traffic to the **healthy services in Chicago**. This is true **active-active disaster recovery** - no manual DNS changes, no waiting for health checks to time out. The mesh detects the failure and reroutes traffic in milliseconds.
>
> This provides **99.99% availability** across regions without complex application-level failover code."

**Restore after demo**:
```bash
kubectl --context=primary-cluster-context scale deployment productpage-v1 -n bookinfo --replicas=1
```

---

## Key Talking Points

### Architecture Benefits
- **Zero application changes** - Apps don't know they're in a multi-cluster mesh
- **Automatic mTLS** - All inter-service traffic is encrypted
- **Cross-cluster service discovery** - Services can call each other across regions using simple DNS names
- **Intelligent routing** - Load balancing, circuit breaking, retries handled by Istio

### Production Use Cases
1. **Geographic distribution** - Serve users from nearest region
2. **Disaster recovery** - Automatic failover between regions
3. **Blue/Green deployments** - Deploy to one cluster, test, then route traffic
4. **Cost optimization** - Burst to second region during peak traffic
5. **Regulatory compliance** - Data residency with cross-region backup

### Oracle Cloud Integration
- **OCI Load Balancer** - Native integration with flexible shapes
- **VCN security** - Clusters communicate over private networks
- **OKE native** - Fully managed Kubernetes with Istio support
- **No egress charges** - Traffic between OCI regions is free

---

## Quick Command Reference

### View Cluster Header in Terminal
```bash
# Primary cluster
curl -sI http://<primary-lb-ip>/productpage | grep X-Served-By-Cluster

# Secondary cluster
curl -sI http://<secondary-lb-ip>/productpage | grep X-Served-By-Cluster
```

### Test Multi-Cluster Routing
```bash
# Generate traffic and see which versions respond
for i in {1..20}; do
  curl -s http://<primary-lb-ip>/productpage | grep -o "reviews-v[1-3]"
done | sort | uniq -c
```

### Check Pod Distribution
```bash
# Primary cluster
kubectl --context=primary-cluster-context get pods -n bookinfo -o wide

# Secondary cluster
kubectl --context=secondary-cluster-context get pods -n bookinfo -o wide
```

---

## Common Customer Questions

**Q: How does Istio know about services in the other cluster?**  
A: We exchange "remote secrets" that contain kubeconfig credentials. Each cluster's Istio control plane can then query the other cluster's API server for service endpoints.

**Q: What happens if the network between clusters fails?**  
A: Each cluster continues serving requests independently. Services only fail over cross-cluster when local services are unhealthy. If inter-cluster networking fails, each cluster operates autonomously.

**Q: Does this work with our existing applications?**  
A: Yes! The only requirement is that pods must have the Istio sidecar injected. This happens automatically in namespaces labeled with `istio-injection=enabled`. No code changes needed.

**Q: What's the latency impact?**  
A: Within a cluster: <1ms overhead. Cross-cluster: adds network round-trip time between regions (~20-50ms for US regions). Istio prefers local services by default to minimize cross-cluster calls.

**Q: How do we manage certificates?**  
A: We use a shared root CA across clusters. Each cluster has its own intermediate CA. This enables mTLS trust between clusters without manual certificate management.

---

## Troubleshooting During Demo

### If stars don't change:
- Check that all three reviews versions are running: `kubectl get pods -n bookinfo | grep reviews`
- Verify VirtualService is applied: `kubectl get virtualservice -n bookinfo`

### If cluster header doesn't appear:
- Verify EnvoyFilter is applied: `kubectl get envoyfilter -n istio-system`
- Check ingress gateway logs: `kubectl logs -n istio-system -l istio=ingressgateway`

### If failover doesn't work:
- Ensure remote secrets exist: `kubectl get secrets -n istio-system | grep remote`
- Check east-west gateway is running: `kubectl get pods -n istio-system | grep eastwest`
- Verify DestinationRules are applied: `kubectl get destinationrules -A`

---

## Additional Resources

- Istio Multi-Cluster Docs: https://istio.io/latest/docs/setup/install/multicluster/
- Bookinfo Sample App: https://istio.io/latest/docs/examples/bookinfo/
- OCI Load Balancer Annotations: https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengcreatingloadbalancer.htm
