# shellcheck shell=bash
# Configuration and verification functions

function configure() {
  load
  ARCUS_ADMIN_EMAIL=${ARCUS_ADMIN_EMAIL:-me@example.com}
  ARCUS_DOMAIN_NAME=${ARCUS_DOMAIN_NAME:-example.com}
  ARCUS_SUBNET=${ARCUS_SUBNET:-unconfigured}
  ARCUS_CERT_TYPE=${ARCUS_CERT_TYPE:-staging}
  ARCUS_PROXY_REAL_IP=${ARCUS_PROXY_REAL_IP:-}
  ARCUS_ADMIN_DOMAIN=${ARCUS_ADMIN_DOMAIN:-}

  if [ "$ARCUS_ADMIN_EMAIL" = "me@example.com" ]; then
    prompt ARCUS_ADMIN_EMAIL "Please enter your admin email address (or set ARCUS_ADMIN_EMAIL): "
  fi
  echo "$ARCUS_ADMIN_EMAIL" > "$ARCUS_CONFIGDIR/admin.email"

  if [ "$ARCUS_DOMAIN_NAME" = "example.com" ]; then
    prompt ARCUS_DOMAIN_NAME "Please enter your domain name (or set ARCUS_DOMAIN_NAME): "
  fi
  echo "$ARCUS_DOMAIN_NAME" > "$ARCUS_CONFIGDIR/domain.name"

  if [[ -z "$ARCUS_PROXY_REAL_IP" ]]; then
    local use_proxy
    prompt use_proxy "Is traffic arriving via a proxy that sends PROXY protocol (e.g. HAProxy, cloud LB)? [yes/no]:"
    if [[ "$use_proxy" == "yes" ]]; then
      prompt ARCUS_PROXY_REAL_IP "Enter upstream proxy IP/subnet (e.g. 192.168.1.1/32): "
      echo "$ARCUS_PROXY_REAL_IP" > "$ARCUS_CONFIGDIR/proxy-real-ip"
    fi
  fi

  if [[ -z "$ARCUS_ADMIN_DOMAIN" ]]; then
    local use_admin
    prompt use_admin "Do you have a separate admin (Grafana) domain? [yes/no]:"
    if [[ "$use_admin" == "yes" ]]; then
      prompt ARCUS_ADMIN_DOMAIN "Enter admin domain (e.g. admin.arcus-dc1.example.com): "
      echo "$ARCUS_ADMIN_DOMAIN" > "$ARCUS_CONFIGDIR/admin-domain"
    fi
  fi

  if [[ -z "${ARCUS_METALLB:-}" ]]; then
    # Auto-detect: if MetalLB is already running, default to yes and read its subnet
    if $KUBECTL get deployment -n metallb-system controller &>/dev/null; then
      ARCUS_METALLB="yes"
      echo "MetalLB detected in cluster — enabling automatically."
      if [[ "$ARCUS_SUBNET" == "unconfigured" ]]; then
        local detected_subnet
        detected_subnet=$($KUBECTL get ipaddresspool -n metallb-system arcus-pool -o jsonpath='{.spec.addresses[0]}' 2>/dev/null) || true
        if [[ -n "$detected_subnet" ]]; then
          ARCUS_SUBNET="$detected_subnet"
          echo "  Using existing subnet: $ARCUS_SUBNET"
          echo "$ARCUS_SUBNET" > "$ARCUS_CONFIGDIR/subnet"
        fi
      fi
    else
      local use_metallb
      prompt use_metallb "Do you need MetalLB for load balancer IPs? [yes/no]:"
      if [[ "$use_metallb" == "yes" ]]; then
        ARCUS_METALLB="yes"
      else
        ARCUS_METALLB="no"
      fi
    fi
    echo "$ARCUS_METALLB" > "$ARCUS_CONFIGDIR/metallb"
  fi

  if [[ "$ARCUS_METALLB" == "yes" && "$ARCUS_SUBNET" == "unconfigured" ]]; then
    echo "MetalLB requires a pre-defined subnet for services to be served behind. This subnet must be unallocated (e.g. no IP addresses are used, *and* reserved for static clients)."
    echo "Examples: 192.168.1.200/29, 192.168.1.200-192.168.1.207"
    prompt ARCUS_SUBNET "Please enter your subnet for Arcus services to be exposed on (or set ARCUS_SUBNET): "
    echo "$ARCUS_SUBNET" > "$ARCUS_CONFIGDIR/subnet"
  fi

  echo "$ARCUS_CERT_TYPE" > "$ARCUS_CONFIGDIR/cert-issuer"

  if [[ -z "${ARCUS_CERT_SOLVER:-}" ]]; then
    local cert_solver
    prompt cert_solver "Certificate solver type — http (default) or dns (Route 53 DNS-01): "
    cert_solver="${cert_solver:-http}"
    if [[ "$cert_solver" != "http" && "$cert_solver" != "dns" ]]; then
      echo "Invalid solver type '$cert_solver', using http"
      cert_solver="http"
    fi
    ARCUS_CERT_SOLVER="$cert_solver"
    echo "$ARCUS_CERT_SOLVER" > "$ARCUS_CONFIGDIR/cert-solver"
  fi

  if [[ "${ARCUS_CERT_SOLVER}" == "dns" ]]; then
    if [[ -z "${ARCUS_ROUTE53_ZONE_ID:-}" ]]; then
      prompt ARCUS_ROUTE53_ZONE_ID "Enter Route 53 hosted zone ID: "
      echo "$ARCUS_ROUTE53_ZONE_ID" > "$ARCUS_CONFIGDIR/route53-hosted-zone-id"
    fi
    if [[ -z "${ARCUS_ROUTE53_REGION:-}" ]]; then
      prompt ARCUS_ROUTE53_REGION "Enter AWS region for Route 53 (e.g. us-east-1): "
      echo "$ARCUS_ROUTE53_REGION" > "$ARCUS_CONFIGDIR/route53-region"
    fi
    if [[ -z "${ARCUS_ROUTE53_SET_ID:-}" ]]; then
      local use_set_id
      prompt use_set_id "Do you use Route 53 weighted records for multi-cluster failover? [yes/no]:"
      if [[ "$use_set_id" == "yes" ]]; then
        prompt ARCUS_ROUTE53_SET_ID "Enter this cluster's Route 53 set identifier: "
        echo "$ARCUS_ROUTE53_SET_ID" > "$ARCUS_CONFIGDIR/route53-set-identifier"
      fi
    fi
  fi

  mkdir -p secret

  if [[ "${ARCUS_CERT_SOLVER:-}" == "dns" ]]; then
    if [[ ! -e secret/route53-access-key-id ]]; then
      local r53_key_id
      prompt r53_key_id "Enter AWS access key ID for Route 53: "
      echo -n "$r53_key_id" > secret/route53-access-key-id
    fi
    if [[ ! -e secret/route53-secret-access-key ]]; then
      local r53_secret_key
      prompt r53_secret_key "Enter AWS secret access key for Route 53: "
      echo -n "$r53_secret_key" > secret/route53-secret-access-key
    fi
  fi
  if [[ ! -e secret/billing.api.key ]]; then
    echo "Setting up default secret for billing.api.key"
    echo -n "12345" > secret/billing.api.key
  fi

  if [[ ! -e secret/billing.public.api.key ]]; then
    echo "Setting up default secret for billing.public.api.key"
    echo -n "12345" > secret/billing.public.api.key
  fi

  if [[ ! -e secret/iris.aes.iv ]]; then
    echo "Generating secret for iris.aes.iv"
    openssl rand -base64 8 | tr -d '\n' > secret/iris.aes.iv
  fi

  if [[ ! -e secret/iris.aes.secret ]]; then
    echo "Generating secret for iris.aes.secret"
    openssl rand -base64 32 | tr -d '\n' > secret/iris.aes.secret
  fi

  if [[ ! -e secret/questions.aes.secret ]]; then
    echo "Generating secret for questions.aes.secret"
    openssl rand -base64 32 | tr -d '\n' > secret/questions.aes.secret
  fi

  if [[ ! -e secret/smarty.auth.id ]]; then
    echo "Setting up default secret for smarty.auth.id"
    echo -n "12345" > secret/smarty.auth.id
  fi

  if [[ ! -e secret/smarty.auth.token ]]; then
    echo "Setting up default secret for smarty.auth.token"
    echo -n "12345" > secret/smarty.auth.token
  fi

  if [[ ! -e secret/tls.server.truststore.password ]]; then
    echo "Using *KNOWN DEFAULT* secret for tls.server.truststore.password"
    # note: the utility of truststore and keystore passwords is quesitonable.
    echo -n "8EFJhxm7aRs2hmmKwVuM9RPSwhNCtMpC" > secret/tls.server.truststore.password
  fi

  if [[ ! -e secret/apns.pkcs12.password ]]; then
    echo "Using *KNOWN DEFAULT* secret for apns.pkcs12.password"
    # note: the utility of truststore and keystore passwords is quesitonable.
    echo -n "8EFJhxm7aRs2hmmKwVuM9RPSwhNCtMpC" > secret/apns.pkcs12.password
  fi

  local authid authtoken apikey twilio_auth twilio_sid twilio_from skip_creds

  # Check if any external credentials still need configuration
  local needs_smarty=0 needs_sendgrid=0 needs_twilio=0
  [[ ! -e secret/smartystreets.authid || ! -e secret/smartystreets.authtoken ]] && needs_smarty=1
  [[ ! -e secret/email.provider.apikey ]] && needs_sendgrid=1
  [[ ! -e secret/twilio.account.auth || ! -e secret/twilio.account.sid || ! -e secret/twilio.account.from ]] && needs_twilio=1

  if [[ $((needs_smarty + needs_sendgrid + needs_twilio)) -gt 0 ]]; then
    echo ""
    echo "Arcus uses external services for address verification, email, and SMS."
    echo "You can configure these now, or skip and come back later with './arcuscmd.sh configure'."
    prompt skip_creds "Configure external service credentials now? [yes/no]:"
  else
    skip_creds="done"
  fi

  if [[ "$skip_creds" == "yes" ]]; then
    if [[ $needs_smarty -eq 1 ]]; then
      echo ""
      echo "SmartyStreets is required for address verification (https://smartystreets.com/)."
      echo "Create secret keys — these are only used on the server, never exposed to users."

      if [[ ! -e secret/smartystreets.authid ]]; then
        prompt authid "Please enter your smartystreets authid:"
        echo -n "$authid" > secret/smartystreets.authid
      fi

      if [[ ! -e secret/smartystreets.authtoken ]]; then
        prompt authtoken "Please enter your smartystreets authtoken:"
        echo -n "$authtoken" > secret/smartystreets.authtoken
      fi
    fi

    if [[ $needs_sendgrid -eq 1 ]]; then
      echo ""
      echo "Sendgrid is required for email notifications."

      if [[ ! -e secret/email.provider.apikey ]]; then
        prompt apikey "Please enter your sendgrid API key:"
        echo -n "$apikey" > secret/email.provider.apikey
      fi
    fi

    if [[ $needs_twilio -eq 1 ]]; then
      echo ""
      echo "Twilio is required for SMS/voice notifications."

      if [[ ! -e secret/twilio.account.auth ]]; then
        prompt twilio_auth "Please enter your twilio auth:"
        echo -n "$twilio_auth" > secret/twilio.account.auth
      fi

      if [[ ! -e secret/twilio.account.sid ]]; then
        prompt twilio_sid "Please enter your twilio sid:"
        echo -n "$twilio_sid" > secret/twilio.account.sid
      fi

      if [[ ! -e secret/twilio.account.from ]]; then
        prompt twilio_from "Please enter your twilio phone number:"
        echo -n "$twilio_from" > secret/twilio.account.from
      fi
    fi
  elif [[ "$skip_creds" != "done" ]]; then
    echo "Skipping external service credentials. Run './arcuscmd.sh configure' when you're ready to set them up."
  fi
}

