# Kubernetes Network Policies: Zero-Trust Lab

A hands-on Kubernetes lab demonstrating namespace-level default-deny isolation and explicitly permitted application traffic.

The example application has three workload tiers:

```text
Frontend  --TCP/80-->  API  --TCP/6379-->  Redis
   |                    |                   |
   +------ DNS:53 ------+-------------------+
```

The intended network behavior is:

| Source | Destination | Protocol / port | Expected |
|---|---|---:|---|
| Frontend | API Service | TCP/80 | Allow |
| API | Database Service (Redis) | TCP/6379 | Allow |
| Frontend | Database Service (Redis) | TCP/6379 | Deny |
| Application Pods | CoreDNS | UDP/53 and TCP/53 | Allow |
| Other traffic | Any | Any | Deny, unless separately allowed |

> **Important:** Kubernetes stores NetworkPolicy resources, but enforcement is performed by the cluster networking implementation (CNI). Use a CNI that supports Kubernetes NetworkPolicy. This lab uses Calico. A standard Kind cluster using only kindnet does not enforce these policies.

## Repository layout

```text
kubernetes-network-policies/
├── README.md
├── kind/
│   └── kind-calico.yaml
├── applications/
│   └── applications.yaml
├── policies/
│   ├── default-deny.yaml
│   ├── allow-dns.yaml
│   ├── frontend-egress.yaml
│   ├── api-ingress.yaml
│   ├── api-egress.yaml
│   └── database-ingress.yaml
└── tests/
    └── connectivity-tests.sh
```

## Prerequisites

