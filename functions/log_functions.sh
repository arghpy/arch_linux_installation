#!/usr/bin/env bash

function log_colors()
{
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    GREEN='\033[0;32m'
    LIGHT_CYAN='\033[0;96m'
    RESET='\033[0m'
}

function log_it()
{
    local LOG_STATUS=''
    local LOG_COLOR=''
    local LOG_MESSAGE="$*"

    case "${LOG_LEVEL_FUNCTION}" in
        "OK")
            LOG_COLOR="${GREEN}"
            LOG_STATUS='SUCCESS'
            ;;
        "WARNING")
            LOG_COLOR="${YELLOW}"
            LOG_STATUS='WARNING'
            ;;
        "ERROR")
            LOG_COLOR="${RED}"
            LOG_STATUS='ERROR'
            ;;
        "INFO")
            LOG_COLOR="${LIGHT_CYAN}"
            LOG_STATUS='INFO'
            ;;
    esac

    DATE="$(date +"%Y-%m-%d %H:%M:%S")"
    if [ -n "${LOG_MESSAGE}" ]; then
        printf "%b[ %-11s ] %s: %s%b\\n" "${LOG_COLOR}" "${LOG_STATUS}" "${DATE}" "${LOG_MESSAGE}" "${RESET}"
    fi
}

log_ok() { LOG_LEVEL_FUNCTION="OK" ; log_it "$*"; }
log_warning() { LOG_LEVEL_FUNCTION="WARNING" ; log_it "$*"; }
log_error() { LOG_LEVEL_FUNCTION="ERROR" ; log_it "$*"; }
log_info() { LOG_LEVEL_FUNCTION="INFO" ; log_it "$*"; }
log_colors
