service_tool.sh                                                                                              
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# -----------------------------
# Defaults
# -----------------------------
SERVICES_FILE="services.txt"
LOG_FILE="service_check.log"
RESTART=false
FAILED=0
TMP_FILE="$(mktemp)"

ALLOWED_HOSTS=("ip-10-20-1-198")
# -----------------------------
# Usage
# -----------------------------
usage() {
  echo "Usage: $0 [-f services_file] [-l log_file] [-r]"
  exit 1
}

# -----------------------------
# Argument parsing
# -----------------------------
while getopts ":f:l:rh" opt; do
  case "$opt" in
    f) SERVICES_FILE="$OPTARG" ;;
    l) LOG_FILE="$OPTARG" ;;
    r) RESTART=true ;;
    h) usage ;;
    *) usage ;;
  esac
done
# -----------------------------
log() {
  printf '%s | %s\n' "$(date '+%F %T')" "$1" | tee -a "$LOG_FILE"
}

# -----------------------------
# SAFEGUARD
# -----------------------------
# gurde 1: Host allowlist
HOSTNAME="$(hostname)"
if [[ ! " ${ALLOWED_HOSTS[*]} " =~ " ${HOSTNAME} " ]]; then
  log "FATAL | Script no allowed on host: ${HOSTNAME}"
  exit 4
  fi
# Guarde 2: Services file existence
if [[ ! -f "$SERVICES_FILE" ]]; then
  log "FATAL | Services file not found: $SERVICES_FILE"
  exit 2
fi
# Guarde 3: Services file not empty
if [[ ! -s "$SERVICES_FILE" ]]; then
    log "FATAL | Services file is empty: $SERVICES_FILE"
    exit 5
fi
# Guarde 4: Restart mode requries root
if $RESTART && [[ "$(id -u)" -ne 0 ]]; then
    log "FATAL | Restart mode requires root privileges."
    exit 3
fi

# Validation
# -----------------------------
if [[ ! -f "$SERVICES_FILE" ]]; then
  echo "❌ Services file not found: $SERVICES_FILE"
  exit 2
fi

# -----------------------------
# Cleanup & traps
#  -----------------------------
cleanup() {
    [[ -f "$TMP_FILE" ]] && rm -f "$TMP_FILE"
}
trap cleanup EXIT
trap 'lod "error | Script failed on line $LINENO" exit 1' ERR
trap 'log "INTERRUPTED | Script stopped by user"; exit 130' INT

# -----------------------------
#Helper functions
# -----------------------------
# Installed = unit exists (even if stopped)
is_installed() {
  systemctl show "$1" -p LoadState --value 2>/dev/null | grep -qx loaded
}

# Running = active
is_running() {
  systemctl is-active --quiet "$1"
}

restart_service() {
  systemctl restart "$1"
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
    sleep "$delay"
    ((attempt++))
  done
}

# -----------------------------
# Prepare temp file
# -----------------------------
cp "$SERVICES_FILE" "$TMP_FILE"

# -----------------------------
# Main loop
# -----------------------------
while IFS= read -r svc || [[ -n "$svc" ]]; do
  # sanitize input
  svc="${svc//$'\r'/}"
  svc="${svc#"${svc%%[![:space:]]*}"}"
  svc="${svc%"${svc##*[![:space:]]}"}"

  [[ -z "$svc" ]] && continue

  if is_installed "$svc"; then
    if is_running "$svc"; then
      log "OK | $svc running"
    else
      if $RESTART; then
        log "RESTARTING | $svc"
        if retry 3 2 restart_service "$svc"; then
          FAILED=1
        else
          log "ERROR | $svc failed to restart after retries"
          exit 1
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