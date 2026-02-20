#!/bin/bash
set -euo pipefail

METALLB_VERSION='v0.15.3'
NGINX_VERSION='v1.14.3'
CERT_MANAGER_VERSION='v1.19.2'
ISTIO_VERSION='1.26.0'

SCRIPT_PATH="$0"
SCRIPT_DIR=$(dirname "${SCRIPT_PATH}")
. "${SCRIPT_DIR}/script/common.sh"
. "${SCRIPT_DIR}/script/funcs.sh"

# setup

if ! ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
  echo "Couldn't get root of git repository. You must checkout arcus-k8s as a git repository, not as an extracted zip."
  exit 1
fi

ARCUS_CONFIGDIR="${ROOT}/.config"
mkdir -p $ARCUS_CONFIGDIR

KUBECTL=${KUBECTL:-kubectl}

DEPLOYMENT_TYPE=cloud

if [ -x "$(command -v k3s)" ]; then
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
  killall    - Deletes all Arcus pods, triggering their controllers to reschedule them.
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
    DEPLOYMENT_TYPE=local
    setup_k3s
    setup_helm
    setup_istio
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
  logs "${@:2}"
  ;;
shell)
  shell_exec "${@:2}"
  ;;
dbshell)
  shell_exec cassandra /opt/cassandra/bin/cqlsh localhost
  ;;
deletepod)
  delete "${@:2}"
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
