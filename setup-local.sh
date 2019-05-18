#!/bin/bash
set -euo pipefail

echo "Installing snap..."
sudo snap install microk8s --classic

if [[ ! -e kustomize ]]; then
  . kustomize-install.sh
fi

function retry {
  local retries=$1
  shift

  local count=0
  until "$@"; do
    exit=$?
    wait=$((2 ** $count))
    count=$(($count + 1))
    if [ $count -lt $retries ]; then
      echo "Retry $count/$retries exited $exit, retrying in $wait seconds..."
      sleep $wait
    else
      echo "Retry $count/$retries exited $exit, no more retries left."
      return $exit
    fi
  done
  return 0
}

function prompt() {
  local  __resultvar=$1
  echo -n "${2} "
  local  myresult=''
  read myresult
  eval $__resultvar="'$myresult'"
}

ARCUS_ADMIN_EMAIL=${ARCUS_ADMIN_EMAIL:-me@example.com}

if [ "$ARCUS_ADMIN_EMAIL" = "me@example.com" ]; then
  prompt ARCUS_ADMIN_EMAIL "Please enter your admin email address (or set ARCUS_ADMIN_EMAIL): "
fi

cp -r overlays/local-production/ overlays/local-production-local
sed -i "s/me@example.com/$ARCUS_ADMIN_EMAIL/" overlays/local-production-local/cert-provider.yaml

ARCUS_DOMAIN_NAME=${ARCUS_DOMAIN_NAME:-example.com}

if [ "$ARCUS_DOMAIN_NAME" = "example.com" ]; then
  prompt ARCUS_DOMAIN_NAME "Please enter your domain name (or set ARCUS_DOMAIN_NAME): "
fi
cp config/shared-config/config.yml overlays/local-production-local/shared-config.yaml
sed -i "s/arcussmarthome.com/$ARCUS_DOMAIN_NAME/" overlays/local-production-local/shared-config.yaml


ARCUS_SUBNET=${ARCUS_SUBNET:-unconfigured}

if [ "$ARCUS_SUBNET" = "unconfigured" ]; then
  echo "Arcus requires a pre-defined subnet for services to be served behind. This subnet must be unallocated (e.g. no IP addresses are used, *and* reserved for static clients)."
  echo "Examples: 192.168.1.200/29, 192.168.1.200-192.168.1.207"
  prompt ARCUS_SUBNET "Please enter your subnet for Arcus services to be exposed on (or set ARCUS_SUBNET): "
fi
cp localk8/metallb.yml overlays/local-production-local/metallb.yml
sed -i "s!PLACEHOLDER_1!$ARCUS_SUBNET!" overlays/local-production-local/metallb.yml

function check_k8 {
  echo > /dev/tcp/localhost/16443 >/dev/null 2>&1
}

retry 6 check_k8

retry 15 /snap/bin/microk8s.enable dns
/snap/bin/microk8s.enable storage
/snap/bin/microk8s.enable istio
/snap/bin/microk8s.kubectl apply -f https://raw.githubusercontent.com/google/metallb/v0.7.3/manifests/metallb.yaml
/snap/bin/microk8s.kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/mandatory.yaml
/snap/bin/microk8s.kubectl apply -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.7/deploy/manifests/cert-manager.yaml --validate=false

/snap/bin/microk8s.kubectl apply -f overlays/local-production-local/metallb.yml
/snap/bin/microk8s.kubectl apply -f localk8/cloud-generic.yaml

mkdir -p secret
if [[ ! -e secret/billing.api.key ]]; then
  echo "Setting up default secret for billing.api.key"
  echo -n "12345" > secret/billing.api.key
fi

if [[ ! -e secret/billing.public.api.key ]]; then
  echo "Setting up default secret for billing.public.api.key"
  echo -n "12345" > secret/billing.public.api.key
fi

if [[ ! -e secret/iris.aes.iv ]]; then
  echo "Generating secret for iris.aes.iv"
  openssl rand -base64 8 | tr -d '\n' > secret/iris.aes.iv
fi

if [[ ! -e secret/iris.aes.secret ]]; then
  echo "Generating secret for iris.aes.secret"
  openssl rand -base64 32 | tr -d '\n' > secret/iris.aes.secret
fi

if [[ ! -e secret/questions.aes.secret ]]; then
  echo "Generating secret for questions.aes.secret"
  openssl rand -base64 32 | tr -d '\n' > secret/questions.aes.secret
fi

if [[ ! -e secret/smarty.auth.id ]]; then
  echo "Setting up default secret for smarty.auth.id"
  echo -n "12345" > secret/smarty.auth.id
fi

if [[ ! -e secret/smarty.auth.token ]]; then
  echo "Setting up default secret for smarty.auth.token"
  echo -n "12345" > secret/smarty.auth.token
fi

if [[ ! -e secret/tls.server.truststore.password ]]; then
  echo "Using *KNOWN DEFAULT* secret for tls.server.truststore.password"
  # note: the utility of truststore and keystore passwords is quesitonable.
  echo -n "8EFJhxm7aRs2hmmKwVuM9RPSwhNCtMpC" > secret/tls.server.truststore.password
fi

echo "Arcus requires a verified address. In order to verify your address, you will need to create an account on https://smartystreets.com/"
echo "Please go and create an account now, as you will be required to provide some details"
echo "Make sure to create secret keys, since these credentials will only be used on the Arcus server, and never exposed to users"

if [[ ! -e secret/smartystreets.authid ]]; then
  prompt authid "Please enter your smartystreets authid:"
  echo -n "$authid" > secret/smartystreets.authid
fi

if [[ ! -e secret/smartystreets.authtoken ]]; then
  prompt authtoken "Please enter your smartystreets authtoken:"
  echo -n "$authtoken" > secret/smartystreets.authtoken
fi

set +e
/snap/bin/microk8s.kubectl create secret generic shared --from-file secret/
set -e

/snap/bin/microk8s.kubectl label namespace default istio-injection=enabled --overwrite
function apply {
  ./kustomize build overlays/local-production-local/ | /snap/bin/microk8s.kubectl apply -f -
}
retry 10 apply

echo "Setting up schema"
retry 10 /snap/bin/microk8s.kubectl exec cassandra-0 --stdin --tty -- '/bin/sh' '-c' 'CASSANDRA_KEYSPACE=production CASSANDRA_REPLICATION=1 CASSANDRA_HOSTNAME=localhost /usr/bin/cassandra-provision'
kafka_id=$(/snap/bin/microk8s.kubectl get pod | grep kafka- | awk '{print $1}')
retry 10 /snap/bin/microk8s.kubectl exec $kafka_id --stdin --tty -- '/bin/sh' '-c' 'KAFKA_REPLICATION=1 KAFKAOPS_REPLICATION=1 kafka-cmd setup'

IPADDRESS=$(/snap/bin/microk8s.kubectl describe service -n ingress-nginx | grep 'LoadBalancer Ingress:' | awk '{print $3}')
HUB_IPADDRESS=$(/snap/bin/microk8s.kubectl describe service hub-bridge-service | grep 'LoadBalancer Ingress:' | awk '{print $3}')

echo "Done with setup. Please wait a few more minutes for Arcus to start. In the mean time, please make sure you configure your DNS accordingly:"
echo "If these IP addresses are private, you are responsible for setting up port forwarding"
echo "${ARCUS_DOMAIN_NAME}:80 $IPADDRESS:80"
echo "${ARCUS_DOMAIN_NAME}:443 $IPADDRESS:443"
echo "${ARCUS_DOMAIN_NAME}:8082 $HUB_IPADDRESS:8082"
