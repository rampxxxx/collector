#!/bin/bash
set -e

# --- Configuration ---
SSH_USER="root"
SSH_KEY="$HOME/.ssh/collector"
VM_MANAGER="../../lab/vm_manager.sh"
MAIN_VM_NAME="collector_main"
EDGE_VM_NAME="collector_edge"
RANCHER_ADMIN_USER="admin"

# --- Functions ---
get_vm_ip() {
	local name=$1
	local ip=""
	echo "⏳ Waiting for IP for $name..." >&2
	while [ -z "$ip" ]; do
		# We use sudo virsh as it requires privileges
		# virsh domifaddr output is a table, we extract the IPv4 address
		ip=$(sudo virsh domifaddr "$name" 2>/dev/null | grep ipv4 | awk '{print $4}' | cut -d/ -f1)
		[ -z "$ip" ] && sleep 2
	done
	echo "$ip"
}
wait_for_cloud_init() {
	local ip=$1
	echo "⏳ Waiting for cloud-init to finish on $ip..." >&2
	while ! ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$ip" "test -f /var/lib/cloud/instance/boot-finished" 2>/dev/null; do
		sleep 5
	done
}
argocd_login_with_retries() {
	local ip=$1
	local port=$2
	local password=$3
	echo "🔐 Logging into ArgoCD CLI ($ip:$port)..."
	for i in {1..10}; do
		if argocd login "$ip:$port" --username admin --password "$password" --insecure --grpc-web; then
			echo "✅ Successfully logged into ArgoCD"
			return 0
		fi
		echo "⏳ ArgoCD login failed, retrying in 15s ($i/10)..."
		sleep 15
	done
	return 1
}
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
	fi

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

