# Create Bootstrap Cluster
## Provision one instance for the Control plane and one instance for the Worker Nodes (Ubuntu 20.04, Kubernetes: v1.23.1)

#### Note: For *AWS* you will need to create a instance and attach the control plane iam, and the node iam, additionally you must provision two instances for *AWS* due to kiam

#### Note: For *openstack* you only need a single instance to bootstrap
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
    kubectl --kubeconfig /etc/kubernetes/kubelet.conf label node $HOST node-role.kubernetes.io/worker= --overwrite=true
    ```
- ### For Single Node Bootstrap run (Openstack ONLY)
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
    kubectl apply -f apps/calico/manifests
    ```
11. ### Install Kiam on bootstrap cluster (AWS ONLY)
    ```bash
    helm repo add bitnami https://charts.bitnami.com/bitnami
    kubectl create ns kiam
    kubectl apply -f <(helm template kiam bitnami/kiam -f <(cat apps/common/shared/kiam-app-cr.yaml | yq e '.stringData."values.yaml"' - | yq -f extract e '' -) --dry-run | ytt --ignore-unknown-comments -f - -f apps/kiam/manifests/overlay.yaml)
    ```
12. ### ClusterApi
    ```bash
    kubectl apply -f apps/cluster-api/capi/manifests -f apps/cluster-api/capa/manifests -f apps/cluster-api/capo/manifests
    ```
## Creating a AMI
1. ### Pull down the AMI creation repo on to the AWS instance
    ```bash
    git clone https://github.com/Jeremy-Boyle/image-builder -b ubuntu-1804-dod-asi
    cd image-builder/images/capi
    ```
2. ### Install prerequisites
    ```bash
    sudo apt update && sudo apt install make build-essential pip unzip awscli -y
    export PATH=$PATH:~/.local/bin/
    make deps-ami
    ```
3. ### Configure AWS config file for packer
    ```bash
    mkdir -p .aws
    cat <<EOF | tee ~/.aws/config
    [default]
    region = us-gov-east-1
    ```
4. ### Configure packer
    ```bash
    sed -i 's/"ami_groups": "all"/"ami_groups": ""/g' packer/ami/packer.json
    sed -i 's/"snapshot_groups": "all"/"snapshot_groups": ""/g' packer/ami/packer.json
    sed -i 's/"encrypted": "false"/"encrypted": "true"/g' packer/ami/packer.json
    sed -i 's/"kms_key_id": ""/"kms_key_id": "REPLACE_ME_WITH_KMS_ID"/g' packer/ami/packer.json
    ```
4. ### Build DOD AMI
    ```bash
    make build-ami-ubuntu-1804-dod
    ```
## Creating a Openstack qCow raw image
1. ### Pull down the image builder repo on the instance / local machines *Note:* this wont work on amazon due to needing nested KVM
    ```bash
    git clone https://github.com/Jeremy-Boyle/image-builder -b ubuntu-1804-dod-asi
    cd image-builder/images/capi
    ```
2. ### Install prerequisites
    ```bash
    sudo apt update && sudo apt install make build-essential pip unzip qemubuilder qemu-kvm libvirt-daemon-system libvirt-clients virtinst cpu-checker libguestfs-tools libosinfo-bin -y
    export PATH=$PATH:~/.local/bin/
    make deps-qemu
    ```
3. ### Setup KVM
    ```bash
    sudo usermod -a -G kvm $USER
    sudo systemctl enable --now libvirtd
    sudo systemctl enable --now virtlogd
    sudo modprobe kvm
    sudo modprobe kvm_intel
    sudo chown root:kvm /dev/kvm
    ```
3. ### Build DOD image for openstack
    ```bash
    make build-qemu-ubuntu-1804-dod
    ```
4. ### SCP copy the iso image to the openstack server and import with openstack
    ```bash
    scp output/IMAGE_FOLDER/IMAGE_NAME USERNAME@IP_ADDRESS:~/DEST
    openstack image create \
        --container-format bare \
        --disk-format qcow2 \
        --property hw_disk_bus=scsi \
        --property hw_scsi_model=virtio-scsi \
        --property os_type=linux \
        --property os_distro=ubuntu \
        --property os_admin_user=ubuntu \
        --property os_version='18.04' \
        --public \
        --file IMAGE_NAME \
        IMAGE_NAME
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
    kapp deploy --kubeconfig mgt-cluster.kubeconfig -a kapp-controller -n kube-system -f https://github.com/vmware-tanzu/carvel-kapp-controller/releases/latest/download/release.yml -f apps/kapp-controller/manifests
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

    kubectl --kubeconfig mgt-cluster.kubeconfig apply -f <(ytt --ignore-unknown-comments --data-value cluster_name=platform-ops-mgt --data-value namespace=platform-ops -f apps/common/shared/cert-manager-app-cr.yaml)
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
    ytt -f apps/openstack-cloud-controller/manifests/ -f apps/cinder-csi-plugin/manifests | kapp deploy --kubeconfig mgt-cluster.kubeconfig -a platform-ops-mgt-openstack-controllers-ctl -n platform-ops -f - -y
    ```