#!/bin/bash
set -e

# --- Configuration ---
SSH_USER="root"
SSH_KEY="$HOME/.ssh/collector"
VM_MANAGER="../../lab/vm_manager.sh"
MAIN_VM_NAME="collector_main"
EDGE_VM_NAME="collector_edge"

# --- VM Creation ---
echo "🖥️ Creating Virtual Machines..."
sudo "$VM_MANAGER" create "$MAIN_VM_NAME" "$HOME/.ssh"
sudo "$VM_MANAGER" create "$EDGE_VM_NAME" "$HOME/.ssh"

get_vm_ip() {
	local name=$1
	local ip=""
	echo "⏳ Waiting for IP for $name..." >&2
	while [ -z "$ip" ]; do
		# We use sudo virsh as it requires privileges
		ip=$(sudo virsh domifaddr "$name" 2>/dev/null | grep ipv4 | awk '{print $4}' | cut -d/ -f1)
		[ -z "$ip" ] && sleep 2
	done
	echo "$ip"
}

MAIN_IP=$(get_vm_ip "$MAIN_VM_NAME")
echo "📍 Main VM IP: $MAIN_IP"
EDGE_IP=$(get_vm_ip "$EDGE_VM_NAME")
echo "📍 Edge VM IP: $EDGE_IP"

# --- Cleanup Stale Kubeconfig ---
echo "🧹 Cleaning up stale kubeconfig entries..."
kubectl config delete-context "main-cluster" 2>/dev/null || true
kubectl config delete-cluster "main-cluster" 2>/dev/null || true
kubectl config delete-user "main-cluster" 2>/dev/null || true
kubectl config delete-context "edge-cluster" 2>/dev/null || true
kubectl config delete-cluster "edge-cluster" 2>/dev/null || true
kubectl config delete-user "edge-cluster" 2>/dev/null || true

wait_for_cloud_init() {
	local ip=$1
	echo "⏳ Waiting for cloud-init to finish on $ip..." >&2
	while ! ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$ip" "test -f /var/lib/cloud/instance/boot-finished" 2>/dev/null; do
		sleep 5
	done
}

wait_for_cloud_init "$MAIN_IP"
wait_for_cloud_init "$EDGE_IP"

# --- Cluster Types (The Core Identifiers) ---
MAIN_TYPE="main"
EDGE_TYPE="edge"

# --- Cluster Names (Derived from Types) ---
CLUSTER_MAIN_NAME="${MAIN_TYPE}-cluster"
CLUSTER_EDGE_NAME="${EDGE_TYPE}-cluster"

echo "🚀 Starting Fleet Provisioning..."
echo "Configured: $CLUSTER_MAIN_NAME ($MAIN_TYPE) and $CLUSTER_EDGE_NAME ($EDGE_TYPE)"

# 1. Provision Clusters via k3sup
echo "📦 Installing K3s on $CLUSTER_MAIN_NAME..."
k3sup install \
	--ip $MAIN_IP \
	--user $SSH_USER \
	--ssh-key $SSH_KEY \
	--context $CLUSTER_MAIN_NAME \
	--local-path $HOME/.kube/config \
	--merge

echo "📦 Installing K3s on $CLUSTER_EDGE_NAME..."
k3sup install \
	--ip $EDGE_IP \
	--user $SSH_USER \
	--ssh-key $SSH_KEY \
	--context $CLUSTER_EDGE_NAME \
	--local-path $HOME/.kube/config \
	--merge \
	--k3s-extra-args "--disable traefik --disable servicelb"
# 1.4 Fix Libvirt Firewall (if needed)
if sudo nft list tables | grep -q "libvirt_network"; then
    echo "🛡️ Fixing libvirt nftables for API access (Port 6443)..."
    sudo nft insert rule ip libvirt_network forward oif "virbr0" tcp dport 6443 accept || true
    echo "🛡️ Fixing libvirt nftables for NodePort access (30000-32767)..."
    sudo nft insert rule ip libvirt_network forward oif "virbr0" tcp dport 30000-32767 accept || true
fi
# 1.5 Verify API Reachability
echo "🔍 Checking API reachability for $CLUSTER_MAIN_NAME..."
until curl -sk https://$MAIN_IP:6443/livez >/dev/null; do
	echo "⏳ Waiting for API server at $MAIN_IP:6443..."
	echo "🔍 Checking K3s status on VM..."
	ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$MAIN_IP" "systemctl is-active k3s" || echo "⚠️ K3s service is NOT active yet."
	echo "💡 Hint: Check your host firewall. You might need: sudo firewall-cmd --zone=libvirt --add-port=6443/tcp"
	sleep 5