- Docker
- [Kind](https://kind.sigs.k8s.io/)
- `kubectl`
- Bash (for the test script)
- Internet access to pull container images and Calico manifests

The commands below create a dedicated local cluster named `netpol-lab`. Do not use an existing cluster for this exercise unless you understand its CNI and networking configuration.

## 1. Create a Kind cluster without kindnet

Calico must provide the cluster networking, so the default Kind CNI is disabled in the cluster configuration.

```bash
kind create cluster \
  --name netpol-lab \
  --config kind/kind-calico.yaml
```

Check that the cluster exists:

```bash
kubectl cluster-info --context kind-netpol-lab
kubectl get nodes -o wide
```

The nodes may remain `NotReady` until Calico is installed. That is expected at this stage.

## 2. Install Calico

This example pins Calico to **v3.33.0** so the lab is reproducible. Check the [official Calico Kind guide](https://docs.tigera.io/calico/latest/getting-started/kubernetes/kind) before using a different Kubernetes version or Calico release.

First install the Calico custom resource definitions. Choose **one** command based on your Kubernetes version:

For Kubernetes 1.36 and later:

```bash
kubectl create -f \
  https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/v3_projectcalico_org.yaml
```

For Kubernetes 1.34 or 1.35:

```bash
kubectl create -f \
  https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/v3_projectcalico_org-v1beta1.yaml
```

Then install the Tigera Operator and the Calico installation resource:

```bash
kubectl create -f \
  https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/tigera-operator.yaml

kubectl create -f \
  https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/custom-resources.yaml
```

The supplied Kind configuration uses the Pod CIDR `192.168.0.0/16`, which matches the default pool in the Calico `custom-resources.yaml` manifest. If you change the Pod CIDR, update the Calico installation configuration too.

Wait for the cluster networking to become healthy:

```bash
kubectl get tigerastatus
kubectl get pods -n calico-system
kubectl get nodes
```

All nodes should eventually become `Ready`. Calico components should report as available. Do not continue until the CNI is healthy.

## 3. Create the application namespace and workloads

```bash
kubectl create namespace zero-trust-lab
kubectl apply -f applications/applications.yaml
```

Wait for the Deployments:

```bash
kubectl rollout status deployment/frontend -n zero-trust-lab
kubectl rollout status deployment/api -n zero-trust-lab
kubectl rollout status deployment/database -n zero-trust-lab
```

The application manifest creates:

- A frontend placeholder Pod (BusyBox, sleeping).
- An API Pod (Nginx) exposed by the `api` Service on TCP/80.
- A Redis Pod exposed by the `database` Service on TCP/6379.

The testing Pods are created automatically by the test script. They use the same network labels as their corresponding application tiers, but the API test Pod is deliberately excluded from the `api` Service selector.

## 4. Apply the NetworkPolicies

```bash
kubectl apply -f policies/
```

The policies implement the following model:

1. `default-deny.yaml` isolates every Pod in the namespace for ingress and egress.
2. `allow-dns.yaml` permits DNS queries to CoreDNS over UDP and TCP port 53.
3. `frontend-egress.yaml` permits frontend Pods to initiate TCP connections to API Pods on port 80.
4. `api-ingress.yaml` permits API Pods to receive TCP connections from frontend Pods on port 80.
5. `api-egress.yaml` permits API Pods to initiate TCP connections to database Pods on port 6379.
6. `database-ingress.yaml` permits database Pods to receive TCP connections from API Pods on port 6379.

The rules are additive. The default-deny policy does not override the explicit allow policies; the allowed connections are the union of all applicable rules for each direction.

## 5. Run the connectivity tests

Make the script executable and run it:

```bash
chmod +x tests/connectivity-tests.sh
./tests/connectivity-tests.sh
```

The script uses the current `kubectl` context and the `zero-trust-lab` namespace. It creates `frontend-check` and `api-check` Pods if they do not already exist, waits for them to become Ready, then verifies:

- Frontend can resolve the `api` Service through DNS.
- Frontend can reach the API over TCP/80.
- API can reach Redis over TCP/6379.
- Frontend cannot connect directly to Redis over TCP/6379.

A successful run should report all four checks as `PASS`.

## 6. Inspect the resources

```bash
kubectl get networkpolicy -n zero-trust-lab
kubectl describe networkpolicy -n zero-trust-lab
kubectl get pods -n zero-trust-lab --show-labels
kubectl get services,endpointslices -n zero-trust-lab
```

Check CoreDNS labels if DNS does not work:

```bash
kubectl get pods -n kube-system --show-labels
```

The DNS policy in this lab assumes CoreDNS Pods are in `kube-system` and carry the label `k8s-app=kube-dns`, as in a typical Kubernetes cluster. Adjust the namespace and Pod selector if your DNS implementation differs.

## 7. Cleanup

Delete the lab namespace and all its application resources:

```bash
kubectl delete namespace zero-trust-lab
```

Delete the dedicated Kind cluster when you have finished:

```bash
kind delete cluster --name netpol-lab
```

## Troubleshooting

### Pods remain Pending or nodes are NotReady

Check that Calico installed correctly:

```bash
kubectl get tigerastatus
kubectl get pods -n calico-system -o wide
kubectl describe nodes
```

### DNS lookup fails

Check CoreDNS health and labels:

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl get pods -n kube-system --show-labels
```

Confirm that the `allow-dns` policy selects the actual DNS Pods in your cluster.

### An allowed connection fails

Check Pod labels, Service selectors, endpoints, and policies:

```bash
kubectl get pods -n zero-trust-lab --show-labels
kubectl get services,endpointslices -n zero-trust-lab
kubectl get networkpolicy -n zero-trust-lab
kubectl describe networkpolicy -n zero-trust-lab
```

Remember that a Pod-to-Pod connection can be blocked by the source Pod's egress isolation or the destination Pod's ingress isolation. Both sides must permit the connection when both are isolated in the corresponding direction.

### A policy exists but traffic is not blocked

Verify that the cluster is using a NetworkPolicy-capable CNI and that its Pods are healthy. Creating a NetworkPolicy object alone does not guarantee enforcement.

## Important limitations

- Standard Kubernetes NetworkPolicy is an L3/L4 control. It does not inspect HTTP paths, authenticate application users, or encrypt traffic.
- Standard NetworkPolicies are additive; they do not provide an explicit deny rule that overrides another policy's allow rule.
- This lab does not cover host-networked Pods, node-level firewalling, service-mesh authorization, or cloud-provider-specific network paths.
- The manifests are educational examples. Review selectors, ports, DNS behavior, and CNI compatibility before adapting them to production.

## References

- [Kubernetes: Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [Kubernetes API: NetworkPolicy](https://kubernetes.io/docs/reference/kubernetes-api/networking/network-policy-v1/)
- [Calico: Installing on Kind](https://docs.tigera.io/calico/latest/getting-started/kubernetes/kind)
- [Calico: Kubernetes Network Policy](https://docs.tigera.io/calico/latest/network-policy/get-started/kubernetes-policy/kubernetes-policy-basic)
- [Kind: Configuration](https://kind.sigs.k8s.io/docs/user/configuration/)
