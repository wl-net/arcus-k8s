#!/bin/bash
set -euo pipefail

SCRIPT_PATH="$0"
SCRIPT_DIR=$(dirname ${SCRIPT_PATH})
. "${SCRIPT_DIR}/script/common.sh"

KUBECTL=/snap/bin/microk8s.kubectl

if [[ ! -e kustomize ]]; then
  . kustomize-install.sh
fi

$KUBECTL apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/mandatory.yaml
$KUBECTL apply -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.7/deploy/manifests/cert-manager.yaml --validate=false

. "${SCRIPT_DIR}/script/shared-config.sh"

. "${SCRIPT_DIR}/script/shared-secret.sh"

$KUBECTL label namespace default istio-injection=enabled --overwrite
function apply {
  ./kustomize build overlays/local-production-local/ | $KUBECTL apply -f -
}
retry 10 apply

