#!/usr/bin/env bash

# shellcheck disable=SC2154,SC2034,SC1090
set -ea

[[ $VERBOSE =~ on|On|Yes|yes|true|True ]] && set -x

if [[ -n "${BALENA_DEVICE_UUID}" ]]; then
    # prepend the device UUID if running on balenaOS
    TLD="${BALENA_DEVICE_UUID}.${DNS_TLD}"
else
    TLD="${DNS_TLD}"
fi

conf=${CONF:-/balena/${TLD}.env}
test_fleet=${TEST_FLEET:-test-fleet}
device_type=${DEVICE_TYPE:-qemux86-64}

function cleanup() {
   rm -f Dockerfile
   sleep "$(( (RANDOM % 5) + 5 ))s"
}

trap 'cleanup' EXIT

function wait_for_device() {
    while ! [[ -e /balena/config.json ]]; do sleep "$(( (RANDOM % 5) + 5 ))s"; done
    while ! pgrep qemu-system-x86_64; do sleep "$(( (RANDOM % 5) + 5 ))s"; done
    while ! /usr/sbin/docker-hc; do sleep "$(( (RANDOM % 5) + 5 ))s"; done
}

function registry_auth() {
    if [[ -n $REGISTRY_USER ]] && [[ -n $REGISTRY_PASS ]]; then
        docker login -u "${REGISTRY_USER}" -p "${REGISTRY_PASS}"

        echo "{\"https://index.docker.io/v1/\":{\"username\":\"${REGISTRY_USER}\",\"password\":\"${REGISTRY_PASS}\"}}" \
          | jq -r > ~/.balena/secrets.json
    fi
}

function deploy_release() {
    printf 'FROM balenalib/%s-alpine\n\nCMD [ "balena-idle" ]\n' "${device_type}" > Dockerfile

    while ! balena deploy \
      --ca "${DOCKER_CERT_PATH}/ca.pem" \
      --cert "${DOCKER_CERT_PATH}/cert.pem" \
      --key "${DOCKER_CERT_PATH}/key.pem" \
      "${test_fleet}" --logs; do

        sleep "$(( (RANDOM % 5) + 5 ))s"
    done
}

function get_last_release() {
    balena releases "${test_fleet}" | head -n 2 | tail -n 1 \
      | grep -E '^.*\s+success\s+.*\s+true$' \
      | awk '{print $2}'
}

function check_running_release() {
    balena_device_uuid="$(cat < /balena/config.json | jq -r .uuid)"

    if [[ -n $balena_device_uuid ]] && [[ -n $1 ]]; then
        while ! [[ $(balena device "${balena_device_uuid}" | grep -E ^COMMIT | awk '{print $2}') =~ ${should_be_running_release_id} ]]; do
            running_release_id="$(balena device "${balena_device_uuid}" | grep -E ^COMMIT | awk '{print $2}')"
            printf 'please wait, device %s should be running %s, but is still running %s...\n' \
              "${balena_device_uuid}" \
              "${1}" \
              "${running_release_id}"

            sleep "$(( (RANDOM % 5) + 5 ))s"
        done

        balena device "${balena_device_uuid}"
    fi
}

function supervisor_poll_target_state() {
    balena_device_uuid="$(cat < /balena/config.json | jq -r .uuid)"

    if [[ -n $balena_device_uuid ]]; then
        while ! curl -X POST --silent --fail \
          --header "Content-Type:application/json" \
          --header "Authorization: Bearer $(cat ~/.balena/token)" \
          --data "{\"uuid\": \"${balena_device_uuid}\", \"data\": {\"force\": true}}" \
          "https://api.${DNS_TLD}/supervisor/v1/update"; do

            sleep "$(( (RANDOM % 5) + 5 ))s"
        done
    fi
}

if [[ $TLD =~ ^.*\.local\.? ]]; then
    echo 'mDNS configurations not supported'
    exit 1
fi

[[ -f $conf ]] && source "${conf}"

BALENARC_BALENA_URL="${DNS_TLD}"

wait_for_device
registry_auth
deploy_release
should_be_running_release_id="$(get_last_release)"
supervisor_poll_target_state
check_running_release "${should_be_running_release_id}"
