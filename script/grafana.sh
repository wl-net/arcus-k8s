# shellcheck shell=bash
# Grafana alert silence management

GRAFANA_URL="http://grafana-service.default.svc.cluster.local:3000"
GRAFANA_SECRET_NAME="grafana-api-token"

_grafana_get_token() {
  kubectl get secret "$GRAFANA_SECRET_NAME" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d
}

_grafana_api() {
  local token
  token=$(_grafana_get_token)
  local method=$1 path=$2
  shift 2
  kubectl exec statefulset/grafana -- curl -sf -X "$method" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    "${GRAFANA_URL}${path}" "$@"
}

_ensure_grafana_token() {
  if kubectl get secret "$GRAFANA_SECRET_NAME" &>/dev/null; then
    return 0
  fi

  echo "No Grafana API token found. Creating a service account..."
  echo "You will need the Grafana admin password (one-time setup)."
  echo ""

  local password
  prompt password "Grafana admin password:"

  # Create service account
  local sa_response
  sa_response=$(kubectl exec statefulset/grafana -- curl -sf -X POST \
    -u "admin:${password}" \
    -H "Content-Type: application/json" \
    "${GRAFANA_URL}/api/serviceaccounts" \
    -d '{"name":"arcuscmd","role":"Editor"}') || {
    echo "Error: failed to create service account. Check the admin password."
    return 1
  }

  local sa_id
  sa_id=$(echo "$sa_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

  # Create token for the service account
  local token_response
  token_response=$(kubectl exec statefulset/grafana -- curl -sf -X POST \
    -u "admin:${password}" \
    -H "Content-Type: application/json" \
    "${GRAFANA_URL}/api/serviceaccounts/${sa_id}/tokens" \
    -d '{"name":"arcuscmd-token"}') || {
    echo "Error: failed to create API token."
    return 1
  }

  local token
  token=$(echo "$token_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['key'])")

  kubectl create secret generic "$GRAFANA_SECRET_NAME" --from-literal="token=${token}"
  echo "Grafana API token saved to secret/${GRAFANA_SECRET_NAME}"
}

silence_alerts() {
  _ensure_grafana_token || return 1

  local duration="${1:-2h}"

  # Parse duration into seconds
  local seconds=0
  if [[ "$duration" =~ ^([0-9]+)h$ ]]; then
    seconds=$(( BASH_REMATCH[1] * 3600 ))
  elif [[ "$duration" =~ ^([0-9]+)m$ ]]; then
    seconds=$(( BASH_REMATCH[1] * 60 ))
  else
    echo "Invalid duration '${duration}'. Use format like 2h or 30m."
    return 1
  fi

  local starts_at ends_at
  starts_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  ends_at=$(date -u -d "+${seconds} seconds" +"%Y-%m-%dT%H:%M:%SZ")

  local response
  response=$(_grafana_api POST "/api/alertmanager/grafana/api/v2/silences" \
    -d "{\"matchers\":[{\"name\":\"severity\",\"value\":\".+\",\"isRegex\":true}],\"startsAt\":\"${starts_at}\",\"endsAt\":\"${ends_at}\",\"comment\":\"Silenced via arcuscmd for ${duration}\",\"createdBy\":\"arcuscmd\"}") || {
    echo "Error: failed to create silence."
    return 1
  }

  local silence_id
  silence_id=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['silenceID'])")

  echo "Alerts silenced for ${duration} (until $(date -d "+${seconds} seconds" +"%H:%M:%S %Z"))."
  echo "Silence ID: ${silence_id}"
  echo "Run './arcuscmd.sh unsilence' to remove."
}

unsilence_alerts() {
  _ensure_grafana_token || return 1

  local silences
  silences=$(_grafana_api GET "/api/alertmanager/grafana/api/v2/silences") || {
    echo "Error: failed to list silences."
    return 1
  }

  local ids
  ids=$(echo "$silences" | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    if s.get('status', {}).get('state') == 'active' and s.get('createdBy') == 'arcuscmd':
        print(s['id'])
")

  if [[ -z "$ids" ]]; then
    echo "No active arcuscmd silences found."
    return 0
  fi

  local count=0
  while IFS= read -r sid; do
    _grafana_api DELETE "/api/alertmanager/grafana/api/v2/silence/${sid}" > /dev/null
    count=$((count + 1))
  done <<< "$ids"

  echo "Removed ${count} silence(s). Alerts are active again."
}