function verify_config() {
  load

  local errors=0
  local warnings=0

  echo "Verifying Arcus configuration..."
  echo

  # --- Required .config files ---
  echo "=== Node Configuration (.config/) ==="

  for file in domain.name admin.email cert-issuer; do
    if [[ ! -f "$ARCUS_CONFIGDIR/$file" ]]; then
      echo "  MISSING: .config/$file (required)"
      ((errors++))
    elif [[ ! -s "$ARCUS_CONFIGDIR/$file" ]]; then
      echo "  EMPTY:   .config/$file (required)"
      ((errors++))
    else
      echo "  OK:      .config/$file = $(cat "$ARCUS_CONFIGDIR/$file")"
    fi
  done

  # overlay-name defaults to local-production in load(), so missing is fine but we still report it
  if [[ -f "$ARCUS_CONFIGDIR/overlay-name" ]]; then
    echo "  OK:      .config/overlay-name = $(cat "$ARCUS_CONFIGDIR/overlay-name")"
  else
    echo "  DEFAULT: .config/overlay-name (using local-production)"
  fi

  # subnet is required when MetalLB is enabled
  if [[ "${ARCUS_METALLB:-}" == "yes" ]]; then
    if [[ ! -f "$ARCUS_CONFIGDIR/subnet" ]]; then
      echo "  MISSING: .config/subnet (required when MetalLB is enabled)"
      ((errors++))
    elif [[ ! -s "$ARCUS_CONFIGDIR/subnet" ]]; then
      echo "  EMPTY:   .config/subnet (required when MetalLB is enabled)"
      ((errors++))
    else
      echo "  OK:      .config/subnet = $(cat "$ARCUS_CONFIGDIR/subnet")"
    fi
  fi

  # metallb config
  if [[ -f "$ARCUS_CONFIGDIR/metallb" ]]; then
    echo "  OK:      .config/metallb = $(cat "$ARCUS_CONFIGDIR/metallb")"
  else
    echo "  DEFAULT: .config/metallb (MetalLB not configured — run configure to set)"
  fi

  # Optional config files
  for file in proxy-real-ip cassandra-host zookeeper-host kafka-host admin-domain cert-solver; do
    if [[ -f "$ARCUS_CONFIGDIR/$file" ]]; then
      echo "  OK:      .config/$file = $(cat "$ARCUS_CONFIGDIR/$file")"
    fi
  done

  # Route 53 config (required when cert-solver=dns)
  if [[ "${ARCUS_CERT_SOLVER:-}" == "dns" ]]; then
    for file in route53-hosted-zone-id route53-region; do
      if [[ ! -f "$ARCUS_CONFIGDIR/$file" ]]; then
        echo "  MISSING: .config/$file (required when cert-solver=dns)"
        ((errors++))
      elif [[ ! -s "$ARCUS_CONFIGDIR/$file" ]]; then
        echo "  EMPTY:   .config/$file (required when cert-solver=dns)"
        ((errors++))
      else
        echo "  OK:      .config/$file = $(cat "$ARCUS_CONFIGDIR/$file")"
      fi
    done
    # Optional: set identifier for multi-cluster weighted records
    if [[ -f "$ARCUS_CONFIGDIR/route53-set-identifier" ]]; then
      echo "  OK:      .config/route53-set-identifier = $(cat "$ARCUS_CONFIGDIR/route53-set-identifier")"
    fi
  fi

  echo

  # --- Validate config values ---
  echo "=== Value Checks ==="

  if [[ "${ARCUS_DOMAIN_NAME:-}" == "example.com" ]]; then
    echo "  ERROR:   domain.name is still the placeholder (example.com)"
    ((errors++))
  elif [[ -n "${ARCUS_DOMAIN_NAME:-}" ]]; then
    echo "  OK:      domain.name looks valid"
  fi

  if [[ "${ARCUS_ADMIN_EMAIL:-}" == "me@example.com" ]]; then
    echo "  ERROR:   admin.email is still the placeholder (me@example.com)"
    ((errors++))
  elif [[ -n "${ARCUS_ADMIN_EMAIL:-}" ]]; then
    echo "  OK:      admin.email looks valid"
  fi

  if [[ -n "${ARCUS_CERT_TYPE:-}" ]]; then
    if [[ "$ARCUS_CERT_TYPE" != "staging" && "$ARCUS_CERT_TYPE" != "production" ]]; then
      echo "  ERROR:   cert-issuer has invalid value '$ARCUS_CERT_TYPE' (must be staging or production)"
      ((errors++))
    else
      echo "  OK:      cert-issuer = $ARCUS_CERT_TYPE"
    fi
  fi

  # Check that the overlay directory exists
  if [[ ! -d "overlays/${ARCUS_OVERLAY_NAME}" ]]; then
    echo "  ERROR:   overlay directory overlays/${ARCUS_OVERLAY_NAME} does not exist"
    ((errors++))
  else
    echo "  OK:      overlay directory overlays/${ARCUS_OVERLAY_NAME} exists"
  fi

  echo

  # --- Secrets ---
  echo "=== Secrets (secret/) ==="

  local required_secrets=(
    billing.api.key
    billing.public.api.key
    iris.aes.iv
    iris.aes.secret
    questions.aes.secret
    smarty.auth.id
    smarty.auth.token
    tls.server.truststore.password
    apns.pkcs12.password
    smartystreets.authid
    smartystreets.authtoken
    email.provider.apikey
    twilio.account.auth
    twilio.account.sid
    twilio.account.from
  )

  if [[ ! -d secret ]]; then
    echo "  MISSING: secret/ directory does not exist"
    ((errors += ${#required_secrets[@]}))
  else
    for s in "${required_secrets[@]}"; do
      if [[ ! -f "secret/$s" ]]; then
        echo "  MISSING: secret/$s"
        ((errors++))
      elif [[ ! -s "secret/$s" ]]; then
        echo "  EMPTY:   secret/$s"
        ((errors++))
      else
        echo "  OK:      secret/$s"
      fi
    done
  fi

  # Route 53 secrets (required when cert-solver=dns)
  if [[ "${ARCUS_CERT_SOLVER:-}" == "dns" ]]; then
    for s in route53-access-key-id route53-secret-access-key; do
      if [[ ! -f "secret/$s" ]]; then
        echo "  MISSING: secret/$s (required when cert-solver=dns)"
        ((errors++))
      elif [[ ! -s "secret/$s" ]]; then
        echo "  EMPTY:   secret/$s (required when cert-solver=dns)"
        ((errors++))
      else
        echo "  OK:      secret/$s"
      fi
    done
  fi

  # Warn about placeholder secrets
  for s in smarty.auth.id smarty.auth.token billing.api.key billing.public.api.key; do
    if [[ -f "secret/$s" ]] && [[ "$(cat "secret/$s")" == "12345" ]]; then
      echo "  WARNING: secret/$s still has the default placeholder value"
      ((warnings++))
    fi
  done

  echo
  echo "=== Summary ==="
  if [[ $errors -eq 0 && $warnings -eq 0 ]]; then
    echo "  Configuration is complete. No issues found."
  else
    [[ $warnings -gt 0 ]] && echo "  $warnings warning(s)"
    [[ $errors -gt 0 ]] && echo "  $errors error(s) — run './arcuscmd.sh configure' to fix"
  fi

  return "$errors"
}
