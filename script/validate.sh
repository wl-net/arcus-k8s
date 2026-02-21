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
      ((errors++))
    fi
  done < <(find config/ overlays/ -name '*.yml' -o -name '*.yaml' | sort)

  echo ""
  echo "=== Kustomize Build ==="
  if $KUBECTL kustomize config > /dev/null 2>&1; then
    echo "  OK:   config/ builds cleanly"
  else
    echo "  FAIL: config/ kustomize build failed"
    $KUBECTL kustomize config 2>&1 | sed 's/^/  /'
    ((errors++))
  fi

  echo ""
  echo "=== Kubernetes Schema ==="
  if command -v kubeconform &>/dev/null; then
    local kc_output
    kc_output=$($KUBECTL kustomize config 2>/dev/null \
      | kubeconform -summary -strict \
          -ignore-missing-schemas \
          -kubernetes-version 1.32.0 2>&1)
    local kc_exit=$?
    # shellcheck disable=SC2001
    echo "$kc_output" | sed 's/^/  /'
    if [[ $kc_exit -ne 0 ]]; then
      ((errors++))
    fi
  else
    echo "  SKIP: kubeconform not installed (install from https://github.com/yannh/kubeconform)"
  fi

  echo ""
  if [[ $errors -eq 0 ]]; then
    echo "Validation passed."
  else
    echo "$errors check(s) failed."
    return 1
  fi
}
