#!/usr/bin/env bash

set -Eeuo pipefail

# Cleanup on exit
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "========================================="
echo " AWS CLI / kubectl / Helm / eksctl Setup "
echo "========================================="

# Use sudo if not running as root
if [[ $EUID -ne 0 ]]; then
    SUDO="sudo"
else
    SUDO=""
fi

# Detect architecture
case "$(uname -m)" in
    x86_64)
        K8S_ARCH="amd64"
        AWS_ARCH="x86_64"
        ;;
    aarch64|arm64)
        K8S_ARCH="arm64"
        AWS_ARCH="aarch64"
        ;;
    *)
        echo "Unsupported architecture: $(uname -m)"
        exit 1
        ;;
esac

echo "Detected architecture:"
echo "  AWS CLI : ${AWS_ARCH}"
echo "  K8S     : ${K8S_ARCH}"
echo

############################################
# Prerequisites
############################################

echo "Updating package index..."
$SUDO apt-get update

echo "Installing prerequisites..."
$SUDO apt-get install -y \
    curl \
    wget \
    unzip \
    tar \
    ca-certificates \
    gnupg \
    apt-transport-https \
    lsb-release

############################################
# AWS CLI v2
############################################

echo
echo "Installing AWS CLI v2..."

cd "$TMPDIR"

curl -fsSLo awscliv2.zip \
    "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip"

unzip -q awscliv2.zip

if command -v aws >/dev/null 2>&1; then
    $SUDO ./aws/install --update
else
    $SUDO ./aws/install
fi

############################################
# kubectl
############################################

echo
echo "Installing kubectl..."

KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)

curl -fsSLo kubectl \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${K8S_ARCH}/kubectl"

chmod +x kubectl
$SUDO install -m 0755 kubectl /usr/local/bin/kubectl

############################################
# Helm
############################################

echo
echo "Installing Helm..."

curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

############################################
# eksctl
############################################

echo
echo "Installing eksctl..."

PLATFORM="$(uname -s)_${K8S_ARCH}"

curl -fsSL \
"https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_${PLATFORM}.tar.gz" \
| tar -xz -C "$TMPDIR"

$SUDO install -m 0755 "$TMPDIR/eksctl" /usr/local/bin/eksctl

############################################
# Verification
############################################

echo
echo "========================================="
echo " Installed Versions"
echo "========================================="

echo
echo "AWS CLI"
aws --version

echo
echo "kubectl"
kubectl version --client

echo
echo "Helm"
helm version --short

echo
echo "eksctl"
eksctl version

echo
echo "========================================="
echo "Installation complete."
echo "========================================="