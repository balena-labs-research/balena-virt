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

BALENA_API_URL=${BALENA_API_URL:-https://api.balena-cloud.com}
certs=${CERTS:-/certs}
conf=${CONF:-/balena/${TLD}.env}
test_fleet=${TEST_FLEET:-test-fleet}
device_type=${DEVICE_TYPE:-qemux86-64}
os_version=${OS_VERSION:-$(balena os versions "${device_type}" | grep \.dev | head -n 1)}
guest_disk_size=${GUEST_DISK_SIZE:-16}
guest_image=${GUEST_IMAGE:-/balena/balena.img}
attempts=${ATTEMPTS:-3}

function set_update_lock {
    if [[ -n $BALENA_SUPERVISOR_ADDRESS ]] && [[ -n $BALENA_SUPERVISOR_API_KEY ]]; then
        while [[ $(curl --silent --retry "${attempts}" --fail \
          "${BALENA_SUPERVISOR_ADDRESS}/v1/device?apikey=${BALENA_SUPERVISOR_API_KEY}" \
          -H "Content-Type: application/json" | jq -r '.update_pending') == 'true' ]]; do

            curl --silent --retry "${attempts}" --fail \
              "${BALENA_SUPERVISOR_ADDRESS}/v1/device?apikey=${BALENA_SUPERVISOR_API_KEY}" \
              -H "Content-Type: application/json" | jq -r

            sleep "$(( (RANDOM % 3) + 3 ))s"
        done
        sleep "$(( (RANDOM % 5) + 5 ))s"

        # https://www.balena.io/docs/learn/deploy/release-strategy/update-locking/
        lockfile /tmp/balena/updates.lock
    fi
}

function remove_update_lock() {
    rm -f /tmp/balena/updates.lock
}

function cleanup() {
   rm -f /tmp/balena.zip
   remove_update_lock

   # crash loop backoff
   sleep 10s
}

trap 'cleanup' EXIT

function update_ca_certificates() {
    # only set CA bundle if using private certificate chain
    if [[ -e "${certs}/ca-bundle.pem" ]]; then
        if [[ "$(readlink -f "${certs}/${TLD}-chain.pem")" =~ \/private\/ ]]; then
            mkdir -p /usr/local/share/ca-certificates
            cat < "${certs}/ca-bundle.pem" > /usr/local/share/ca-certificates/balenaRootCA.crt
            # shellcheck disable=SC2034
            CURL_CA_BUNDLE=${CURL_CA_BUNDLE:-${certs}/ca-bundle.pem}
            NODE_EXTRA_CA_CERTS=${NODE_EXTRA_CA_CERTS:-${CURL_CA_BUNDLE}}
            # (TBC) refactor to use NODE_EXTRA_CA_CERTS instead of ROOT_CA
            # https://github.com/balena-io/e2e/blob/master/conf.js#L12-L14
            # https://github.com/balena-io/e2e/blob/master/Dockerfile#L82-L83
            # ... or
            # https://thomas-leister.de/en/how-to-import-ca-root-certificate/
            # https://github.com/puppeteer/puppeteer/issues/2377
            ROOT_CA=${ROOT_CA:-$(cat < "${NODE_EXTRA_CA_CERTS}" | openssl base64 -A)}
        else
            rm -f /usr/local/share/ca-certificates/balenaRootCA.crt
            unset NODE_EXTRA_CA_CERTS CURL_CA_BUNDLE ROOT_CA
        fi
        update-ca-certificates
    fi
}

function wait_for_api() {
    while ! curl --silent --fail "https://api.${DNS_TLD}/ping"; do
        sleep "$(( (RANDOM % 5) + 5 ))s"
    done
}

function open_balena_login() {
    balena login --credentials \
      --email "${SUPERUSER_EMAIL}" \
      --password "${SUPERUSER_PASSWORD}"
}

function create_fleet() {
    if ! balena fleet "${test_fleet}"; then
        # wait for API to load DT contracts
        # (TBC) 'balena devices supported' always returns empty list
        while ! balena fleet create "${test_fleet}" --type "${device_type}"; do
            sleep "$(( (RANDOM % 5) + 5 ))s"
        done
    fi
}

function download_os_image() {
    if ! [[ -e $guest_image ]]; then
        wget -qO /tmp/balena.zip \
          "${BALENA_API_URL}/download?deviceType=${device_type}&version=${os_version:1}&fileType=.zip&developmentMode=true"

        unzip -oq /tmp/balena.zip -d /tmp

        cat < "$(find /tmp -type f -name "*.img" | head -n 1)" > "${guest_image}"
    fi
}

function configure_virtual_device() {
    while ! [[ -e $guest_image ]]; do sleep "$(( (RANDOM % 5) + 5 ))s"; done

    if ! [[ -e /balena/config.json ]]; then
        balena_device_uuid="$(openssl rand -hex 16)"

        balena device register "${test_fleet}" --uuid "${balena_device_uuid}"

        balena config generate \
          --version "${os_version:1}" \
          --device "${balena_device_uuid}" \
          --network ethernet \
          --appUpdatePollInterval 10 \
          --output /balena/config.json
    fi

    balena os configure "${guest_image}" \
      --fleet "${test_fleet}" \
      --config /balena/config.json

}

function resize_disk_image() {
    if ! [[ -e /balena/standard0.qcow2 ]]; then
        qemu-img convert -f raw -O qcow2 \
          "${guest_image}" \
          "/balena/standard0.qcow2"

        qemu-img resize "/balena/standard0.qcow2" "${guest_disk_size}G"
    fi
}

function convert_raw_image() {
    if ! [[ -e /balena/standard0-snapshot.qcow2 ]]; then
        qemu-img create \
          -f qcow2 -b "/balena/standard0.qcow2" \
          -F qcow2 "/balena/standard0-snapshot.qcow2" \
          "$(( guest_disk_size / 2 ))G"
    fi
}

function enable_nested_virtualisation() {
    if modprobe kvm_intel; then
        echo 1 > /sys/kernel/mm/ksm/run
    else
        sed -i '/accel: kvm/d' guests.yml
    fi
}

if [[ $TLD =~ ^.*\.local\.? ]]; then
    echo 'mDNS configurations not supported'
    sleep infinity
fi

[[ -f $conf ]] && source "${conf}"

BALENARC_BALENA_URL="${DNS_TLD}"

enable_nested_virtualisation
update_ca_certificates
wait_for_api
balena whoami || open_balena_login
create_fleet
download_os_image
configure_virtual_device

set_update_lock
resize_disk_image
convert_raw_image
remove_update_lock

exec /root/cli.js "$@"
