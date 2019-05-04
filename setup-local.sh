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

cp -r overlays/local-production overlays/local-production-local
sed -i "s/me@example.com/$ARCUS_ADMIN_EMAIL/" overlays/local-production-local/cert-provider.yaml

function check_k8 {
  echo > /dev/tcp/localhost/16443 >/dev/null 2>&1
}

retry 6 check_k8

retry 15 /snap/bin/microk8s.enable dns
/snap/bin/microk8s.enable storage
/snap/bin/microk8s.kubectl apply -f https://raw.githubusercontent.com/google/metallb/v0.7.3/manifests/metallb.yaml
/snap/bin/microk8s.kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/mandatory.yaml
/snap/bin/microk8s.kubectl apply -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.7/deploy/manifests/cert-manager.yaml --validate=false

/snap/bin/microk8s.kubectl apply -f localk8/metallb.yml
/snap/bin/microk8s.kubectl apply -f localk8/cloud-generic.yaml

mkdir -p secret
if [[ ! -e secret/billing.api.key ]]; then
  echo "Setting up default secret for billing.api.key"
  echo "12345" > secret/billing.api.key
fi

if [[ ! -e secret/billing.public.api.key ]]; then
  echo "Setting up default secret for billing.public.api.key"
  echo "12345" > secret/billing.public.api.key
fi

if [[ ! -e secret/iris.aes.iv ]]; then
  echo "Generating secret for iris.aes.iv"
  openssl rand -hex 8 > secret/iris.aes.iv
fi

if [[ ! -e secret/iris.aes.secret ]]; then
  echo "Generating secret for iris.aes.secret"
  openssl rand -hex 32 > secret/iris.aes.secret
fi

if [[ ! -e secret/questions.aes.secret ]]; then
  echo "Generating secret for questions.aes.secret"
  openssl rand -hex 32 > secret/questions.aes.secret
fi

if [[ ! -e secret/smarty.auth.id ]]; then
  echo "Setting up default secret for smarty.auth.id"
  echo "12345" > secret/smarty.auth.id
fi

if [[ ! -e secret/smarty.auth.token ]]; then
  echo "Setting up default secret for smarty.auth.token"
  echo "12345" > secret/smarty.auth.token
fi

if [[ ! -e secret/tls.server.truststore.password ]]; then
  echo "Using *KNOWN DEFAULT* secret for tls.server.truststore.password"
  # note: the utility of truststore and keystore passwords is quesitonable.
  echo "8EFJhxm7aRs2hmmKwVuM9RPSwhNCtMpC" > secret/tls.server.truststore.password 
fi

set +e
/snap/bin/microk8s.kubectl create secret generic shared --from-file secret/
set -e

function apply {
  ./kustomize build overlays/local-production-local/ | /snap/bin/microk8s.kubectl apply -f -
}
retry 10 apply

echo "Setting up schema"
retry 10 /snap/bin/microk8s.kubectl exec cassandra-0 --stdin --tty -- '/bin/sh' '-c' 'CASSANDRA_KEYSPACE=production CASSANDRA_REPLICATION=1 /usr/bin/cassandra-provision'

IPADDRESS=$(/snap/bin/microk8s.kubectl describe service -n ingress-nginx | grep 'LoadBalancer Ingress:' | awk '{print $3}')
echo "Done with setup. Please wait a few more minutes for Arcus to start. In the mean time, please make sure you configure your DNS accordingly:"
echo "dev.arcus.wl-net.net A $IPADDRESS"
