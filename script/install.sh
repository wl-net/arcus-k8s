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
  curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION="${K3S_VERSION}" INSTALL_K3S_EXEC='--disable=servicelb --write-kubeconfig-mode 644' sh -

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

# TEMPORARY: one-shot cleanup for clusters that still have Istio from before it
# was dropped from install. Remove this function and its arcuscmd.sh entry once
# dev, dc1, and dc2 have all run it.
function uninstall_istio() {
  # Removing istiod strands any proxy still running, so those pods must restart
  # without a sidecar first. Finished pods have no proxy left to strand.
  local sidecars=() fixes=() deploy_arcus=0 pod owner hash containers ns
  while IFS='|' read -r pod owner hash containers; do
    [[ " $containers " == *" istio-proxy "* ]] || continue
    sidecars+=("$pod")
    ns=${pod%%/*}
    # Name whatever recreates the pod. A ReplicaSet is named for its Deployment
    # plus the pod-template-hash.
    case "$owner" in
      ReplicaSet/*)
        owner=${owner#ReplicaSet/}
        owner=${owner%-"$hash"}
        if [[ "$ns" == default && " $APPS " == *" $owner "* ]]; then
          deploy_arcus=1
          continue
        fi
        fixes+=("$KUBECTL -n $ns rollout restart deployment/$owner")
        ;;
      StatefulSet/*|DaemonSet/*)
        fixes+=("$KUBECTL -n $ns rollout restart ${owner,,}")
        ;;
      Job/*)
        fixes+=("$KUBECTL -n $ns delete job/${owner#Job/}")
        ;;
      *)
        fixes+=("$KUBECTL -n $ns delete pod/${pod#*/}")
        ;;
    esac
  done < <($KUBECTL get pods -A --field-selector=status.phase!=Succeeded,status.phase!=Failed \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"|"}{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"|"}{.metadata.labels.pod-template-hash}{"|"}{.spec.initContainers[*].name}{" "}{.spec.containers[*].name}{"\n"}{end}')

  if [[ ${#sidecars[@]} -gt 0 ]]; then
    echo "These pods still run an istio-proxy sidecar:"
    printf '  %s\n' "${sidecars[@]}"
    echo "Sidecar injection will be turned off, but Istio stays installed until they restart."
  else
    echo "This removes Istio from the cluster: istiod, its CRDs and webhooks, the istio-system"
    echo "namespace, and leftover Istio RBAC, CA configmaps, and certificate secrets."
  fi
  local confirm
  prompt confirm "Are you sure you want to continue? [yes/no]:"
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    return 0
  fi

  $KUBECTL label namespace -l istio-injection istio-injection-

  if [[ ${#sidecars[@]} -gt 0 ]]; then
    echo "Restart them, then run this again:"
    if [[ $deploy_arcus -eq 1 ]]; then
      echo "  ./arcuscmd.sh deploy"
    fi
    if [[ ${#fixes[@]} -gt 0 ]]; then
      printf '  %s\n' "${fixes[@]}" | sort -u
    fi
    return 1
  fi

  local release
  for release in istiod istio-base; do
    if helm status "$release" -n istio-system &>/dev/null; then
      helm uninstall "$release" -n istio-system --wait
    fi
  done

  # Helm only owns what the current chart installed. Sweep up the rest by name:
  # Istio 1.4-era RBAC, plus webhooks and CRDs from non-Helm installs.
  local leftovers=()
  mapfile -t leftovers < <(
    $KUBECTL get crd -o name | grep '\.istio\.io$'
    $KUBECTL get clusterroles,clusterrolebindings,mutatingwebhookconfigurations,validatingwebhookconfigurations -o name | grep istio
  )
  if [[ ${#leftovers[@]} -gt 0 ]]; then
    $KUBECTL delete --ignore-not-found "${leftovers[@]}"
  fi

  $KUBECTL delete namespace istio-system --ignore-not-found

  # istiod creates these GatewayClasses at runtime and nothing else removes them.
  # The Gateway API CRDs themselves belong to k3s's traefik-crd chart and stay.
  if $KUBECTL get crd gatewayclasses.gateway.networking.k8s.io &>/dev/null; then
    $KUBECTL delete gatewayclass istio istio-remote --ignore-not-found
  fi

  # istiod copies its root CA into every namespace, and Istio 1.4's Citadel left
  # a key-and-cert secret for every service account.
  $KUBECTL delete configmap -A --field-selector metadata.name=istio-ca-root-cert
  $KUBECTL delete secret -A --field-selector type=istio.io/key-and-cert

  helm repo remove istio &>/dev/null || true

  echo "Istio removed."
}
