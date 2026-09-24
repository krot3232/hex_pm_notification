#!/usr/bin/env bash
# Checks hex.pm for new package versions and sends notifications
# to stdout and (if configured) to Telegram. Intended to run from cron.
#
# Settings (env or the CONFIG_FILE, which is sourced):
#   PACKAGES_FILE        list of packages, one per line, '#' starts a comment
#   STATE_FILE           state file, "<package> <version>" per line
#   INCLUDE_PRERELEASE   1 - track pre-releases (latest_version), otherwise latest_stable_version
#   TELEGRAM_BOT_TOKEN   bot token; Telegram is disabled without it and TELEGRAM_CHAT_ID
#   TELEGRAM_CHAT_ID     chat id
#   HEX_API_URL          base API URL (for tests)
#   TELEGRAM_API_URL     base Telegram Bot API URL (for tests)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/hex_pm_notification.conf}"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

PACKAGES_FILE="${PACKAGES_FILE:-$SCRIPT_DIR/packages.txt}"
STATE_FILE="${STATE_FILE:-$SCRIPT_DIR/state.txt}"
INCLUDE_PRERELEASE="${INCLUDE_PRERELEASE:-0}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
HEX_API_URL="${HEX_API_URL:-https://hex.pm/api}"
TELEGRAM_API_URL="${TELEGRAM_API_URL:-https://api.telegram.org}"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

err() {
  log "ERROR: $*" >&2
}

# Prints the latest version of a package or returns a non-zero code.
# --retry covers network failures, 5xx and 429 (hex.pm limit is 100 requests per minute)
fetch_latest_version() {
  local package="$1" json filter
  json="$(curl -fsS -m 30 --retry 3 -H 'Accept: application/json' "$HEX_API_URL/packages/$package")" || return 1
  if [[ "$INCLUDE_PRERELEASE" == "1" ]]; then
    filter='.latest_version // empty'
  else
    # Packages without stable releases have latest_stable_version == null.
    filter='.latest_stable_version // .latest_version // empty'
  fi
  jq -er "$filter" <<<"$json"
}

send_telegram() {
  local text="$1" response status body description
  [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]] || return 0
  response="$(exec 9>&-; curl -sS -m 30 -w '\n%{http_code}' \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
    --data-urlencode "text=$text" \
    --data-urlencode "disable_web_page_preview=true" \
    "$TELEGRAM_API_URL/bot$TELEGRAM_BOT_TOKEN/sendMessage")" || return 1
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$status" != 2?? ]]; then
    # Telegram description =error
    description="$(jq -r '.description // empty' <<<"$body" 2>/dev/null || true)"
    err "telegram: HTTP $status${description:+: $description}"
    return 1
  fi
}

version_gt() {
  jq -en --arg new "$1" --arg old "$2" '
    def key:
      sub("\\+.*$"; "")
      | capture("^(?<core>\\d+\\.\\d+\\.\\d+)(?:-(?<pre>.+))?$")
      | [(.core | split(".") | map(tonumber)),
         (if .pre then [0, (.pre | split(".") | map(if test("^\\d+$") then tonumber else . end))]
          else [1] end)];
    ($new | key) > ($old | key)' >/dev/null 2>&1
}

save_state() {
  local name
  STATE_TMP="$(mktemp "$STATE_FILE.XXXXXX")"
  for name in "${!state[@]}"; do
    printf '%s %s\n' "$name" "${state[$name]}"
  done | sort >"$STATE_TMP"
  mv "$STATE_TMP" "$STATE_FILE"
  STATE_TMP=""
}

notify() {
  local package="$1" old="$2" new="$3" text
  # 📦 = EMOJI_PACKAGE
  text="📦 $package: $old → $new
https://hex.pm/packages/$package/$new"
  log "NEW $package $old -> $new"
  send_telegram "$text"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

require_commands() {
  local command
  for command in curl jq flock sort mktemp; do
    if ! command -v "$command" >/dev/null 2>&1; then
      err "required command not found: $command"
      return 1
    fi
  done
}

main() {
  require_commands
  if [[ ! -f "$PACKAGES_FILE" ]]; then
    err "packages file not found: $PACKAGES_FILE"
    return 1
  fi
  exec 9>"$STATE_FILE.lock"
  if ! flock -n 9; then
    err "another instance is running"
    return 1
  fi

  STATE_TMP=""
  trap 'rm -f "${STATE_TMP:-}"' EXIT

  touch "$STATE_FILE"
  declare -A state=()
  local name version
  while read -r name version || [[ -n "$name" ]]; do
    name="${name%$'\r'}"
    version="${version%$'\r'}"
    [[ -n "$name" ]] && state["$name"]="$version"
  done <"$STATE_FILE"

  local line package latest old cmp failed=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    package="${line%%#*}"
    package="$(trim "$package")"
    [[ -z "$package" ]] && continue

    if ! latest="$(exec 9>&-; fetch_latest_version "$package")"; then
      err "failed to fetch $package"
      failed=1
      continue
    fi

    old="${state[$package]:-}"
    if [[ -z "$old" ]]; then
      # First time we see this package: remember it without notifying.
      log "TRACK $package $latest"
      state["$package"]="$latest"
      save_state
    elif [[ "$old" != "$latest" ]]; then
      cmp=0
      version_gt "$latest" "$old" || cmp=$?
      if ((cmp == 1)); then
        # Rollback (reverted publish) or INCLUDE_PRERELEASE turned off:
        # keep the old version so we do not notify about a downgrade.
        log "IGNORE $package $latest (older than $old)"
        continue
      fi
      ((cmp == 0)) || log "WARN $package: cannot compare $old and $latest as semver"
      # Update the state only after a successful send, so a failure is retried next run.
      # Save right away so an interrupted run does not send the notification again.
      if notify "$package" "$old" "$latest"; then
        state["$package"]="$latest"
        save_state
      else
        err "failed to send notification for $package"
        failed=1
      fi
    fi
  done <"$PACKAGES_FILE"

  return "$failed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
