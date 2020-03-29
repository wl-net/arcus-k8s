#!/bin/bash
set -euo pipefail

METALLB_VERSION='v0.9.3'
NGINX_VERSION='0.30.0'
CERT_MANAGER_VERSION='v0.14.0'
ISTIO_VERSION='1.4.6'

SCRIPT_PATH="$0"
SCRIPT_DIR=$(dirname ${SCRIPT_PATH})
. "${SCRIPT_DIR}/script/common.sh"
. "${SCRIPT_DIR}/script/funcs.sh"

# setup

set +e
ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
RESULT=$?
if [ $RESULT -ne 0 ]; then
  echo "Couldn't get root of git repository. You must checkout arcus-k8 as a git repository, not as an extracted zip."
  exit $RESULT
fi
set -e

ARCUS_CONFIGDIR="${ROOT}/.config"
mkdir -p $ARCUS_CONFIGDIR

KUBECTL=${KUBECTL:-kubectl}

DEPLOYMENT_TYPE=cloud

if [ -x "$(command -v microk8s.kubectl)" ]; then
  KUBECTL=microk8s.kubectl
  DEPLOYMENT_TYPE=local
fi

function print_available() {
  cat <<ENDOFDOC
arcuscmd: manage your arcus deployment

Setup Commands:
  setup        - setup a new instance of Arcus
  setupmetrics - setup grafana metrics
  configure    - configure Arcus by answering a few questions
  install      - install kubernetes components (e.g. cert-manager)

Basic Commands:
  apply      - apply the existing configured configuration
  deploy     - deploy arcus (rolling the entire fleet, 1 service at a time)
  update     - update your local copy with the latest changes
  deletepod  - delete pods matching an application
  backupdb   - backup cassandra
  logs       - shows logs of a running container

Debug Commands:
  logs       - get the logs for an application
  dbshell    - Get a shell (cqlsh) on the database

Dangerous Commands:
  killall    - Immediately kills all running deployments / statefulsets.
ENDOFDOC

}

cmd=${1:-help}

case "$cmd" in
setup)
  prompt answer "Setup Arcus on this machine, or in the cloud: [local/cloud]:"
  if [[ $answer != 'cloud' && $answer != 'local' ]]; then
    echo "Invalid option $answer, must pick 'local' or 'cloud'"
    exit 1
  fi

  if [[ $answer == 'local' ]]; then
    prompt answer "Do you want to use microk8s or k3s? [microk8s/k3s]:"
    if [[ $answer != 'microk8s' && $answer != 'k3s' ]]; then
      echo "Invalid option $answer, must pick 'local' or 'cloud'"
      exit 1
    fi

    DEPLOYMENT_TYPE=local

    if [[ $answer == 'k3s' ]]; then
      setup_k3s
      setup_helm
      setup_istio
    else
      setup_microk8s
    fi

    install
    configure
    apply
    provision
    info
  fi
  ;;
setupmetrics)
  setup_metrics
  ;;
apply)
  apply
  ;;
provision)
  provision
  ;;
installk3s)
  setup_k3s
  ;;
installmicrok8s)
  setup_microk8s
  ;;
install)
  install
  ;;
configure)
  configure
  ;;
deploy)
  deploy_platform
  ;;
deployfast)
  deployfast
  ;;
killall)
  killallpods
  ;;
updatehubkeystore)
  updatehubkeystore
  ;;
modelmanager)
  runmodelmanager
  ;;
useprodcert)
  useprodcert
  ;;
info)
  info
  ;;
update)
  update
  ;;
logs)
  logs $*
  ;;
dbshell)
  $KUBECTL exec --stdin --tty cassandra-0 /bin/bash -- /opt/cassandra/bin/cqlsh localhost
  ;;
deletepod)
  delete $*
  ;;
backupdb)
  backup_cassandra
  ;;
status)
  arcus_status
  ;;
help)
  print_available
  ;;
*)
  echo "Unsupported Command: $cmd"
  echo
  print_available
  ;;
esac
