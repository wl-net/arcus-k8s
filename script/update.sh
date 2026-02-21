# shellcheck shell=bash
# Update, history, and rollback functions

function update() {
  local branch before after

  branch=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)
  before=$(git -C "$ROOT" rev-parse HEAD)

  local last_applied=""
  if [[ -f "$ROOT/.cache/last-applied-rev" ]]; then
    last_applied=$(cat "$ROOT/.cache/last-applied-rev")
  fi

  if [[ -n "$last_applied" && "$last_applied" != "$before" ]]; then
    echo "Warning: current revision (${before:0:7}) has not been applied (last applied: ${last_applied:0:7})"
    echo ""
  fi

  if ! git -C "$ROOT" diff --quiet; then
    echo "Warning: you have uncommitted changes"
    git -C "$ROOT" --no-pager diff --stat
    echo ""
  fi

  git -C "$ROOT" pull --ff-only --quiet || {
    echo "Fast-forward failed. You may have local commits that diverge from the remote."
    echo "Resolve manually with: git -C $ROOT rebase origin/$branch"
    return 1
  }

  after=$(git -C "$ROOT" rev-parse HEAD)

  if [[ "$before" == "$after" ]]; then
    echo "Already up to date on $branch (${after:0:7})."
    return 0
  fi

  mkdir -p "$ROOT/.cache"
  echo "$(date -Iseconds) $before $after" >> "$ROOT/.cache/update-history"

  echo "Updated $branch: ${before:0:7} -> ${after:0:7}"
  git -C "$ROOT" --no-pager log --oneline "${before}..${after}"

  local config_changes
  config_changes=$(git -C "$ROOT" --no-pager diff --name-only "${before}..${after}" -- \
    'config/' 'overlays/' '*.yml' '*.yaml')

  if [[ -n "$config_changes" ]]; then
    echo ""
    echo "Changed manifests/overlays:"
    echo "${config_changes//$'\n'/$'\n'  }" | sed '1s/^/  /'
    echo ""
    local show_diff
    prompt show_diff "Show full diff of manifest changes? [yes/no]:"
    if [[ "$show_diff" == "yes" ]]; then
      git -C "$ROOT" --no-pager diff "${before}..${after}" -- \
        'config/' 'overlays/' '*.yml' '*.yaml'
    fi
  fi

  echo ""
  echo "Run './arcuscmd.sh apply' to deploy the new configuration."
  echo "Run './arcuscmd.sh rollback' to revert to the previous version."
}

function update_history() {
  local history_file="$ROOT/.cache/update-history"
  if [[ ! -f "$history_file" ]]; then
    echo "No update history found."
    return 0
  fi

  local last_applied=""
  if [[ -f "$ROOT/.cache/last-applied-rev" ]]; then
    last_applied=$(cat "$ROOT/.cache/last-applied-rev")
  fi

  echo "Update history (most recent first):"
  echo ""
  local ts prev_rev new_rev status
  while read -r ts prev_rev new_rev; do
    if [[ -n "$last_applied" ]]; then
      if git -C "$ROOT" merge-base --is-ancestor "$new_rev" "$last_applied" 2>/dev/null; then
        status="[applied]"
      else
        status="[pending]"
      fi
    else
      status=""
    fi
    echo "  $ts  ${prev_rev:0:7} -> ${new_rev:0:7}  $status"
  done < <(tail -10 "$history_file" | tac)
}

function rollback() {
  local history_file="$ROOT/.cache/update-history"
  if [[ ! -f "$history_file" ]]; then
    echo "No update history found. Nothing to roll back to."
    return 1
  fi

  local count
  count=$(wc -l < "$history_file")

  if [[ "$count" -eq 1 ]]; then
    local ts prev_rev new_rev
    read -r ts prev_rev new_rev < "$history_file"
    echo "Rolling back to ${prev_rev:0:7} (before update at $ts)"
    git -C "$ROOT" checkout "$prev_rev"
    echo "Rolled back. Run './arcuscmd.sh apply' to deploy."
    return 0
  fi

  echo "Recent updates (most recent first):"
  echo ""
  local i=0
  local -a revs timestamps
  while read -r ts prev_rev new_rev; do
    revs+=("$prev_rev")
    timestamps+=("$ts")
    echo "  $((i + 1))) $ts  ${prev_rev:0:7} -> ${new_rev:0:7}"
    ((i++))
  done < <(tail -10 "$history_file" | tac)

  echo ""
  local choice
  prompt choice "Roll back to which version? [1-$i]:"
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "$i" ]]; then
    echo "Invalid selection."
    return 1
  fi

  local target="${revs[$((choice - 1))]}"
  echo "Rolling back to ${target:0:7} (before update at ${timestamps[$((choice - 1))]})"
  git -C "$ROOT" checkout "$target"
  echo "Rolled back. Run './arcuscmd.sh apply' to deploy."
}
