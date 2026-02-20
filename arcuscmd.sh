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
mkdir -p "$ARCUS_CONFIGDIR"

KUBECTL=${KUBECTL:-kubectl}

DEPLOYMENT_TYPE=cloud

if [ -x "$(command -v k3s)" ]; then
  DEPLOYMENT_TYPE=local
fi

if [[ ${1:-help} != 'help' && ${1:-help} != 'setup' && ${1:-help} != 'configure' && ${1:-help} != 'verifyconfig' ]]; then
  if ! command -v "$KUBECTL" &>/dev/null; then
    echo "Error: kubectl not found. Is it installed and in your PATH?"
    exit 1
  fi
fi

function print_available() {
  cat <<ENDOFDOC
arcuscmd: manage your arcus deployment

Setup Commands:
  setup          - setup a new instance of Arcus
  installk3s     - install k3s on this machine
  setupmetrics   - setup grafana metrics
  configure      - configure Arcus by answering a few questions
  install        - install/upgrade kubernetes components (MetalLB, nginx-ingress, cert-manager)
  useprodcert    - switch from Let's Encrypt staging to production certificate
  updatehubkeystore - convert production TLS key to PKCS#8 for hub-bridge

Basic Commands:
  apply      - apply the existing configured configuration
  deploy     - deploy arcus (rolling the entire fleet, 1 service at a time)
  update     - update your local copy with the latest changes
  deletepod  - delete pods matching an application
  backupdb   - backup cassandra
  backupconfig - backup local configuration (.config, secrets, overlays) to a tarball
  verifyconfig - verify that all configuration and secrets are present
  status     - show status of services, certificates, and infrastructure versions
  versions   - show installed vs configured infrastructure versions
  info       - show DNS to IP/port mappings
  check      - test public connectivity to Arcus services

Debug Commands:
  logs       - get the logs for an application
  certlogs   - get the logs for cert-manager (optionally: webhook, cainjector)
  shell      - get an interactive shell on a pod
  dbshell    - get a cqlsh shell on the Cassandra database

Dangerous Commands:
  killall    - Deletes all Arcus pods, triggering their controllers to reschedule them.
ENDOFDOC

}

subcmd=${1:-help}

case "$subcmd" in
setup)
  answer=''
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
  else
    echo "For cloud deployments, ensure kubectl is configured to point at your cluster, then run:"
    echo "  ./arcuscmd.sh install"
    echo "  ./arcuscmd.sh configure"
    echo "  ./arcuscmd.sh apply"
    echo "  ./arcuscmd.sh provision"
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
check)
  connectivity_check
  ;;
update)
  update
  ;;
logs)
  logs "${@:2}"
  ;;
certlogs)
  certlogs "${@:2}"
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
backupconfig)
  backup_config
  ;;
verifyconfig)
  verify_config
  ;;
status)
  arcus_status
  ;;
versions)
  infra_versions
  ;;
help)
  print_available
  ;;
*)
  echo "Unsupported Command: $subcmd"
  echo
  print_available
  ;;
esac
