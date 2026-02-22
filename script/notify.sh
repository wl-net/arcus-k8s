# shellcheck shell=bash
# Discord webhook notifications (opt-in)

# Embed colors (decimal)
_NOTIFY_COLOR_BLUE=3447003
_NOTIFY_COLOR_GREEN=3066993
_NOTIFY_COLOR_RED=15158332
_NOTIFY_COLOR_ORANGE=15105570

# State for the EXIT trap
_NOTIFY_MSG=""
_NOTIFY_START=0
_NOTIFY_HANDLED=0

_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

_format_duration() {
  local secs=$1
  if (( secs >= 60 )); then
    printf '%dm %ds' $((secs / 60)) $((secs % 60))
  else
    printf '%ds' "$secs"
  fi
}

_notify_discord() {
  local message color fields_json
  message=$(_json_escape "$1")
  color="${2:-$_NOTIFY_COLOR_BLUE}"
  fields_json="${3:-}"
  [[ -z "${ARCUS_DISCORD_WEBHOOK:-}" ]] && return 0

  local title rev user footer payload
  title=$(_json_escape "${ARCUS_DOMAIN_NAME:-arcuscmd}")
  rev=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null) || rev="unknown"
  user="${USER:-unknown}"
  footer="$user@$(hostname) • $rev • $(date +"%Y-%m-%d %H:%M:%S %Z")"

  if [[ -n "$fields_json" ]]; then
    payload=$(printf '{"embeds":[{"title":"%s","description":"%s","color":%s,"fields":[%s],"footer":{"text":"%s"}}]}' \
      "$title" "$message" "$color" "$fields_json" "$footer")
  else
    payload=$(printf '{"embeds":[{"title":"%s","description":"%s","color":%s,"footer":{"text":"%s"}}]}' \
      "$title" "$message" "$color" "$footer")
  fi
  curl -sf -X POST -H "Content-Type: application/json" -d "$payload" "$ARCUS_DISCORD_WEBHOOK" &>/dev/null &
}

_notify_start() {
  local message="$1" color="${2:-$_NOTIFY_COLOR_BLUE}"
  _NOTIFY_MSG="$message"
  _NOTIFY_START=$SECONDS
  _NOTIFY_HANDLED=0
  _notify_discord "$message" "$color"
}

_notify_success() {
  local message="$1"
  _NOTIFY_HANDLED=1
  local elapsed duration_field
  elapsed=$(_format_duration $(( SECONDS - _NOTIFY_START )))
  duration_field=$(printf '{"name":"Duration","value":"%s","inline":true}' "$elapsed")
  _notify_discord "$message" "$_NOTIFY_COLOR_GREEN" "$duration_field"
}

_notify_failure() {
  local message="$1"
  _NOTIFY_HANDLED=1
  local elapsed duration_field
  elapsed=$(_format_duration $(( SECONDS - _NOTIFY_START )))
  duration_field=$(printf '{"name":"Duration","value":"%s","inline":true}' "$elapsed")
  _notify_discord "$message" "$_NOTIFY_COLOR_RED" "$duration_field"
}

# Called by the EXIT trap in arcuscmd.sh — posts success/failure for any
# command that called _notify_start but did not explicitly call
# _notify_success or _notify_failure (i.e. most simple commands).
_notify_on_exit() {
  local rc=$?
  [[ -z "${_NOTIFY_MSG:-}" || "${_NOTIFY_HANDLED:-0}" -eq 1 ]] && return
  if [[ $rc -eq 0 ]]; then
    _notify_success "${_NOTIFY_MSG} completed"
  else
    _notify_failure "${_NOTIFY_MSG} failed"
  fi
  wait 2>/dev/null || true
}
