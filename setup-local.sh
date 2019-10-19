#!/bin/bash
set -euo pipefail

SCRIPT_PATH="$0"
SCRIPT_DIR=$(dirname ${SCRIPT_PATH})
. "${SCRIPT_DIR}/script/common.sh"

KUBECTL=/snap/bin/microk8s.kubectl
echo "Installing snap..."
sudo apt install snapd curl -y
sudo snap install microk8s --classic

if [[ ! -e kustomize ]]; then
  . kustomize-install.sh
fi

. "${SCRIPT_DIR}/script/shared-config.sh"

ARCUS_SUBNET=${ARCUS_SUBNET:-unconfigured}

if [ "$ARCUS_SUBNET" = "unconfigured" ]; then
  echo "Arcus requires a pre-defined subnet for services to be served behind. This subnet must be unallocated (e.g. no IP addresses are used, *and* reserved for static clients)."
  echo "Examples: 192.168.1.200/29, 192.168.1.200-192.168.1.207"
  prompt ARCUS_SUBNET "Please enter your subnet for Arcus services to be exposed on (or set ARCUS_SUBNET): "
fi

cp localk8/metallb.yml overlays/local-production-local/metallb.yml
sed -i "s!PLACEHOLDER_1!$ARCUS_SUBNET!" overlays/local-production-local/metallb.yml

retry 6 check_k8

retry 15 /snap/bin/microk8s.enable dns
/snap/bin/microk8s.enable storage
/snap/bin/microk8s.enable istio

$KUBECTL create namespace cert-manager
$KUBECTL label namespace cert-manager certmanager.k8s.io/disable-validation=true

$KUBECTL apply -f https://raw.githubusercontent.com/google/metallb/v0.8.1/manifests/metallb.yaml
$KUBECTL apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/nginx-0.26.0/deploy/static/mandatory.yaml
$KUBECTL apply -f https://github.com/jetstack/cert-manager/releases/download/v0.10.1/cert-manager.yaml

$KUBECTL apply -f overlays/local-production-local/metallb.yml
$KUBECTL apply -f localk8/cloud-generic.yaml

. "${SCRIPT_DIR}/script/shared-secret.sh"

set +e
$KUBECTL create secret generic shared --from-file secret/
set -e

set +e
$KUBECTL delete configmap logging
$KUBECTL delete configmap extrafiles
$KUBECTL create configmap extrafiles --from-file config/extrafiles
set -e

$KUBECTL label namespace default istio-injection=enabled --overwrite
function apply {
  ./kustomize build overlays/local-production-local/ | $KUBECTL apply -f -
}
retry 10 apply

echo "Setting up schema"
retry 10 $KUBECTL exec cassandra-0 --stdin --tty -- '/bin/sh' '-c' 'CASSANDRA_KEYSPACE=production CASSANDRA_REPLICATION=1 CASSANDRA_HOSTNAME=localhost /usr/bin/cassandra-provision'
kafka_id=$($KUBECTL get pod | grep kafka- | awk '{print $1}')
retry 10 $KUBECTL exec $kafka_id --stdin --tty -- '/bin/sh' '-c' 'KAFKA_REPLICATION=1 KAFKAOPS_REPLICATION=1 kafka-cmd setup'

IPADDRESS=$($KUBECTL describe service -n ingress-nginx | grep 'LoadBalancer Ingress:' | awk '{print $3}')
HUB_IPADDRESS=$($KUBECTL describe service hub-bridge-service | grep 'LoadBalancer Ingress:' | awk '{print $3}')

echo "Done with setup. Please wait a few more minutes for Arcus to start. In the mean time, please make sure you configure your DNS accordingly:"
echo "If these IP addresses are private, you are responsible for setting up port forwarding"
echo "${ARCUS_DOMAIN_NAME}:80 $IPADDRESS:80"
echo "${ARCUS_DOMAIN_NAME}:443 $IPADDRESS:443"
echo "ipcd.${ARCUS_DOMAIN_NAME}:443 $IPADDRESS:443"
echo "admin.${ARCUS_DOMAIN_NAME}:443 $IPADDRESS:443"
echo "hub.${ARCUS_DOMAIN_NAME}:8082 $HUB_IPADDRESS:8082"
