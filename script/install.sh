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
  curl -sfL https://get.k3s.io | sudo INSTALL_K3S_EXEC='--disable=servicelb --disable=traefik --write-kubeconfig-mode 644' sh -

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

function install_nginx() {
  # Delete completed admission jobs — their spec.template is immutable and
  # kubectl apply will fail if they already exist from a previous install.
  $KUBECTL delete job -n ingress-nginx ingress-nginx-admission-create ingress-nginx-admission-patch 2>/dev/null || true
  $KUBECTL apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-${NGINX_VERSION}/deploy/static/provider/baremetal/deploy.yaml"
}

function install_certmanager() {
  $KUBECTL apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
}

function install_istio() {
  $KUBECTL create namespace istio-system --dry-run=client -o yaml | $KUBECTL apply -f -

  $KUBECTL get crd gateways.gateway.networking.k8s.io &>/dev/null || \
    $KUBECTL kustomize "github.com/kubernetes-sigs/gateway-api/config/crd?ref=v1.3.0" | $KUBECTL apply -f -

  helm repo add istio https://istio-release.storage.googleapis.com/charts
  helm repo update

  helm upgrade --install istio-base istio/base \
    --namespace istio-system \
    --version "$ISTIO_VERSION" \
    --set defaultRevision=default \
    --create-namespace

  helm upgrade --install istiod istio/istiod \
    --namespace istio-system \
    --version "$ISTIO_VERSION" \
    --set pilot.resources.requests.cpu=100m \
    --set pilot.resources.requests.memory=512M

  $KUBECTL label namespace default istio-injection=enabled --overwrite &>/dev/null || true
}

function install() {
  load
  local targets=("$@")
  if [[ ${#targets[@]} -eq 0 ]]; then
    targets=(nginx cert-manager istio)
  fi
  for target in "${targets[@]}"; do
    case "$target" in
      metallb)      install_metallb ;;
      nginx)        install_nginx ;;
      cert-manager) install_certmanager ;;
      istio)        install_istio ;;
      *)
        echo "Unknown component: $target"
        echo "Available: metallb, nginx, cert-manager, istio"
        return 1
        ;;
    esac
  done
}
