#!/bin/bash
#
# Copyright(C) 2021 Nicolas NAVARRETE @ ZENETYS
# This script is licensed under MIT License (http://opensource.org/licenses/MIT)
#

PROGNAME=${0##*/}
BASEURL=${BASEURL:-https://veeam.acme.loc:9419}
USERNAME=${USERNAME:-monitoring}
PASSWORD=${PASSWORD:-secret}

function exit_usage() {
    local status=${1:-0}
    [[ "$status" != "0" ]] && exec >&2

    echo "\
Usage: $PROGNAME [OPTION]...
Dump one page of backup history

Options:
    -b, --baseurl   Name of the url
    -u, --username  Authentication username
    -p, --password  Authentication password
    -v, --verbose   Verbose mode
    -h, --help      Display this help
"
    exit "$status"
}

info() {
    echo "$(date +%Y-%m-%dT%H:%M:%S.%3N%:z) $PROGNAME: $*" >&2
}

function _curl() {
    local cmd=(
        curl ${VERBOSE:+-v} -f -s -k -X POST -H  "accept: application/json"
            -H  "x-api-version: 1.3-rev1" "$@"
    )
    if [[ -n $VERBOSE ]]; then
        echo -n "EXEC: "
        printf '%q ' "${cmd[@]}"
        echo
    fi
    "${cmd[@]}"
}

function on_exit() {
    info "Logout..."
    _curl "$BASEURL/api/oauth2/logout" -H "Authorization: Bearer ${TOKEN[1]}" -d "" >/dev/null
}

while (( $# > 0 )); do
    case "$1" in
        -b|--baseurl) BASEURL=$2; shift ;;
        -u|--username) USERNAME=$2; shift ;;
        -p|--password) PASSWORD=$2; shift ;;
        -v|--verbose) VERBOSE=1 ;;
        -h|--help) exit_usage ;;
        *) exit_usage 1 ;;
    esac
    shift
done

info 'Get token...'
TOKEN=($(_curl "$BASEURL/api/oauth2/token" -H "Content-Type: application/x-www-form-urlencoded" \
            -d "grant_type=password&username=$USERNAME&password=$PASSWORD&use_short_term_refresh=" |
                jq -r '"\(.refresh_token)\n\(.access_token)"'))

if [[ $? != 0 || ${TOKEN[0]} == null || -z ${TOKEN[0]} ]]; then
    echo 'Login error!'
    exit 1
fi

# TOKEN[0] .refresh_token
# TOKEN[1] .access_token

trap on_exit EXIT

info 'Refresh token...'
_curl "$BASEURL/api/oauth2/token" -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=refresh_token&username=&password=&refresh_token=${TOKEN[0]}&use_short_term_refresh=" \
        >/dev/null

if [[ $? != 0 ]]; then
    echo 'Refresh token failed!'
    exit 1
fi

info 'Get backup history...'
_curl -X GET "$BASEURL/api/v1/sessions" -H "Authorization: Bearer ${TOKEN[1]}"  |jq .

if [[ $? != 0 ]]; then
    echo 'Failed get all backup history!'
    exit 1
fi
