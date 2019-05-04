#!/bin/bash
set -euo pipefail

sudo snap install microk8s --classic

/snap/bin/microk8s.enable dns
/snap/bin/microk8s.enable storage
/snap/bin/microk8s.kubectl apply -f https://raw.githubusercontent.com/google/metallb/v0.7.3/manifests/metallb.yaml
/snap/bin/microk8s.kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/mandatory.yaml
/snap/bin/microk8s.kubectl apply -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.7/deploy/manifests/cert-manager.yaml --validate=false

. kustomize-install.sh

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

if [[ ! -e secret/iris.aes.iv ]]; then
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

./kustomize build overlays/local-production/ | /snap/bin/microk8s.kubectl apply -f -

echo "Setting up schema"
/snap/bin/microk8s.kubectl exec cassandra-0 --stdin --tty -- '/bin/sh' '-c' 'CASSANDRA_KEYSPACE=production CASSANDRA_REPLICATION=1 /usr/bin/cassandra-provision'
