# shellcheck shell=bash
# Manifest validation functions

function validate_manifests() {
  local errors=0

  echo "=== YAML Syntax ==="
  while IFS= read -r f; do
    local err
    if err=$(python3 -c "import yaml, sys; list(yaml.safe_load_all(open(sys.argv[1])))" "$f" 2>&1); then
      echo "  OK:   $f"
    else
      echo "  FAIL: $f"
      while IFS= read -r line; do echo "        $line"; done <<< "$err"
      errors=$((errors + 1))
    fi
  done < <(find config/ overlays/ -name '*.yaml' | sort)

  echo ""
  echo "=== Kustomize Build ==="
  if $KUBECTL kustomize config > /dev/null 2>&1; then
    echo "  OK:   config/ builds cleanly"
  else
    echo "  FAIL: config/ kustomize build failed"
    $KUBECTL kustomize config 2>&1 | sed 's/^/  /'
    errors=$((errors + 1))
  fi

  echo ""
  echo "=== Kubernetes Schema ==="
  if command -v kubeconform &>/dev/null; then
    # Validate against the Kubernetes version k3s installs (v1.36.5+k3s1 -> 1.36.5)
    local k8s_version=${K3S_VERSION#v}
    k8s_version=${k8s_version%%+*}
    local kc_output kc_exit=0
    kc_output=$($KUBECTL kustomize config 2>/dev/null \
      | kubeconform -summary -strict \
          -ignore-missing-schemas \
          -kubernetes-version "$k8s_version" 2>&1) || kc_exit=$?
    # shellcheck disable=SC2001
    echo "$kc_output" | sed 's/^/  /'
    if [[ $kc_exit -ne 0 ]]; then
      errors=$((errors + 1))
    fi
  else
    echo "  SKIP: kubeconform not installed (install from https://github.com/yannh/kubeconform)"
  fi

  echo ""
  echo "=== Monitoring Config ==="
  if command -v docker &>/dev/null && docker info &>/dev/null; then
    _validate_monitoring || errors=$((errors + 1))
  else
    echo "  SKIP: docker not available (the Prometheus, blackbox, Loki, Alloy and Grafana checks run their images)"
  fi

  echo ""
  if [[ $errors -eq 0 ]]; then
    echo "Validation passed."
  else
    echo "$errors check(s) failed."
    return 1
  fi
}

# The image config/$1 runs (its first image: line), so the checks use the versions
# that are deployed.
function _manifest_image() {
  awk '$1 == "image:" { print $2; exit } $1 == "-" && $2 == "image:" { print $3; exit }' "$ROOT/config/$1"
}

# Run check $1 as a docker command, printing OK or FAIL with the command's output.
function _docker_check() {
  local name=$1 output
  shift
  if output=$("$@" 2>&1); then
    echo "  OK:   $name"
    return 0
  fi
  echo "  FAIL: $name"
  tail -n 30 <<< "$output" | sed 's/^/        /'
  return 1
}

# Check the monitoring configuration with the programs that will load it:
# promtool for Prometheus, the blackbox exporter's and Loki's own config checks,
# alloy validate, and a Grafana started against the provisioning files, which is
# the only way to find out whether every alert rule, the notification template
# and the contact points apply would write are accepted. Grafana exits at
# startup when provisioning fails, so this is what keeps a typo in
# alerting.yaml from taking down a datacenter's alerting.
function _validate_monitoring() {
  local failed=0 image
  local work
  work=$(mktemp -d)
  # shellcheck disable=SC2064 # expand now: the directory name is fixed
  trap "rm -rf '$work'" RETURN

  image=$(_manifest_image stateful/prometheus.yaml)
  _docker_check "prometheus.yaml (promtool, $image)" \
    docker run --rm -v "$ROOT/config/extrafiles/prometheus.yaml:/check/prometheus.yaml:ro" \
    --entrypoint promtool "$image" check config --syntax-only /check/prometheus.yaml || failed=1

  image=$(_manifest_image monitoring/blackbox-exporter.yaml)
  _docker_check "blackbox.yaml ($image)" \
    docker run --rm -v "$ROOT/config/extrafiles/blackbox.yaml:/check/blackbox.yaml:ro" \
    "$image" --config.check --config.file=/check/blackbox.yaml || failed=1

  image=$(_manifest_image stateful/loki.yaml)
  _docker_check "loki.yaml ($image)" \
    docker run --rm -v "$ROOT/config/extrafiles/loki.yaml:/check/loki.yaml:ro" \
    "$image" -config.file=/check/loki.yaml -verify-config || failed=1

  image=$(_manifest_image logging/alloy.yaml)
  python3 -c '
import sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc.get("kind") == "ConfigMap":
        sys.stdout.write(doc["data"]["config.alloy"])' "$ROOT/config/logging/alloy.yaml" > "$work/config.alloy"
  _docker_check "alloy.yaml config ($image)" \
    docker run --rm -v "$work/config.alloy:/check/config.alloy:ro" "$image" validate /check/config.alloy || failed=1

  # Grafana, provisioned the way the StatefulSet mounts it: rules rendered with the
  # default thresholds, plus the contact points and policy for a Discord webhook
  # and Pushover keys, so that generator is checked too
  mkdir -p "$work/provisioning/datasources" "$work/provisioning/alerting" "$work/provisioning/dashboards/json"
  cp "$ROOT/config/grafana/datasources.yaml" "$work/provisioning/datasources/"
  cp "$ROOT/config/grafana/dashboards.yaml" "$work/provisioning/dashboards/"
  cp "$ROOT"/config/dashboards/*.json "$work/provisioning/dashboards/json/"
  ARCUS_EXPECTED_HUBS="" _render_alert_rules "$work/provisioning/alerting/alerting.yaml"
  ARCUS_ALERT_DISCORD_WEBHOOK="https://discord.com/api/webhooks/0/check" \
    ARCUS_ALERT_PUSHOVER_USER_KEY="check" ARCUS_ALERT_PUSHOVER_API_TOKEN="check" \
    _grafana_notifications > "$work/provisioning/alerting/notifications.yaml"
  chmod -R a+rX "$work"
  local expected_rules
  expected_rules=$(grep -c '^  - uid: ' "$ROOT/config/grafana/alerting.yaml")
  image=$(_manifest_image stateful/grafana.yaml)
  local name="arcus-validate-grafana-$$"
  docker rm -f "$name" &>/dev/null || true
  if ! docker run -d --name "$name" -e GF_SECURITY_ADMIN_PASSWORD=validate \
       -v "$work/provisioning:/etc/grafana/provisioning:ro" "$image" > /dev/null; then
    echo "  FAIL: could not start $image"
    return 1
  fi
  local deadline=$((SECONDS + 120)) health="" rules
  while ((SECONDS < deadline)); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != "true" ]]; then
      break
    fi
    health=$(docker exec "$name" curl -sf http://localhost:3000/api/health 2>/dev/null) && break
    sleep 2
  done
  if [[ -z "$health" ]]; then
    echo "  FAIL: Grafana ($image) did not come up with this provisioning"
    docker logs "$name" 2>&1 | grep -iE 'error|fail|provision' | tail -n 20 | sed 's/^/        /'
    failed=1
  else
    rules=$(docker exec "$name" curl -sf -u admin:validate http://localhost:3000/api/v1/provisioning/alert-rules 2>/dev/null \
      | python3 -c 'import sys, json; print(len(json.load(sys.stdin)))' 2>/dev/null) || rules=0
    if [[ "$rules" == "$expected_rules" ]]; then
      echo "  OK:   alerting.yaml: Grafana ($image) loaded all $rules alert rules, the notification template and the contact points"
    else
      echo "  FAIL: alerting.yaml: Grafana ($image) loaded $rules of $expected_rules alert rules"
      docker logs "$name" 2>&1 | grep -iE 'error|fail|provision' | tail -n 20 | sed 's/^/        /'
      failed=1
    fi
    local policy
    policy=$(docker exec "$name" curl -sf -u admin:validate http://localhost:3000/api/v1/provisioning/policies 2>/dev/null)
    if [[ "$policy" == *'"receiver":"arcus-discord"'* ]]; then
      echo "  OK:   notification policy provisioned"
    else
      echo "  FAIL: notification policy was not provisioned: ${policy:-no answer}"
      failed=1
    fi
  fi
  docker rm -f "$name" &>/dev/null || true
  return $failed
}