configure_registry_mirror() {
	local ip=$1
	local reg_ip=$(kubectl get svc -n default main-cluster-internal-registry -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
	echo "📦 Pushing registry config to $ip..."
	ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$ip" "mkdir -p /etc/rancher/k3s && echo -e 'mirrors:\n  \"$reg_ip:5000\":\n    endpoint:\n      - \"http://$reg_ip:5000\"\nconfigs:\n  \"$reg_ip:5000\":\n    auth:\n      insecure: true' > /etc/rancher/k3s/registries.yaml && systemctl restart k3s || systemctl restart k3s-agent"
}
register_cluster_with_retries() {
	local name=$1
	local type=$2
	echo "🔗 Registering $name ($type) with retries..."
	for i in {1..10}; do
		if argocd cluster add "$name" --name "$name" --label "type=$type" --upsert -y --grpc-web --insecure; then
			echo "✅ Successfully registered $name"
			return 0
		fi
		echo "⏳ Registration failed, retrying in 10s ($i/10)..."
		sleep 10
	done
	echo "❌ Failed to register $name after 10 attempts."
	return 1
}
configure_host_registry() {
	local reg_ip=$(kubectl get svc -n default main-cluster-internal-registry -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
	echo "⚙️ Configuring host Docker daemon for insecure registry ($reg_ip:5000)..."
	sudo mkdir -p /etc/docker
	if [ -f /etc/docker/daemon.json ]; then
		sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
		echo "$(cat /etc/docker/daemon.json | jq -M --arg ip "$reg_ip:5000" '.["insecure-registries"] += [$ip] | .["insecure-registries"] |= unique')" | sudo tee /etc/docker/daemon.json >/dev/null
	else
		echo "{\"insecure-registries\": [\"$reg_ip:5000\"]}" | sudo tee /etc/docker/daemon.json >/dev/null
	fi
	sudo systemctl restart docker
	echo "✅ Docker daemon configured for $reg_ip:5000"
}
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
			--set hostname=rancher."$MAIN_IP".sslip.io \
			--set bootstrapPassword=$RANCHER_ADMIN_USER \
			--set replicas=1 \
			--set service.type=LoadBalancer

		echo "⏳ Waiting for Rancher deployment rollout..."
		until kubectl rollout status deployment/rancher -n cattle-system --timeout=300s | grep -i "successfully"; do
			echo "⏳ Waiting for successful rollout message..."
			sleep 10
		done
		echo "✅ Rancher rollout complete."

		echo "⏳ Final wait for all pods in cattle-system to be ready..."
		kubectl wait --for=condition=ready pod --all -n cattle-system --timeout=300s
	else
		echo "✅ Rancher already installed on $context. Ensuring components are ready..."
		kubectl wait --for=condition=ready pod --all -n cattle-system --timeout=120s
	fi
}

import_to_rancher() {
	local edge_context=$1
	local EMPTY_TOKEN="EMPTY"

	echo "🔗 Automatically importing $edge_context into Rancher..."

	# Get the actual LoadBalancer IP for Rancher
	echo "🔍 Finding Rancher LoadBalancer IP..."
	local rancher_ip=""
	for i in {1..20}; do
		rancher_ip=$(kubectl -n cattle-system get svc rancher -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
		[ ! -z "$rancher_ip" ] && [ "$rancher_ip" != "null" ] && break
		echo "⏳ Waiting for Rancher LoadBalancer IP ($i/20)..."
		sleep 10
	done

	if [ -z "$rancher_ip" ]; then
		echo "❌ Failed to find Rancher LoadBalancer IP. Skipping import."
		return
	fi

	local rancher_host="rancher.$rancher_ip.sslip.io"
	echo "📍 Rancher Host: $rancher_host"

	# 1. Login to get a token
	echo "🔑 Logging into Rancher API..."
	LOGIN_RESPONSE=""
	for i in {1..12}; do
		LOGIN_RESPONSE=$(curl -sk "https://$rancher_host/v3-public/localProviders/local?action=login" \
			-H 'Content-Type: application/json' \
			-d "{\"username\":\"$RANCHER_ADMIN_USER\",\"password\":\"$RANCHER_ADMIN_USER\"}" || echo '{"type":"error","message":"curl_failed"}')

		if echo "$LOGIN_RESPONSE" | jq -e '.token' >/dev/null 2>&1; then
			break
		fi
		echo "⏳ Waiting for Rancher API to be ready ($i/12)..."
		sleep 15
	done

	if echo "$LOGIN_RESPONSE" | jq -e '.type == "error"' >/dev/null 2>&1; then
		echo "❌ Rancher login failed: $(echo "$LOGIN_RESPONSE" | jq -r .message)"
		return
	fi

	TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r .token)
	echo "✅ Obtained API Token: ${TOKEN:0:10}..."

	# 1.5 CONFIGURE RANCHER SETTINGS (CRITICAL for self-signed lab)
	echo "⚙️ Setting Rancher server-url to https://$rancher_host..."
	curl -sk "https://$rancher_host/v3/settings/server-url" \
		-H "Authorization: Bearer $TOKEN" \
		-H 'Content-Type: application/json' \
		-X PUT \
		-d "{\"value\":\"https://$rancher_host\"}" >/dev/null

	# 2. Check/Create Cluster Resource
	echo "🏗️ Checking cluster resource in Rancher..."
	CLUSTER_ID=""
	for i in {1..5}; do
		CLUSTER_ID=$(curl -sk "https://$rancher_host/v3/clusters?name=$edge_context" \
			-H "Authorization: Bearer $TOKEN" | jq -r '.data[0].id // ""')
		[ ! -z "$CLUSTER_ID" ] && [ "$CLUSTER_ID" != "null" ] && break
		sleep 5
	done

	if [ -z "$CLUSTER_ID" ] || [ "$CLUSTER_ID" == "null" ]; then
		echo "🏗️ Creating cluster resource in Rancher..."
		CLUSTER_ID=$(curl -sk "https://$rancher_host/v3/clusters" \
			-H "Authorization: Bearer $TOKEN" \
			-H 'Content-Type: application/json' \
			-d "{\"type\":\"cluster\",\"name\":\"$edge_context\"}" | jq -r .id)
		echo "⏳ Giving Rancher 30s to initialize the new cluster object..."
		sleep 30
	fi
	echo "🆔 Cluster ID: $CLUSTER_ID"

	# 3. Retrieve Registration Command
	echo "📋 Retrieving registration command..."
	TOKEN_ID=""
	for i in {1..15}; do
		TOKEN_ID=$(curl -sk "https://$rancher_host/v3/clusterregistrationtokens?clusterId=$CLUSTER_ID" \
			-H "Authorization: Bearer $TOKEN" | jq -r '.data[0].id // ""')
		[ ! -z "$TOKEN_ID" ] && [ "$TOKEN_ID" != "null" ] && break
		echo "⏳ No token found, explicitly requesting Rancher to generate one ($i/15)..."
		curl -sk "https://$rancher_host/v3/clusterregistrationtokens" \
			-H "Authorization: Bearer $TOKEN" \
			-H 'Content-Type: application/json' \
			-d "{\"type\":\"clusterRegistrationToken\",\"clusterId\":\"$CLUSTER_ID\"}" >/dev/null
		sleep 10
	done
	echo "🆔 Token ID: $TOKEN_ID"

	REG_VALUE=""
	MANIFEST_URL=""
	CLUSTER_TOKEN=""
	for i in {1..20}; do
		REG_DATA=$(curl -sk "https://$rancher_host/v3/clusterregistrationtokens/$TOKEN_ID" \
			-H "Authorization: Bearer $TOKEN")

		REG_VALUE=$(echo "$REG_DATA" | jq -r '.insecureCommand // ""')
		MANIFEST_URL=$(echo "$REG_DATA" | jq -r '.manifestUrl // ""')
		CLUSTER_TOKEN=$(echo "$REG_DATA" | jq -r '.token // ""')

		if ([ ! -z "$REG_VALUE" ] && [ "$REG_VALUE" != "null" ]) ||
			([ ! -z "$MANIFEST_URL" ] && [ "$MANIFEST_URL" != "null" ]) ||
			([ ! -z "$CLUSTER_TOKEN" ] && [ "$CLUSTER_TOKEN" != "null" ]); then
			break
		fi
		echo "⏳ Waiting for Rancher to populate registration data ($i/20)..."
		sleep 15
	done
	echo "🔑 Cluster Token: ${CLUSTER_TOKEN:0:10}..."

	# 4. Apply to Edge Cluster (Insecure Import)
	echo "🚀 Applying registration to $edge_context..."
	kubectl config use-context "$edge_context"

	if [ ! -z "$CLUSTER_TOKEN" ] && [ "$CLUSTER_TOKEN" != "null" ]; then
		# Official Rancher UI pattern for insecure import:
		# curl --insecure -sfL https://<host>/v3/import/<token>.yaml | kubectl apply -f -
		local REG_CMD="curl --insecure -sfL https://$rancher_host/v3/import/${CLUSTER_TOKEN}.yaml | kubectl apply -f -"
		echo "Executing: $REG_CMD"
		eval "$REG_CMD" || echo "⚠️ Warning: Failed to apply Rancher registration."
	else
		echo "❌ Could not find valid cluster token for registration."
	fi

	kubectl config use-context "$CLUSTER_MAIN_NAME"
}

# --- VM Creation ---
echo "🖥️ Creating Virtual Machines..."
# Main cluster needs more resources for Rancher (6GB RAM)
VM_RAM=6144 VM_VCPUS=4 sudo -E "$VM_MANAGER" create "$MAIN_VM_NAME" "$HOME/.ssh"
# Edge cluster can stay minimal
sudo "$VM_MANAGER" create "$EDGE_VM_NAME" "$HOME/.ssh"

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
	--ip "$MAIN_IP" \
	--user "$SSH_USER" \
	--ssh-key "$SSH_KEY" \
	--context $CLUSTER_MAIN_NAME \
	--local-path "$HOME/.kube/config" \
	--merge \
	--k3s-extra-args "--disable servicelb"

echo "📦 Installing K3s on $CLUSTER_EDGE_NAME..."
k3sup install \
	--ip "$EDGE_IP" \
	--user "$SSH_USER" \
	--ssh-key "$SSH_KEY" \
	--context $CLUSTER_EDGE_NAME \
	--local-path "$HOME/.kube/config" \
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
until curl -sk "https://$MAIN_IP:6443/livez" >/dev/null; do
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
	argocd_login_with_retries "$MAIN_IP" "$ARGOCD_PORT" "$PASS"
else
	echo "✅ ArgoCD already installed. Re-logging..."
	PASS=$(cat argocd_initial_password.txt 2>/dev/null || echo "")
	if [ ! -z "$PASS" ]; then
		ARGOCD_PORT=$(kubectl -n argocd get svc argocd-server -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
		argocd_login_with_retries "$MAIN_IP" "$ARGOCD_PORT" "$PASS"
	else
		echo "⚠️ No password file found, assuming already logged in or using --core"
		argocd login --core
	fi
fi

# 2.5 CONFIGURE METALLB & REGISTRY

# Install MetalLB on Main (Range .200-.210)
install_metallb "$CLUSTER_MAIN_NAME" "192.168.122" 200 210
# Install MetalLB on Edge (Range .211-.220)
install_metallb "$CLUSTER_EDGE_NAME" "192.168.122" 211 220

# Push registry config
configure_registry_mirror "$MAIN_IP"
configure_registry_mirror "$EDGE_IP"

# 3. Register Clusters with ArgoCD
echo "🔗 Registering clusters with ArgoCD..."
kubectl config use-context "$CLUSTER_MAIN_NAME"

register_cluster_with_retries "$CLUSTER_MAIN_NAME" "$MAIN_TYPE"
register_cluster_with_retries "$CLUSTER_EDGE_NAME" "$EDGE_TYPE"

ARGOCD_PORT=$(kubectl -n argocd get svc argocd-server -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')

# 4. Deploy Root Application
echo "🚀 Deploying ArgoCD Root Application..."
kubectl apply -f ../gitops/root-app.yaml
#
# Wait for registry and broker IPs
echo "⏳ Waiting for internal registry and broker IPs..."
while [ -z "$(kubectl get svc -n default main-cluster-internal-registry -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)" ] ||
	[ -z "$(kubectl get svc -n default main-cluster-mqtt-broker -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)" ]; do sleep 5; done

# Update edge-values.yaml with dynamic broker and registry IPs
BROKER_IP=$(kubectl get svc -n default main-cluster-mqtt-broker -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
REG_IP=$(kubectl get svc -n default main-cluster-internal-registry -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

sed -i "s|repository:.*|repository: $REG_IP:5000/rust-collector|" ../apps-config/edge-values.yaml
sed -i "s|MQTT_BROKER:.*|MQTT_BROKER: \"tcp://$BROKER_IP:1883\"|" ../apps-config/edge-values.yaml
# Update main-values.yaml with dynamic broker and registry IPs
sed -i "s|repository:.*|repository: $REG_IP:5000/golang-api|" ../apps-config/main-values.yaml
sed -i "s|MQTT_BROKER:.*|MQTT_BROKER: \"tcp://$BROKER_IP:1883\"|" ../apps-config/main-values.yaml

# Update host docker daemon
configure_host_registry

# 4.1 Build and push Rust Collector
echo "🏗️ Building and pushing Rust Collector..."
cd ../../rust-collector && make push && cd - >/dev/null

# 5. CONFIGURE REGISTRY MIRROR
# Now that internal-registry is deployed via ArgoCD, we push the config
echo "⏳ Waiting for internal registry IP..."
while [ -z "$(kubectl get svc -n default main-cluster-internal-registry -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)" ]; do sleep 5; done
configure_registry_mirror "$MAIN_IP"
configure_registry_mirror "$EDGE_IP"
#
# 5.1 Re-Deploy Root Application to have collector rust to have updated mqtt IP
echo "🚀 Deploying ArgoCD Root Application..."
kubectl apply -f ../gitops/root-app.yaml

# 6. RANCHER INSTALLATION & IMPORT
echo "🤠 Starting Rancher Setup..."

# Run Rancher steps, but don't fail the whole script if they hit a snag
install_rancher "$CLUSTER_MAIN_NAME" || echo "⚠️ Rancher install issue."
# import_to_rancher "$CLUSTER_EDGE_NAME" || echo "⚠️ Edge import issue."

# Get the final Rancher URL (using LoadBalancer IP)
FINAL_RANCHER_IP=$(kubectl -n cattle-system get svc rancher -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "$MAIN_IP")
RANCHER_URL="https://rancher.$FINAL_RANCHER_IP.sslip.io"

echo "-------------------------------------------------------"
echo "✅ Infrastructure is Ready!"
echo "Contexts: $CLUSTER_MAIN_NAME, $CLUSTER_EDGE_NAME"
echo "Labels:   type=$MAIN_TYPE, type=$EDGE_TYPE"
echo "ArgoCD UI: https://$MAIN_IP:$ARGOCD_PORT"
echo "Rancher UI: $RANCHER_URL (Initial Password: $RANCHER_ADMIN_USER)"
echo "-------------------------------------------------------"
