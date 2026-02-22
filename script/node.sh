# shellcheck shell=bash
# Node operations: upgrades and reboots

upgrade_node() {
  echo "Updating package lists..."
  sudo apt-get update

  echo ""
  echo "Upgrading packages..."
  sudo apt-get dist-upgrade -y

  echo ""
  if [[ -f /var/run/reboot-required ]]; then
    echo "Reboot required."
    if [[ -f /var/run/reboot-required.pkgs ]]; then
      echo "Packages requiring reboot:"
      sed 's/^/  /' /var/run/reboot-required.pkgs
    fi
    echo ""
    echo "Run './arcuscmd.sh reboot-node' to reboot gracefully."
  else
    echo "No reboot required."
  fi
}

reboot_node() {
  echo "This will:"
  echo "  1. Drain Route 53 traffic (if configured)"
  echo "  2. Silence Grafana alerts for 10 minutes"
  echo "  3. Disconnect hubs and clients from bridges"
  echo "  4. Reboot this host"
  echo ""

  local confirm
  prompt confirm "Are you sure? [yes/no]:"
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    return 0
  fi

  local _reboot_drained=false
  local _reboot_silenced=false

  # shellcheck disable=SC2317 # invoked indirectly via trap
  _reboot_cleanup() {
    echo ""
    echo "Interrupted. Rolling back..."
    if [[ "$_reboot_silenced" == true ]]; then
      echo "Removing alert silence..."
      unsilence_alerts
    fi
    if [[ "$_reboot_drained" == true ]]; then
      echo "Resuming traffic..."
      route53_resume
    fi
    trap - INT
    echo "Reboot aborted."
  }
  trap _reboot_cleanup INT

  # Drain traffic if Route 53 is configured
  if [[ "${ARCUS_CERT_SOLVER:-}" == "dns" && -n "${ARCUS_ROUTE53_SET_ID:-}" ]]; then
    echo ""
    echo "Draining traffic..."
    route53_drain
    _reboot_drained=true
    echo "Waiting 30s for traffic to drain..."
    sleep 30
  else
    echo ""
    echo "Skipping drain (Route 53 not configured)."
  fi

  # Silence alerts
  echo ""
  echo "Silencing alerts for 10 minutes..."
  silence_alerts 10m
  _reboot_silenced=true

  # Disconnect hubs and clients by deleting bridge pods (SIGTERM gives 30s for clean shutdown)
  echo ""
  echo "Disconnecting hubs and clients..."
  "$KUBECTL" delete pod -l app=hub-bridge --wait=false
  "$KUBECTL" delete pod -l app=client-bridge --wait=false
  echo "Waiting 30s for bridges to shut down gracefully..."
  sleep 30

  trap - INT
  echo ""
  echo "Rebooting..."
  sudo reboot
}
