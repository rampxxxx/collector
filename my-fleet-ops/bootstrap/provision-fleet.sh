#!/bin/bash
set -e

# --- Configuration ---
SSH_USER="root"
SSH_KEY="$HOME/.ssh/collector"
VM_MANAGER="../../lab/vm_manager.sh"
MAIN_VM_NAME="collector_main"
EDGE_VM_NAME="collector_edge"
RANCHER_ADMIN_USER="admin"

# --- VM Creation ---
echo "🖥️ Creating Virtual Machines..."
# Main cluster needs more resources for Rancher
VM_RAM=4000 VM_VCPUS=4 sudo -E "$VM_MANAGER" create "$MAIN_VM_NAME" "$HOME/.ssh"
# Edge cluster can stay minimal
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

# 2.5 CONFIGURE METALLB
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

	# ALWAYS configure/update MetalLB
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
echo "🔗 Registering clusters with ArgoCD..."
kubectl config use-context "$CLUSTER_MAIN_NAME"

argocd cluster add $CLUSTER_MAIN_NAME --name $CLUSTER_MAIN_NAME --label type=$MAIN_TYPE --upsert -y --grpc-web --insecure
argocd cluster add $CLUSTER_EDGE_NAME --name $CLUSTER_EDGE_NAME --label type=$EDGE_TYPE --upsert -y --grpc-web --insecure

