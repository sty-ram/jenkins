#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# -----------------------------
# CRON-SAFE ENVIRONMENT
# -----------------------------
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# -----------------------------
# Defaults
# -----------------------------
SERVICES_FILE="services.txt"
LOG_FILE="service_check.log"
RESTART=false
DRY_RUN=false
FAILED=0
TMP_FILE="$(mktemp)"
STATE_FILE="/var/tmp/service_tool.state"
LOCK_FILE="/var/tmp/service_tool.lock"
# Allowed hosts
ALLOWED_HOSTS=("ip-10-20-1-198")

# -----------------------------
# Usage
# -----------------------------
usage() {
  echo "Usage: $0 [-f services_file] [-l log_file] [-r] [-D]"
  exit 1
}

# -----------------------------
# Argument parsing
# -----------------------------
while getopts ":f:l:rhD" opt; do
  case "$opt" in
    f) SERVICES_FILE="$OPTARG" ;;
    l) LOG_FILE="$OPTARG" ;;
    r) RESTART=true ;;
    D) DRY_RUN=true ;;
    h) usage ;;
    *) usage ;;
  esac
done

# -----------------------------
# Logging (early)
# -----------------------------
log() {
  printf '%s | %s\n' "$(/bin/date '+%F %T')" "$1"
}

#lock file inisitalization
exec 9>"$LOCK_FILE"

if ! /usr/bin/flock -n 9; then
    log "FATAL | Another instance is allready running"
    exit 6
fi
# Redirect all output (cron hygiene)
exec > >(tee -a "$LOG_FILE") 2>&1

# -----------------------------
# SAFETY GUARDS
# -----------------------------
HOSTNAME="$(/bin/hostname)"

if [[ ! " ${ALLOWED_HOSTS[*]} " =~ " ${HOSTNAME} " ]]; then
  log "FATAL | Script not allowed on host: $HOSTNAME"
  exit 4
fi

if [[ ! -f "$SERVICES_FILE" ]]; then
  log "FATAL | Services file not found: $SERVICES_FILE"
  exit 2
fi

if [[ ! -s "$SERVICES_FILE" ]]; then
  log "FATAL | Services file is empty"
  exit 5
fi

if $RESTART && [[ $(/usr/bin/id -u) -ne 0 ]]; then
  log "FATAL | Restart mode requires root privileges"
  exit 3
fi

# -----------------------------
# Cleanup & traps
# -----------------------------
cleanup() {
  [[ -f "$TMP_FILE" ]] && /bin/rm -f "$TMP_FILE"
}

trap cleanup EXIT
trap 'log "ERROR | Script failed on line $LINENO"; exit 1' ERR
trap 'log "INTERRUPTED | Script stopped by user"; exit 130' INT

# -----------------------------
# Helper functions
# -----------------------------
is_installed() {
  /bin/systemctl show "$1" -p LoadState --value 2>/dev/null | /bin/grep -qx loaded
}

is_running() {
  /bin/systemctl is-active --quiet "$1"
}

restart_service() {
  /bin/systemctl restart "$1"
}

retry() {
  local max_attempts="$1"
  local delay="$2"
  shift 2

  local attempt=1

  while true; do
    if "$@"; then
      return 0
    fi

    if (( attempt >= max_attempts )); then
      log "ERROR | Command failed after $attempt attempts: $*"
      return 1
    fi

    log "WARN | Attempt $attempt failed. Retrying in ${delay}s..."
    /bin/sleep "$delay"
    ((attempt++))
  done
}

# -----------------------------
# Idempotency helpers
# -----------------------------
mark_restarted() {
  echo "$1" >> "$STATE_FILE"
}

was_restarted() {
  /bin/grep -qx "$1" "$STATE_FILE" 2>/dev/null
}

# Reset state if older than 1 hour
if [[ -f "$STATE_FILE" ]]; then
  if (( $(/bin/date +%s) - $(/bin/stat -c %Y "$STATE_FILE") > 3600 )); then
    /bin/rm -f "$STATE_FILE"
  fi
fi

# -----------------------------
# Prepare temp file
# -----------------------------
/bin/cp "$SERVICES_FILE" "$TMP_FILE"

# -----------------------------
# Main loop
# -----------------------------
while IFS= read -r svc || [[ -n "$svc" ]]; do
  svc="${svc//$'\r'/}"
  svc="${svc#"${svc%%[![:space:]]*}"}"
  svc="${svc%"${svc##*[![:space:]]}"}"

  [[ -z "$svc" ]] && continue

  if is_installed "$svc"; then
    if is_running "$svc"; then
      log "OK | $svc running"
    else
      if $DRY_RUN; then
        log "DRY-RUN | Would restart $svc"
      elif $RESTART; then
        if was_restarted "$svc"; then
          log "SKIP | $svc already restarted recently"
        else
          log "RESTARTING | $svc"
          if retry 3 2 restart_service "$svc"; then
            mark_restarted "$svc"
            FAILED=1
          else
            log "ERROR | $svc failed to restart after retries"
            exit 1
          fi
        fi
      else
        log "DOWN | $svc (restart disabled)"
      fi
    fi
  else
    log "SKIPPED | $svc not installed"
  fi
done < "$TMP_FILE"

exit "$FAILED"