done
echo "✅ API server is reachable."

# 2. INSTALL ARGOCD
export KUBECONFIG=$HOME/.kube/config
kubectl config use-context $CLUSTER_MAIN_NAME

if ! kubectl get ns argocd &>/dev/null; then
	echo "📦 ArgoCD not found. Installing via Helm..."
	helm repo add argo https://argoproj.github.io/argo-helm
	helm repo update
	helm install argocd argo/argo-cd \
		--namespace argocd \
		--create-namespace \
		--set server.service.type=NodePort

	echo "⏳ Waiting for ArgoCD pods..."
	kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s

	# Retrieve Password
	PASS=""
	while [ -z "$PASS" ]; do
		PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d)
		[ -z "$PASS" ] && sleep 2
	done

	echo "$PASS" >argocd_initial_password.txt
	chmod 600 argocd_initial_password.txt

	# Get NodePort for login
	ARGOCD_PORT=$(kubectl -n argocd get svc argocd-server -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
	echo "🔐 Logging into ArgoCD CLI..."
	argocd login "$MAIN_IP:$ARGOCD_PORT" --username admin --password "$PASS" --insecure --grpc-web
else
	echo "✅ ArgoCD already installed. Re-logging..."
	PASS=$(cat argocd_initial_password.txt 2>/dev/null || echo "")
	if [ ! -z "$PASS" ]; then
		ARGOCD_PORT=$(kubectl -n argocd get svc argocd-server -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
		argocd login "$MAIN_IP:$ARGOCD_PORT" --username admin --password "$PASS" --insecure --grpc-web
	else
		echo "⚠️ No password file found, assuming already logged in or using --core"
		argocd login --core
	fi
fi

# 2.5 INSTALL METALLB
install_metallb() {
    local context=$1
    local ip_prefix=$2
    local start=$3
    local end=$4
    
    echo "📦 Configuring MetalLB on $context (Range: ${ip_prefix}.${start}-${ip_prefix}.${end})..."
    kubectl config use-context "$context"
    
    if ! kubectl get ns metallb-system &>/dev/null; then
        kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.3/config/manifests/metallb-native.yaml
        echo "⏳ Waiting for MetalLB pods to be registered..."
        sleep 10
        kubectl wait --for=condition=ready pod -l app=metallb -n metallb-system --timeout=300s
    else
        echo "✅ MetalLB already installed on $context. Ensuring config is up to date..."
    fi
    
    # ALWAYS configure/update MetalLB with a range in the libvirt network (192.168.122.x)
    cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
  - ${ip_prefix}.${start}-${ip_prefix}.${end}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-advert
  namespace: metallb-system
EOF
}

# Install MetalLB on Main (Range .200-.210)
install_metallb "$CLUSTER_MAIN_NAME" "192.168.122" 200 210
# Install MetalLB on Edge (Range .211-.220)
install_metallb "$CLUSTER_EDGE_NAME" "192.168.122" 211 220

# 3. Register Clusters with ArgoCD
echo "🔗 Registering clusters..."
kubectl config use-context "$CLUSTER_MAIN_NAME"

# Register Main (Self)
argocd cluster add $CLUSTER_MAIN_NAME \
	--name $CLUSTER_MAIN_NAME \
	--label type=$MAIN_TYPE \
	--upsert -y \
	--grpc-web --insecure

# Register Edge
argocd cluster add $CLUSTER_EDGE_NAME \
	--name $CLUSTER_EDGE_NAME \
	--label type=$EDGE_TYPE \
	--upsert -y \
	--grpc-web --insecure

# Get ArgoCD NodePort
ARGOCD_PORT=$(kubectl -n argocd get svc argocd-server -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')

echo "-------------------------------------------------------"
echo "✅ Infrastructure is Ready!"
echo "Contexts: $CLUSTER_MAIN_NAME, $CLUSTER_EDGE_NAME"
echo "Labels:   type=$MAIN_TYPE, type=$EDGE_TYPE"
echo "ArgoCD UI: https://$MAIN_IP:$ARGOCD_PORT"
echo "-------------------------------------------------------"