ARGOCD_PORT=$(kubectl -n argocd get svc argocd-server -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')

# 4. Deploy Root Application
echo "🚀 Deploying ArgoCD Root Application..."
kubectl apply -f ../gitops/root-app.yaml

# 5. RANCHER INSTALLATION & IMPORT (Final Step)
echo "🤠 Starting Rancher Setup..."

install_rancher() {
	local context=$1
	echo "📦 Installing Rancher UI on $context..."
	kubectl config use-context "$context"

	if ! kubectl get ns cattle-system &>/dev/null; then
		# 1. Install cert-manager
		echo "📦 Installing cert-manager..."
		helm repo add jetstack https://charts.jetstack.io
		helm repo update
		helm install cert-manager jetstack/cert-manager \
			--namespace cert-manager \
			--create-namespace \
			--set installCRDs=true

		echo "⏳ Waiting for cert-manager pods..."
		kubectl wait --for=condition=available deployment/cert-manager -n cert-manager --timeout=300s

		# 2. Install Rancher
		echo "📦 Installing Rancher..."
		helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
		helm repo update
		helm install rancher rancher-stable/rancher \
			--namespace cattle-system \
			--create-namespace \
			--set hostname=rancher.$MAIN_IP.sslip.io \
			--set bootstrapPassword=$RANCHER_ADMIN_USER \
			--set replicas=1 \
			--set service.type=LoadBalancer

		echo "⏳ Waiting for Rancher pods..."
		kubectl wait --for=condition=available deployment/rancher -n cattle-system --timeout=300s
	else
		echo "✅ Rancher already installed on $context."
	fi
}

import_to_rancher() {
	local edge_context=$1
	local rancher_host="rancher.$MAIN_IP.sslip.io"
	local EMPTY_TOKEN="EMPTY"

	echo "🔗 Automatically importing $edge_context into Rancher..."

	# 1. Login to get a token
	echo "🔑 Logging into Rancher API..."
	LOGIN_RESPONSE=$(curl -sk "https://$rancher_host/v3-public/localProviders/local?action=login" \
		-H 'Content-Type: application/json' \
		-d "{\"username\":\"$RANCHER_ADMIN_USER\",\"password\":\"$RANCHER_ADMIN_USER\"}" || echo "Error login into Rancher" && return 0)

	TOKEN=$(echo "$LOGIN_RESPONSE" | grep -oP '"token":"\K[^"]+' || echo "$EMPTY_TOKEN")

	if [ -z "$TOKEN" ] || [ "$TOKEN" == "$EMPTY_TOKEN" ]; then
		echo "❌ Failed to get Rancher token. Skipping automated import."
		return
	fi

	# 2. Check/Create Cluster Resource
	echo "🏗️ Checking cluster resource in Rancher..."
	CLUSTER_ID=$(curl -sk "https://$rancher_host/v3/clusters?name=$edge_context" \
		-H "Authorization: Bearer $TOKEN" | grep -oP '"id":"\K[^"]+' | head -1)

	if [ -z "$CLUSTER_ID" ]; then
		echo "🏗️ Creating cluster resource in Rancher..."
		CLUSTER_ID=$(curl -sk "https://$rancher_host/v3/clusters" \
			-H "Authorization: Bearer $TOKEN" \
			-H 'Content-Type: application/json' \
			-d "{\"type\":\"cluster\",\"name\":\"$edge_context\"}" | grep -oP '"id":"\K[^"]+')
	fi

	# 3. Retrieve Registration Command
	echo "📋 Retrieving registration command..."
	TOKEN_ID=""
	for i in {1..15}; do
		TOKEN_ID=$(curl -sk "https://$rancher_host/v3/clusterregistrationtokens?clusterId=$CLUSTER_ID" \
			-H "Authorization: Bearer $TOKEN" | grep -oP '"data":\[.*?"id":"\K[^"]+' | head -1)
		[ ! -z "$TOKEN_ID" ] && break
		sleep 5
	done

	REG_VALUE=""
	for i in {1..20}; do
		REG_DATA=$(curl -sk "https://$rancher_host/v3/clusterregistrationtokens/$TOKEN_ID" \
			-H "Authorization: Bearer $TOKEN")
		REG_VALUE=$(echo "$REG_DATA" | grep -oP '"insecureCommand":"\K[^"]+')
		[ ! -z "$REG_VALUE" ] && break
		sleep 5
	done
	# 4. Apply to Edge Cluster
	echo "🚀 Applying registration to $edge_context..."
	kubectl config use-context "$edge_context"
	if [ ! -z "$REG_VALUE" ]; then
		CLEAN_VAL=$(echo "$REG_VALUE" | sed 's/\\//g')

		# Extract the URL from the curl command if it's already a full command
		if [[ "$CLEAN_VAL" == *"http"* ]]; then
			# Regex to find the URL inside the string
			MANIFEST_URL=$(echo "$CLEAN_VAL" | grep -oP 'https?://[^ ]+')
			echo "📥 Downloading registration manifest from: $MANIFEST_URL"
			curl -skL -H "Authorization: Bearer $TOKEN" "$MANIFEST_URL" >registration.yaml

			if [ -s registration.yaml ]; then
				echo "📄 Manifest downloaded successfully. Applying..."
				kubectl apply -f registration.yaml
				rm registration.yaml
			else
				echo "❌ Downloaded manifest is empty. Skipping apply."
			fi
		else
			echo "❌ Unrecognized registration command format: $CLEAN_VAL"
		fi
	else
		echo "❌ Could not find registration command."
	fi
	kubectl config use-context "$CLUSTER_MAIN_NAME"
}

# Run Rancher steps, but don't fail the whole script if they hit a snag
install_rancher "$CLUSTER_MAIN_NAME" || echo "⚠️ Warning: Rancher installation encountered an issue."
import_to_rancher "$CLUSTER_EDGE_NAME" || echo "⚠️ Warning: Automated edge import encountered an issue."

RANCHER_URL="https://rancher.$MAIN_IP.sslip.io"

echo "-------------------------------------------------------"
echo "✅ Infrastructure is Ready!"
echo "Contexts: $CLUSTER_MAIN_NAME, $CLUSTER_EDGE_NAME"
echo "Labels:   type=$MAIN_TYPE, type=$EDGE_TYPE"
echo "ArgoCD UI: https://$MAIN_IP:$ARGOCD_PORT"
echo "Rancher UI: $RANCHER_URL (Initial Password: $RANCHER_ADMIN_USER)"
echo "-------------------------------------------------------"
