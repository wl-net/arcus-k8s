# shellcheck shell=bash
# Route 53 traffic management functions

function _route53_change_weight() {
  local record_name=$1 record_value=$2 record_type=$3 record_ttl=$4 new_weight=$5
  local change_batch
  change_batch=$(cat <<ENDJSON
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${record_name}",
      "Type": "${record_type}",
      "SetIdentifier": "${ARCUS_ROUTE53_SET_ID}",
      "Weight": ${new_weight},
      "TTL": ${record_ttl},
      "ResourceRecords": [{"Value": "${record_value}"}]
    }
  }]
}
ENDJSON
)
  aws route53 change-resource-record-sets \
    --hosted-zone-id "$ARCUS_ROUTE53_ZONE_ID" \
    --change-batch "$change_batch"
}

function route53_drain() {
  load

  if [[ "${ARCUS_CERT_SOLVER:-}" != "dns" ]]; then
    echo "Error: drain requires cert-solver=dns (Route 53 must be configured)."
    echo "Run './arcuscmd.sh configure' and select the dns cert solver."
    return 1
  fi

  if [[ -z "${ARCUS_ROUTE53_SET_ID:-}" ]]; then
    echo "Error: .config/route53-set-identifier is not set."
    echo "Run './arcuscmd.sh configure' or write the set identifier to .config/route53-set-identifier."
    return 1
  fi

  if ! command -v aws &>/dev/null; then
    echo "Error: aws CLI not found. Install it to use drain/resume."
    return 1
  fi

  export AWS_ACCESS_KEY_ID
  AWS_ACCESS_KEY_ID=$(cat secret/route53-access-key-id)
  export AWS_SECRET_ACCESS_KEY
  AWS_SECRET_ACCESS_KEY=$(cat secret/route53-secret-access-key)
  export AWS_DEFAULT_REGION="$ARCUS_ROUTE53_REGION"

  local record
  record=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$ARCUS_ROUTE53_ZONE_ID" \
    --query "ResourceRecordSets[?SetIdentifier=='${ARCUS_ROUTE53_SET_ID}']" \
    --output json)

  local count
  count=$(echo "$record" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
  if [[ "$count" -eq 0 ]]; then
    echo "Error: no Route 53 record found with set identifier '${ARCUS_ROUTE53_SET_ID}'"
    return 1
  fi

  local record_name record_value record_type record_ttl current_weight
  record_name=$(echo "$record" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['Name'])")
  record_type=$(echo "$record" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['Type'])")
  record_ttl=$(echo "$record" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['TTL'])")
  record_value=$(echo "$record" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['ResourceRecords'][0]['Value'])")
  current_weight=$(echo "$record" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['Weight'])")

  if [[ "$current_weight" -eq 0 ]]; then
    echo "Record ${record_name} (set: ${ARCUS_ROUTE53_SET_ID}) is already at weight 0."
    return 0
  fi

  mkdir -p .cache
  echo "$current_weight" > .cache/route53-saved-weight

  _route53_change_weight "$record_name" "$record_value" "$record_type" "$record_ttl" 0
  echo "Drained: ${record_name} (set: ${ARCUS_ROUTE53_SET_ID}) weight ${current_weight} -> 0"
  echo "Saved previous weight to .cache/route53-saved-weight"
  echo "Run './arcuscmd.sh resume' to restore traffic."
}

function route53_resume() {
  load

  if [[ "${ARCUS_CERT_SOLVER:-}" != "dns" ]]; then
    echo "Error: resume requires cert-solver=dns (Route 53 must be configured)."
    echo "Run './arcuscmd.sh configure' and select the dns cert solver."
    return 1
  fi

  if [[ -z "${ARCUS_ROUTE53_SET_ID:-}" ]]; then
    echo "Error: .config/route53-set-identifier is not set."
    echo "Run './arcuscmd.sh configure' or write the set identifier to .config/route53-set-identifier."
    return 1
  fi

  if [[ ! -f .cache/route53-saved-weight ]]; then
    echo "Error: no saved weight found (.cache/route53-saved-weight)."
    echo "Was this cluster previously drained with './arcuscmd.sh drain'?"
    return 1
  fi

  if ! command -v aws &>/dev/null; then
    echo "Error: aws CLI not found. Install it to use drain/resume."
    return 1
  fi

  local saved_weight
  saved_weight=$(cat .cache/route53-saved-weight)

  export AWS_ACCESS_KEY_ID
  AWS_ACCESS_KEY_ID=$(cat secret/route53-access-key-id)
  export AWS_SECRET_ACCESS_KEY
  AWS_SECRET_ACCESS_KEY=$(cat secret/route53-secret-access-key)
  export AWS_DEFAULT_REGION="$ARCUS_ROUTE53_REGION"

  local record
  record=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$ARCUS_ROUTE53_ZONE_ID" \
    --query "ResourceRecordSets[?SetIdentifier=='${ARCUS_ROUTE53_SET_ID}']" \
    --output json)

  local count
  count=$(echo "$record" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
  if [[ "$count" -eq 0 ]]; then
    echo "Error: no Route 53 record found with set identifier '${ARCUS_ROUTE53_SET_ID}'"
    return 1
  fi

  local record_name record_value record_type record_ttl
  record_name=$(echo "$record" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['Name'])")
  record_type=$(echo "$record" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['Type'])")
  record_ttl=$(echo "$record" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['TTL'])")
  record_value=$(echo "$record" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['ResourceRecords'][0]['Value'])")

  _route53_change_weight "$record_name" "$record_value" "$record_type" "$record_ttl" "$saved_weight"
  rm .cache/route53-saved-weight
  echo "Resumed: ${record_name} (set: ${ARCUS_ROUTE53_SET_ID}) weight 0 -> ${saved_weight}"
}
