# Step-by-Step: Generate Talos ISO and Bootstrap a Kubernetes Cluster with Longhorn

## Prerequisites
- `talosctl` CLI installed (https://www.talos.dev/latest/talos-guides/install/talosctl/)
- `kubectl` CLI installed
- A machine/VM/hardware to boot the ISO (BIOS or UEFI)
- Network access between nodes
- At least 3 nodes recommended for Longhorn HA (1 control-plane + 2+ workers, or 3 combined)

---

## 1. Install talosctl

```bash
curl -sL https://talos.dev/install | sh
talosctl version --client
```

## 2. Generate a Custom Talos ISO (with extensions for Longhorn)

Longhorn requires `iscsi-tools` and `util-linux-tools` system extensions baked into the Talos image.

### 2.1 Find the latest Talos version and installer image
```bash
talosctl version --client
export TALOS_VERSION=v1.7.6
```

### 2.2 Use the Image Factory to build a custom installer/ISO
Visit https://factory.talos.dev or use the API directly.

```bash
curl -X POST --data-binary @- https://factory.talos.dev/schematic <<EOF
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
EOF
```

This returns a JSON response with a `schematic_id`, e.g.:
```json
{"id": "376567988ad370138ad8b2698212367b8edcb69b54162c0d2e6cf2d0522f9f2"}
```

Export it:
```bash
export SCHEMATIC_ID=376567988ad370138ad8b2698212367b8edcb69b54162c0d2e6cf2d0522f9f2
```

### 2.3 Download the custom ISO
```bash
curl -Lo talos-amd64.iso \
  "https://factory.talos.dev/image/${SCHEMATIC_ID}/${TALOS_VERSION}/metal-amd64.iso"
```

(For ARM64, replace `metal-amd64` with `metal-arm64`.)

---

## 3. Boot Nodes from the ISO

1. Write/attach the ISO to each node (USB, virtual media, or PXE).
2. Boot all nodes (control-plane + workers) from the ISO.
3. Talos will boot into maintenance mode and print its IP address on the console — note the IPs for each node.

---

## 4. Generate Machine Configurations

```bash
export CONTROL_PLANE_IP=192.168.1.10
export CLUSTER_NAME=talos-longhorn-cluster

talosctl gen config ${CLUSTER_NAME} https://${CONTROL_PLANE_IP}:6443 \
  --output-dir _out
```

This creates:
- `_out/controlplane.yaml`
- `_out/worker.yaml`
- `_out/talosconfig`

### 4.1 Patch configs to install the custom image with extensions
Create a patch file `patch.yaml`:
```yaml
machine:
  install:
    image: factory.talos.dev/installer/${SCHEMATIC_ID}:${TALOS_VERSION}
  kubelet:
    extraMounts:
      - destination: /var/lib/longhorn
        type: bind
        source: /var/lib/longhorn
        options:
          - bind
          - rshared
          - rw
```

Apply the patch when generating (or re-generate with `--config-patch`):
```bash
talosctl gen config ${CLUSTER_NAME} https://${CONTROL_PLANE_IP}:6443 \
  --output-dir _out \
  --config-patch @patch.yaml \
  --config-patch-control-plane @patch.yaml \
  --config-patch-worker @patch.yaml
```

---

## 5. Apply Configuration to Nodes

### 5.1 Control plane node
```bash
talosctl apply-config --insecure \
  --nodes ${CONTROL_PLANE_IP} \
  --file _out/controlplane.yaml
```

### 5.2 Worker nodes
```bash
export WORKER1_IP=192.168.1.11
export WORKER2_IP=192.168.1.12

talosctl apply-config --insecure --nodes ${WORKER1_IP} --file _out/worker.yaml
talosctl apply-config --insecure --nodes ${WORKER2_IP} --file _out/worker.yaml
```

Nodes will reboot and install Talos to disk automatically.

---

## 6. Bootstrap the Cluster

```bash
export TALOSCONFIG=_out/talosconfig

talosctl bootstrap --nodes ${CONTROL_PLANE_IP} --endpoints ${CONTROL_PLANE_IP}
```

Wait a few minutes for etcd and control plane components to come up.

## 7. Retrieve kubeconfig

```bash
talosctl kubeconfig . --nodes ${CONTROL_PLANE_IP} --endpoints ${CONTROL_PLANE_IP}
export KUBECONFIG=$(pwd)/kubeconfig

kubectl get nodes -o wide
```

---

## 8. Install Longhorn

### 8.1 Verify prerequisites on each node
```bash
kubectl -n kube-system get pods
talosctl -n ${WORKER1_IP} get extensions
```
Confirm `iscsi-tools` and `util-linux-tools` are listed.

### 8.2 Install open-iscsi check (already provided by extension) and Longhorn via Helm
```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update

kubectl create namespace longhorn-system

helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --set persistence.defaultClassReplicaCount=3
```

Or via manifest:
```bash
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.6.2/deploy/longhorn.yaml
```

### 8.3 Verify Longhorn deployment
```bash
kubectl -n longhorn-system get pods
kubectl -n longhorn-system get svc longhorn-frontend
```

---

## 9. Access Longhorn UI

```bash
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
```
Open http://localhost:8080

---

## 10. Set Longhorn as Default StorageClass (optional)

```bash
kubectl patch storageclass longhorn \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

---

## 11. Test with a PVC

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: longhorn-test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
```

```bash
kubectl apply -f pvc-test.yaml
kubectl get pvc longhorn-test-pvc
```

Cluster is now ready with Talos + Kubernetes + Longhorn storage.
