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

if [[ ${1:-help} != 'help' && ${1:-help} != 'setup' && ${1:-help} != 'configure' && ${1:-help} != 'verifyconfig' && ${1:-help} != 'shell-setup' && ${1:-help} != 'validate' && ${1:-help} != 'drain' && ${1:-help} != 'resume' ]]; then
  if ! command -v "$KUBECTL" &>/dev/null; then
    echo "Error: kubectl not found. Is it installed and in your PATH?"
    exit 1
  fi
fi

if [[ ${1:-help} != 'help' && ${1:-help} != 'setup' && ${1:-help} != 'configure' && ${1:-help} != 'verifyconfig' && ${1:-help} != 'shell-setup' && ${1:-help} != 'validate' && ${1:-help} != 'k3s' && ${1:-help} != 'install' && ${1:-help} != 'drain' && ${1:-help} != 'resume' ]]; then
  require_config
fi

function print_available() {
  cat <<ENDOFDOC
arcuscmd: manage your arcus deployment

Setup:
  setup               Setup a new instance of Arcus
  k3s                 Install or upgrade k3s
  install [component] Install/upgrade infrastructure (metallb, nginx, cert-manager, istio)
                        Installs all if none specified
  configure           Configure Arcus by answering a few questions
  shell-setup         Add 'arcuscmd' shortcut to your shell config

Deploy:
  apply               Apply the current configuration to the cluster
  deploy [svc...]       Rolling restart of services (all if none specified)
                          --pull  Force re-pull images before restarting
  update [--apply]    Pull latest changes and show what changed
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
  modelmanager        Run model manager jobs (provision database schemas)
  setupmetrics        Setup Grafana metrics
  silence [duration]  Silence Grafana alerts (default: 2h, e.g. 30m, 4h)
  unsilence           Remove active Grafana alert silences
  upgrade-node        Update and upgrade system packages (apt)
  reboot-node         Drain traffic, silence alerts, and reboot this host
  drain               Set Route 53 weighted record to 0 (remove traffic from this cluster)
  resume              Restore Route 53 weighted record to its previous value
  deletepod           Delete pods matching an application
  logs                Get logs for an application
  certlogs            Get logs for cert-manager (optionally: webhook, cainjector)
  shell               Get an interactive shell on a pod
  dbshell             Open a Cassandra CQL shell

Dangerous:
  killall             Delete all Arcus pods, triggering a full reschedule
ENDOFDOC

}

trap _notify_on_exit EXIT

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
    setup_k3s
    setup_helm
    install
    configure
    apply
    runmodelmanager
    info
  else
    echo "For cloud deployments, ensure kubectl is configured to point at your cluster, then run:"
    echo "  ./arcuscmd.sh install"
    echo "  ./arcuscmd.sh configure"
    echo "  ./arcuscmd.sh apply"
    echo "  ./arcuscmd.sh modelmanager"
  fi
  ;;
setupmetrics)
  setup_metrics
  ;;
apply)
  _notify_start "Applying configuration"
  apply
  ;;
k3s)
  setup_k3s
  ;;
install)
  install "${@:2}"
  ;;
configure)
  configure
  ;;
deploy)
  deploy_platform "${@:2}"
  ;;
killall)
  _notify_start "Killing all pods" "$_NOTIFY_COLOR_ORANGE"
  killallpods
  ;;
updatehubkeystore)
  _notify_start "Updating hub keystore"
  updatehubkeystore
  ;;
modelmanager)
  _notify_start "Running model manager"
  runmodelmanager
  ;;
shell-setup)
  setup_shell
  ;;
useprodcert)
  _notify_start "Switching to production certificate"
  useprodcert
  ;;
info)
  info
  ;;
check)
  connectivity_check
  ;;
update)
  _notify_start "Pulling latest changes"
  update "${@:2}"
  ;;
rollback)
  _notify_start "Rolling back to previous version" "$_NOTIFY_COLOR_ORANGE"
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
  _notify_start "Deleting pods: ${*:2}"
  delete "${@:2}"
  ;;
backupdb)
  _notify_start "Backing up Cassandra"
  backup_cassandra
  ;;
restoredb)
  _notify_start "Restoring Cassandra from snapshot" "$_NOTIFY_COLOR_ORANGE"
  restore_cassandra_snapshot "${@:2}"
  ;;
restoredb-full)
  _notify_start "Full Cassandra restore" "$_NOTIFY_COLOR_ORANGE"
  restore_cassandra_full "${@:2}"
  ;;
backupconfig)
  backup_config
  ;;
silence)
  _notify_start "Silencing alerts for ${2:-2h}"
  silence_alerts "${2:-2h}"
  ;;
unsilence)
  _notify_start "Removing alert silences"
  unsilence_alerts
  ;;
upgrade-node)
  _notify_start "Upgrading node packages"
  upgrade_node
  ;;
reboot-node)
  _notify_start "Rebooting node" "$_NOTIFY_COLOR_ORANGE"
  reboot_node
  ;;
drain)
  _notify_start "Draining traffic" "$_NOTIFY_COLOR_ORANGE"
  route53_drain
  ;;
resume)
  _notify_start "Resuming traffic"
  route53_resume
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
