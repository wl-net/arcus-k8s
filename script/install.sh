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

  local started_at
  started_at=$(date '+%Y-%m-%d %H:%M:%S')
  curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION="${K3S_VERSION}" INSTALL_K3S_EXEC='--disable=servicelb --write-kubeconfig-mode 644' sh -

  # The installer returns as soon as the service is started; wait until the
  # kubelet is actually up rather than leaving a crash loop for later. Pods
  # keep running under containerd throughout; only the API is away.
  _wait_for_k3s "$started_at" || return 1
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

# Wait for k3s to serve the API with the service staying up. One known way an
# upgrade fails is repaired here: the installer's restart can cut the kubelet
# off mid-write on /var/lib/kubelet/cpu_manager_state, after which the new
# kubelet refuses to start ("checkpoint is corrupted ... delete the CPU manager
# checkpoint file") and k3s crash-loops with the API up for a few seconds per
# cycle (dev, 2026-10-23, v1.36.5 -> v1.37.1). With no CPU manager policy
# configured that file holds only the policy name and an empty CPU set, and
# the kubelet rewrites it on start, so when the journal shows that exact error
# the file is removed and k3s restarted. Nothing is touched on a clean start.
function _wait_for_k3s() {
  local since=$1 deadline=$((SECONDS + 180)) repaired=0
  until $KUBECTL get nodes &>/dev/null && [[ "$(sudo systemctl is-active k3s)" == "active" ]]; do
    if [[ $repaired -eq 0 ]] && sudo journalctl -u k3s --since "$since" -o cat 2>/dev/null \
         | grep -q 'CPU manager checkpoint file'; then
      echo "k3s is failing on a corrupted kubelet CPU manager checkpoint (truncated during the restart);"
      echo "removing /var/lib/kubelet/cpu_manager_state (policy none: it holds no pod state) and restarting k3s..."
      sudo systemctl stop k3s
      sudo rm -f /var/lib/kubelet/cpu_manager_state
      sudo systemctl start k3s
      repaired=1
    fi
    if ((SECONDS >= deadline)); then
      echo "k3s did not become ready within 3 minutes. Check: sudo journalctl -u k3s -n 50"
      return 1
    fi
    sleep 5
  done
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
