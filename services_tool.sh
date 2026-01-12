#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SERVICES_FILE="services.txt"
LOG_FILE="service_check.log"
RESTART=false
FAILED=0

usage() {
        echo "Usage: $0 [-f sevices_file] [-l log_file] [-r]"
        exit 1
}

while getopts ":f:l:rh" opt; do
        case "$opt" in
        f) SERVICES_FILES="$OPTARG" ;;
        l) LOG_FILE="$OPTARG" ;;
        r) RESTART=true ;;
        h) usage ;;
        *) usage ;;
        esac
done

if [[ ! -f "$SERVICES_FILE" ]]; then
        echo "Services file not found: $SERVICES_FILE"
        exit 2
fi
log() {

        echo "$(date '+%F %T') |$1" | tee -a "$LOG_FILE"
}
is_installed() {
    systemctl status "$1" >/dev/null 2>&1
}

is_running() {
    systemctl is-active --quiet "$1"
}

restart_service() {
    systemctl restart "$1"

}
while read -r svc; do
    svc="$(echo "$svc" | tr -d '\r' | xargs)"
    [[ -z "$svc" ]] && continue

    if  is_installed "$svc"; then
        if is_running "$svc"; then
            log "OK | $svc running"
        else
            if $RESTART; then
                log "RESTARTING | $svc"
                restart_service "$svc"
                FAILED=1
            else
                log "DOWN | $svc (restart disabled)"
            fi
        fi
    else
        log "SKIPPED | $svc"
    fi
done < "$SERVICES_FILE"
exit "$FAILED"