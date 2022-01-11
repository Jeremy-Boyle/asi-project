# Create Bootstrap Cluster
## Provision two machine a Control plane and Worker Nodes (Ubuntu 20.04, Kubernetes: v1.23.1)

1. ### Update the machine
    ```bash
    sudo apt-get update
    sudo apt-get upgrade -y
    sudo apt-get install -y apt-transport-https ca-certificates curl containerd
    ```
2. ### Install kubernetes repo and keyring
    ```bash
    sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
    echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    sudo apt-get update
    ```
3. ### Install Kubernetes
    ```bash
    sudo apt-get install -y kubelet kubeadm kubectl
    ```
4. ### Configure modprobe for networking
    ```bash
    sudo cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
    overlay
    br_netfilter
    EOF

    sudo modprobe overlay
    sudo modprobe br_netfilter
    ```
5. ### Setup required sysctl params, these persist across reboots.
    ```bash
    cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
    net.bridge.bridge-nf-call-iptables  = 1
    net.ipv4.ip_forward                 = 1
    net.bridge.bridge-nf-call-ip6tables = 1
    EOF
    ```
6. ### Apply sysctl params without reboot
    ```bash
    sudo sysctl --system
    ```

7. ### Setup Containerd
    ```bash
    sudo mkdir -p /etc/containerd
    containerd config default | sudo tee /etc/containerd/config.toml
    ```
8. ### Enable SystemCgrouping
    ```bash
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    sudo systemctl enable --now containerd
    ```
9. Configure Nodes

- ### Control Plane Only
    ```bash
    sudo kubeadm init --pod-network-cidr=10.244.0.0/16
    or
    sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-cert-extra-sans public_ip_here
    ```

- ### Worker Only
    ```bash
    sudo kubeadm join (get command from output on the control plane after the init process)
    ```
- ### For Single Node Bootstrap run
    ```bash
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
    kubectl taint nodes --all node-role.kubernetes.io/master-

    ```
    Cat the kubeconfig for external use and save it on local machine
    ```
    cat ~/.kube/config
    ```

10. ### Calico
    Install calico on the bootstrap cluster otherwise you wont be able create pods on the bootstrap cluster
    ```bash
    kubectl apply -f deploy/apps/calico
    ```

11. ### ClusterApi
    Install: https://github.com/kubernetes-sigs/cluster-api/releases/
    ```bash
    clusterctl init --infrastructure openstack
    ```

## Bootstraping actual mgt cluster

1. ### Create the namespace and create the mgt cluster
    ```bash
    kubectl create ns kapp-controller
    kapp deploy -a platform-ops-mgt-cluster-ctrl -n kapp-controller -f <(sops -d deploy/cluster/secrets/mgt-cluster-secret.platform-ops.sops.yaml | yq e '.stringData."00-values.yaml"' - | ytt --ignore-unknown-comments -f - -f deploy/cluster/manifests )
    ```
2. ### Wait for cluster to be created
    ```bash
    watch clusterctl describe cluster platform-ops-mgt -n platform-ops
    ```
3. ### Save cluster kubeconfig before migration
    ```bash
    clusterctl get kubeconfig -n platform-ops platform-ops-mgt > mgt-cluster.kubeconfig
    ```
4. ### Install Calico on the mgt cluster
    ```bash
    kapp deploy -a platform-ops-mgt-calico-ctrl --kubeconfig mgt-cluster.kubeconfig -f deploy/apps/calico
    ```
5. ### Install Kapp-controller on mgt cluster
    ```bash
    kapp deploy --kubeconfig mgt-cluster.kubeconfig -a kapp-controller -n kube-system -f https://github.com/vmware-tanzu/carvel-kapp-controller/releases/latest/download/release.yml -f deploy/apps/kapp-controller/
    ```
6. ### Create mgt namespace
    ```bash
    kubectl create ns platform-ops
    ```
7. ### Move over the kubeconfig for the mgt cluster on the mgt cluster
    ```bash
    kubectl --kubeconfig mgt-cluster.kubeconfig create secret generic platform-ops-mgt-kubeconfig -n platform-ops --from-file=value=<(kubectl get secrets -n platform-ops platform-ops-mgt-kubeconfig -o=go-template='{{.data.value|base64decode}}')
    ```
7. ### Install Cert-manager on mgt cluster with kapp-controller
    ```bash
    kubectl --kubeconfig mgt-cluster.kubeconfig create ns cert-manager

    kubectl --kubeconfig mgt-cluster.kubeconfig apply -f <(ytt --ignore-unknown-comments --data-value cluster_name=platform-ops-mgt --data-value namespace=platform-ops -f deploy/apps/common/cert-manager-app-cr.yaml)
    ```
8. ### Move kapp deploy config over to new cluster
    ```
    kubectl get cm -n kapp-controller platform-ops-mgt-cluster-ctrl -o yaml | kubectl --kubeconfig mgt-cluster.kubeconfig apply -f -
    ```
9. ### Migrate cluster with clustetctl
    ```
    clusterctl move --to-kubeconfig=mgt-cluster.kubeconfig --namespace platform-ops
    ```
8. ### Bootstrap The MGT Keys
    ```
    for key in $(ls deploy/bootstrap/keys | grep 'sops.yaml');do sops -d deploy/bootstrap/keys/$key | kubectl apply -f - ; done
    ```

9. # Openstack Only
    ```
    ytt -f deploy/apps/openstack-cloud-controller/manifests/ -f deploy/apps/cinder-csi-plugin/manifests | kapp deploy --kubeconfig mgt-cluster.kubeconfig -a platform-ops-mgt-openstack-controllers-ctl -n platform-ops -f - -y
    ```