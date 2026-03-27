#!/bin/bash

# ==============================================================================
# bootstrap/install-deps.sh
# Run this on your central VM (openSUSE Tumbleweed) to prepare for GitOps.
# ==============================================================================

echo "🛠️  Starting dependency installation for openSUSE Tumbleweed..."

# 1. Install System Tools via Zypper
# curl: for downloading binaries
# helm: for package management
# jq: for processing JSON (helpful for ArgoCD CLI)
sudo zypper refresh
sudo zypper install -y curl helm jq git

# 2. Install k3sup (The Provisioner)
if ! command -v k3sup &>/dev/null; then
	echo "📥 Installing k3sup..."
	curl -sLS https://get.k3sup.dev | sh
	sudo install k3sup /usr/local/bin/
else
	echo "✅ k3sup already installed."
fi

# 3. Install ArgoCD CLI (The Management Tool)
if ! command -v argocd &>/dev/null; then
	echo "📥 Installing ArgoCD CLI..."
	ARGO_VERSION=$(curl --silent "https://api.github.com/repos/argoproj/argo-cd/releases/latest" | jq -r .tag_name)
	sudo curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/download/$ARGO_VERSION/argocd-linux-amd64
	sudo chmod +x /usr/local/bin/argocd
else
	echo "✅ ArgoCD CLI already installed."
fi

echo "-------------------------------------------------------"
echo "🚀 Environment Ready!"
echo "-------------------------------------------------------"
echo "Next Steps (Manual once clusters are up):"
echo "1. Install ArgoCD on Main Cluster:"
echo "   helm repo add argo https://argoproj.github.io/argo-helm"
echo "   helm install argocd argo/argo-cd --namespace argocd --create-namespace"
echo ""
echo "2. Register your Edge cluster:"
echo "   argocd cluster add <context-name> --name edge-01 --label type=edge"
