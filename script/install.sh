# shellcheck shell=bash
# Installation and infrastructure setup functions

function check_prerequisites() {
  local missing=()
  for cmd in curl git openssl sudo; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: required commands not found: ${missing[*]}"
    echo "Install them before running setup."
    return 1
  fi
}

function setup_k3s() {
  # The Node Disk Filling alert fires at 80%, but by default the kubelet only
  # deletes unused images from 85%. Start at 75% and clear down to 65%, so old
  # release images go before the alert does. Written before the installer runs,
  # since it (re)starts k3s.
  sudo mkdir -p /etc/rancher/k3s/config.yaml.d
  sudo tee /etc/rancher/k3s/config.yaml.d/arcus-image-gc.yaml > /dev/null <<'EOF'
# Written by arcuscmd.sh k3s
kubelet-arg+:
  - image-gc-high-threshold=75
  - image-gc-low-threshold=65
EOF

  # On an upgrade the installer stops the running k3s to swap the binary. If
  # the kubelet is mid-write on its CPU manager checkpoint at that moment the
  # file is left truncated, and the new kubelet then refuses to start
  # ("checkpoint is corrupted ... delete the CPU manager checkpoint file"), so
  # k3s crash-loops and the API is only up for a few seconds per cycle (dev,
  # 2026-10-23, v1.36.5 -> v1.37.1). Stop k3s ourselves and remove the file
  # while nothing is writing it: no CPU manager policy is configured, so it
  # holds nothing to keep and the kubelet recreates it. Pods keep running
  # under containerd while k3s is down; only the API is away.
  if sudo systemctl is-active --quiet k3s; then
    echo "Stopping k3s for the upgrade (pods keep running; the API is unavailable until it is back)..."
    sudo systemctl stop k3s
    sudo rm -f /var/lib/kubelet/cpu_manager_state
  fi

  curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION="${K3S_VERSION}" INSTALL_K3S_EXEC='--disable=servicelb --write-kubeconfig-mode 644' sh -

  # The installer returns as soon as the service is started; make sure the
  # kubelet actually came up rather than leaving a crash loop for later.
  local deadline=$((SECONDS + 180))
  until $KUBECTL get nodes &>/dev/null && [[ "$(sudo systemctl is-active k3s)" == "active" ]]; do
    if ((SECONDS >= deadline)); then
      echo "k3s did not become ready within 3 minutes. Check: sudo journalctl -u k3s -n 50"
      return 1
    fi
    sleep 5
  done
  $KUBECTL get nodes

  local inotify_watches
  inotify_watches=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null) || true
  if [[ -n "$inotify_watches" && "$inotify_watches" -lt 524288 ]]; then
    echo ""
    echo "fs.inotify.max_user_watches is $inotify_watches (recommended: 524288)"
    echo "Kubernetes requires a higher value to avoid 'too many open files' errors."
    sudo sysctl -w fs.inotify.max_user_watches=524288
    echo 'fs.inotify.max_user_watches=524288' | sudo tee -a /etc/sysctl.d/99-inotify.conf > /dev/null
    echo "inotify watches increased and persisted."
  fi

  # Make kubectl work without KUBECONFIG being set
  mkdir -p "$HOME/.kube"
  cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
  chmod 600 "$HOME/.kube/config"
  echo "Kubeconfig written to ~/.kube/config"
}

function setup_helm() {
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
}

function setup_shell() {
  local shell_name rcfile
  shell_name=$(basename "$SHELL")

  case "$shell_name" in
    zsh)  rcfile="$HOME/.zshrc" ;;
    bash) rcfile="$HOME/.bashrc" ;;
    *)
      echo "Unsupported shell: $shell_name"
      echo "Add this to your shell config manually:"
      echo "  arcuscmd() { \"${ROOT}/arcuscmd.sh\" \"\$@\"; }"
      return 1
      ;;
  esac

  local func_line="arcuscmd() { \"${ROOT}/arcuscmd.sh\" \"\$@\"; }"

  if grep -qF 'arcuscmd()' "$rcfile" 2>/dev/null; then
    echo "arcuscmd is already in $rcfile"
    return 0
  fi

  {
    echo ""
    echo "# Arcus deployment CLI"
    echo "$func_line"
  } >> "$rcfile"
  echo "Added arcuscmd to $rcfile — run 'source $rcfile' or open a new terminal to use it."
}

function install_metallb() {
  if [[ "${ARCUS_METALLB:-no}" != "yes" ]]; then
    echo "Skipping MetalLB (not enabled — run './arcuscmd.sh configure' to enable)"
    return 0
  fi

  $KUBECTL apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"
}

function install_traefik() {
  # Traefik is bundled with k3s. We configure it via a HelmChartConfig in
  # kube-system; k3s's helm controller reconciles the chart. Requires k3s to
  # be installed WITHOUT --disable=traefik.
  if [[ -n "${ARCUS_PROXY_REAL_IP-}" ]]; then
    mkdir -p "overlays/${ARCUS_OVERLAY_NAME}-local"
    cp config/templates/traefik-proxy.yaml "overlays/${ARCUS_OVERLAY_NAME}-local/traefik-config.yaml"
    sed -i "s!PLACEHOLDER_PROXY_IP!${ARCUS_PROXY_REAL_IP}!" "overlays/${ARCUS_OVERLAY_NAME}-local/traefik-config.yaml"
    $KUBECTL apply -f "overlays/${ARCUS_OVERLAY_NAME}-local/traefik-config.yaml"
  else
    $KUBECTL apply -f config/traefik-config.yaml
  fi
}

function install_certmanager() {
  $KUBECTL apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
}

function install() {
  load
  local targets=("$@")
  if [[ ${#targets[@]} -eq 0 ]]; then
    targets=(traefik cert-manager)
  fi
  for target in "${targets[@]}"; do
    case "$target" in
      metallb)      install_metallb ;;
      traefik)      install_traefik ;;
      cert-manager) install_certmanager ;;
      *)
        echo "Unknown component: $target"
        echo "Available: metallb, traefik, cert-manager"
        return 1
        ;;
    esac
  done
}
