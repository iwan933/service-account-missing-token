#!/bin/bash

CONTAINERD_VERSION="1.6.4"
RUNC_VERSION="1.1.1"
CNI_PLUGINS_VERSION="1.1.1"
KUBERNETES_DASHBOARD_VERSION="2.5.1"
POD_NETWORK_CIDR="192.168.0.0/16"
SONOBUOY_VERSION="0.56.6"
NODE_NAME="k8s-test-control-node"

echo "Disabling swap (https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)"
sudo swapoff -a

if [[ -z "$CONTROL_PLANE_HOST" ]]; then
    echo "Please set the CONTROL_PLANE_HOST environment variable."
    exit 1
fi

echo "Update package information"
sudo apt update && sudo apt upgrade -y

echo "Install development tools"
sudo apt install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    python3-pip

sudo pip3 install toml==0.10.2

echo "Configuring system networking for k8s"
sudo apt update & sudo apt upgrade -y
sudo apt install ufw

sudo ufw allow ssh
sudo ufw --force enable

sudo ufw allow 179/tcp
sudo ufw allow 4789/tcp
sudo ufw allow 5473/tcp
sudo ufw allow 443/tcp
sudo ufw allow 6443/tcp
sudo ufw allow 2379/tcp
sudo ufw allow 4149/tcp
sudo ufw allow 10250/tcp
sudo ufw allow 10255/tcp
sudo ufw allow 10256/tcp
sudo ufw allow 9099/tcp

sudo ufw status

echo "Configuring system for containerd"
cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Setup required sysctl params, these persist across reboots.
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system

echo "Install containerd into /usr/local"

curl -fsSLO https://github.com/containerd/containerd/releases/download/v1.6.4/containerd-1.6.4-linux-amd64.tar.gz
sudo tar Cxzvf /usr/local containerd-$CONTAINERD_VERSION-linux-amd64.tar.gz

sudo mkdir -p /usr/local/lib/systemd/system
sudo curl -fsSLo /usr/local/lib/systemd/system/containerd.service https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
sudo systemctl daemon-reload
sudo systemctl enable --now containerd

curl -fsSLO https://github.com/opencontainers/runc/releases/download/v$RUNC_VERSION/runc.amd64
sudo install -m 755 runc.amd64 /usr/local/sbin/runc

curl -fsSLO https://github.com/containernetworking/plugins/releases/download/v$CNI_PLUGINS_VERSION/cni-plugins-linux-amd64-v$CNI_PLUGINS_VERSION.tgz
sudo mkdir -p /opt/cni/bin
sudo tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.1.1.tgz

sudo mkdir -p /etc/containerd
sudo containerd config default > default-config.toml

python3 << END
import toml

with open("default-config.toml", "r") as f:
    data = toml.load(f)
data["plugins"]["io.containerd.grpc.v1.cri"]["containerd"]["runtimes"]["runc"]["options"]["SystemdCgroup"] = True
with open("/etc/containerd/config.toml", "w") as f:
    toml.dump(data, f)
END

sudo systemctl restart containerd

echo "Add Kubernetes repository repository to apt"
sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list

echo "Installing kubernetes components"
sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Set iptables bridging
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
sudo echo '1' > /proc/sys/net/ipv4/ip_forward
sudo sysctl --system

echo "Initializing cluster"
kubeadm init --config /vagrant/kubeadm-config.yaml --control-plane-endpoint $CONTROL_PLANE_HOST --pod-network-cidr=$POD_NETWORK_CIDR --node-name $NODE_NAME

echo "Install bash completion."
sudo apt install bash-completion

echo 'source <(kubectl completion bash)' >>~/.bashrc
#source /usr/share/bash-completion/bash_completion
kubectl completion bash >/etc/bash_completion.d/kubectl

echo 'Allowing kubectl execution with current user'
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo "Deploying CNI to cluster"
kubectl apply -f /vagrant/calico.yaml

echo "Allowing control plane to act as worker node"
kubectl taint nodes --all node-role.kubernetes.io/control-plane- node-role.kubernetes.io/master-

while [[ $(kubectl get pods -l k8s-app=calico-kube-controllers -n kube-system -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do
    echo "Waiting for calico kube controller to be ready"
    sleep 3
done

kubectl get pods -n kube-system

echo "Deploying kubernetes dashboard"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v$KUBERNETES_DASHBOARD_VERSION/aio/deploy/recommended.yaml

echo "Adding admin user for dashboard"
kubectl apply -f /vagrant/dashboard-adminuser.yaml
kubectl apply -f /vagrant/dashboard-adminrolebinding.yaml

echo "Installing helm"
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get-helm-3 > get_helm.sh
chmod 700 get_helm.sh
./get_helm.sh

echo "Adding bitnami repo to helm"
helm repo add bitnami https://charts.bitnami.com/bitnami

echo "Installing sonobuoy to run cluster health tests"
curl -fsSLO https://github.com/vmware-tanzu/sonobuoy/releases/download/v${SONOBUOY_VERSION}/sonobuoy_${SONOBUOY_VERSION}_linux_amd64.tar.gz
sudo tar -xzvf sonobuoy_${SONOBUOY_VERSION}_linux_amd64.tar.gz
mv sonobuoy /usr/local/bin/sonobuoy
