#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="k8s-dev"
NETWORK_NAME="kind-network"
CONFIG_FILE="./kind-cluster-temp.yaml"

# Check if Docker is installed
if ! command -v docker &>/dev/null; then
    echo "❌ Docker is not installed. Please install Docker and try again."
    exit 1
fi

# Check if jq is installed
if ! command -v jq &>/dev/null; then
    echo "❌ jq is not installed. Please install jq and try again."
    exit 1
fi

echo "✅ All dependencies are installed (docker, jq)."


# 1️⃣ Download latest kubectl binary
echo "Downloading latest kubectl..."
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" &>/dev/null

# 2️⃣ Make it executable
chmod +x kubectl

# 3️⃣ Move to a directory in PATH
sudo mv kubectl /usr/local/bin/kubectl

# 5️⃣ Set up bash completion
echo "Setting up bash completion..."
kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl > /dev/null

# 6️⃣ Enable bash completion for current session
if ! grep -q 'bash_completion' <<< "$BASH_SOURCE"; then
    echo '[[ $PS1 && -f /etc/bash_completion ]] && . /etc/bash_completion' >> ~/.bashrc
fi
source /etc/bash_completion
source ~/.bashrc

echo "✅ kubectl installed and bash completion enabled!"

echo

# -----------------------------
# 1️⃣ Install kind
# -----------------------------
KIND_VERSION=$(curl -s https://api.github.com/repos/kubernetes-sigs/kind/releases/latest | jq -r .tag_name)
echo "Downloading kind $KIND_VERSION..."
curl -Lo ./kind "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64" &>/dev/null
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# create a new docker network
if [ -n "$NETWORK_NAME" ]; then
  docker network create $NETWORK_NAME
fi

# -----------------------------
# 2️⃣ Detect all IPv4 addresses
# -----------------------------
echo "Detecting all IPv4 addresses..."
IP_ADDRESSES=$(ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | sort -u)

echo "Found IPs:"
echo "$IP_ADDRESSES"

# Generate YAML list of SANs
SAN_LIST=""
while read -r ip; do
  SAN_LIST+="            - \"$ip\"\n"
done <<< "$IP_ADDRESSES"

# -----------------------------
# 3️⃣ Generate kind cluster config
# -----------------------------

cat > "$CONFIG_FILE" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: ClusterConfiguration
        apiServer:
          certSANs:
$(echo -e "$SAN_LIST")
    extraPortMappings:
      - containerPort: 6443
        hostPort: 6443
        listenAddress: "0.0.0.0"
        protocol: TCP
EOF

echo "Generated kind config file at $CONFIG_FILE:"
cat "$CONFIG_FILE"

# -----------------------------
# 4️⃣ Create the cluster
# -----------------------------

echo "Creating kind cluster '$CLUSTER_NAME'..."
kind create cluster --name "$CLUSTER_NAME" --config "$CONFIG_FILE"

if [ -n "$NETWORK_NAME" ]; then
  NETWORK_IP=$(docker network inspect $NETWORK_NAME -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' | cut -d'/' -f1 | awk '{print $1}' | sed 's/\.0$/\.1/')

  docker network connect $NETWORK_NAME ${CLUSTER_NAME}-control-plane
else
  NETWORK_IP="127.0.0.1"
fi

kind get kubeconfig --name $CLUSTER_NAME | sed "s/0.0.0.0/$NETWORK_IP/g" > ~/.kube/config


kubectl get namespaces


