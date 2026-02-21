#!/bin/bash
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "Error: Do not run arcuscmd as root. Commands that need elevated privileges will use sudo."
  exit 1
fi

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

if [[ ${1:-help} != 'help' && ${1:-help} != 'setup' && ${1:-help} != 'configure' && ${1:-help} != 'verifyconfig' && ${1:-help} != 'shell-setup' && ${1:-help} != 'validate' ]]; then
  if ! command -v "$KUBECTL" &>/dev/null; then
    echo "Error: kubectl not found. Is it installed and in your PATH?"
    exit 1
  fi
fi

function print_available() {
  cat <<ENDOFDOC
arcuscmd: manage your arcus deployment

Setup:
  setup               Setup a new instance of Arcus
  installk3s          Install k3s on this machine
  install             Install/upgrade kubernetes components (MetalLB, nginx-ingress, cert-manager)
  configure           Configure Arcus by answering a few questions
  shell-setup         Add 'arcuscmd' shortcut to your shell config

Deploy:
  apply               Apply the current configuration to the cluster
  deploy [svc...]       Rolling restart of services (all if none specified)
                          --pull  Force re-pull images before restarting
  update              Pull latest changes and show what changed
  rollback            Revert to a previous version
  history             Show recent update history
  useprodcert         Switch from Let's Encrypt staging to production certificate
  updatehubkeystore   Convert production TLS key to PKCS#8 for hub-bridge

Status:
  status              Show services, certificates, and infrastructure versions
  versions            Show installed vs configured infrastructure versions
  info                Show DNS to IP/port mappings
  check               Test public connectivity to Arcus services
  validate            Validate YAML syntax, kustomize build, and Kubernetes schemas
  verifyconfig        Verify that all configuration and secrets are present

Operations:
  backupdb            Snapshot and backup Cassandra database
  restoredb <file>    Restore Cassandra from a snapshot backup
  restoredb-full <file>  Full Cassandra restore (destructive, replaces data dir)
  backupconfig        Backup local configuration to a tarball
  setupmetrics        Setup Grafana metrics
  deletepod           Delete pods matching an application
  logs                Get logs for an application
  certlogs            Get logs for cert-manager (optionally: webhook, cainjector)
  shell               Get an interactive shell on a pod
  dbshell             Open a Cassandra CQL shell

Dangerous:
  killall             Delete all Arcus pods, triggering a full reschedule
ENDOFDOC

}

subcmd=${1:-help}

case "$subcmd" in
setup)
  check_prerequisites
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
  deploy_platform "${@:2}"
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
shell-setup)
  setup_shell
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
rollback)
  rollback
  ;;
history)
  update_history
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
restoredb)
  restore_cassandra_snapshot "${@:2}"
  ;;
restoredb-full)
  restore_cassandra_full "${@:2}"
  ;;
backupconfig)
  backup_config
  ;;
validate)
  validate_manifests
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
  exit 1
  ;;
esac
