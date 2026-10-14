#!/bin/bash
# Real-binary integration test: downloads the real Go Wings or Wings-RS
# release through the installer and runs it under systemd against
# tests/integration/stub-panel.py. Run as root INSIDE A THROWAWAY CONTAINER/VM.
#   HYDRO_VM_TEST_I_AM_DISPOSABLE=1 bash tests/integration/real-wings.sh <go|rs>
# Covers: fresh install beside a foreign pterodactyl0 bridge, API auth,
# forced update, failed update recovery, Go<->Wings-RS switch, uninstall.
set -u
[ "${HYDRO_VM_TEST_I_AM_DISPOSABLE:-}" = 1 ] || { echo "refusing: set HYDRO_VM_TEST_I_AM_DISPOSABLE=1 in a throwaway VM"; exit 2; }
VARIANT="${1:-go}"
OTHER=rs; [ "$VARIANT" = rs ] && OTHER=go
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
F=0; N=0
ok() { N=$((N+1)); echo "ok $N - [$VARIANT] $1"; }
ng() { N=$((N+1)); F=$((F+1)); echo "not ok $N - [$VARIANT] $1" >&2; }
check() { local l="$1"; shift; if "$@"; then ok "$l"; else ng "$l"; fi; }
LOG=/tmp/real-wings-$VARIANT.log; : > "$LOG"

cp "$ROOT_DIR/lib/lib.sh" /tmp/hydrodactyl-lib.sh
cp "$ROOT_DIR/lib/wings-layout.sh" /tmp/wings-layout.sh
export STUB_PANEL_LOG=/tmp/stub-panel.log; rm -f "$STUB_PANEL_LOG"
(setsid python3 "$ROOT_DIR/tests/integration/stub-panel.py" >/dev/null 2>&1 &)
for _ in $(seq 20); do curl -sf http://127.0.0.1:8081/api/health >/dev/null && break; sleep 0.5; done

install_variant() { # $1 variant
  ( cd "$ROOT_DIR" && yes "" | WINGS_ASSUME_YES="${2:-}" timeout 900 bash installers/wings.sh --variant "$1" \
      --fqdn node.test --panel-url http://127.0.0.1:8081 --api-key ptla_stub --no-firewall ) >> "$LOG" 2>&1
}
api_ok() { # Wings answers /api/system with the node token
  local tok; tok=$(awk '/^token:/ {print $2; exit}' /etc/hydrodactyl/wings/config.yml | tr -d "\"'")
  for _ in $(seq 30); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $tok" http://127.0.0.1:8080/api/system)" = 200 ] && return 0
    sleep 1
  done; return 1
}
api_rejects_bad_token() { [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer nope' http://127.0.0.1:8080/api/system)" = 401 ] || [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer nope' http://127.0.0.1:8080/api/system)" = 403 ]; }
bridge_of() { docker network inspect "$1" -f '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null; }
is_variant() { # $1 go|rs
  case "$1" in
    go) /usr/local/bin/hydrodactyl-wings version 2>&1 | grep -qi 'wings v' ;;
    rs) /usr/local/bin/hydrodactyl-wings --version 2>&1 | grep -qi calagopus ;;
  esac
}

# A foreign Wings (Pterodactyl/Pelican) left its network and bridge behind.
docker network create --subnet 10.99.0.0/16 -o com.docker.network.bridge.name=pterodactyl0 pterodactyl_nw >/dev/null 2>&1

# --- fresh install ----------------------------------------------------------
check "fresh install exits 0" install_variant "$VARIANT"
check "binary is the $VARIANT variant" is_variant "$VARIANT"
check "hydrodactyl-wings is active" systemctl is-active -q hydrodactyl-wings
check "hydrodactyl-wings is enabled" systemctl is-enabled -q hydrodactyl-wings
check "no legacy wings.service was created" test ! -e /etc/systemd/system/wings.service
check "Wings API answers with the node token" api_ok
check "Wings API rejects a wrong token" api_rejects_bad_token
check "config uses namespaced data path" grep -q '^  root_directory: /var/lib/hydrodactyl/wings$' /etc/hydrodactyl/wings/config.yml
check "config is root-only (600)" test "$(stat -c %a /etc/hydrodactyl/wings/config.yml)" = 600
check "network hydrodactyl_nw uses bridge hydro0" test "$(bridge_of hydrodactyl_nw)" = hydro0
check "foreign pterodactyl_nw left intact" test "$(bridge_of pterodactyl_nw)" = pterodactyl0
check "Wings fetched servers from the panel" grep -q '^GET /api/remote/servers' "$STUB_PANEL_LOG"
check "no /var/lib/pterodactyl was created" test ! -e /var/lib/pterodactyl

# --- forced update ------------------------------------------------------------
before=$(sha256sum /usr/local/bin/hydrodactyl-wings | cut -d' ' -f1)
echo "v0.0.1" > /etc/hydrodactyl/wings-version
check "forced update exits 0" bash -c "cd '$ROOT_DIR' && bash installers/auto-update-wings.sh --force >> '$LOG' 2>&1"
check "update keeps the $VARIANT variant" is_variant "$VARIANT"
check "update restores the version file" bash -c '! grep -qx v0.0.1 /etc/hydrodactyl/wings-version'
check "service active after update" systemctl is-active -q hydrodactyl-wings
check "API answers after update" api_ok
check "update backups are root-only" bash -c 'for d in /var/backups/*wings* /var/backups/hydrodactyl*; do [ -d "$d" ] || continue; [ "$(stat -c %a "$d")" = 700 ] || exit 1; done'

# --- failed update recovers ----------------------------------------------------
before=$(sha256sum /usr/local/bin/hydrodactyl-wings | cut -d' ' -f1)
cp /etc/hydrodactyl/auto-update-wings.env /tmp/au.env.bak
sed -i 's|^WINGS_REPO=.*|WINGS_REPO="hydro-install-test/does-not-exist"|' /etc/hydrodactyl/auto-update-wings.env
echo "v0.0.1" > /etc/hydrodactyl/wings-version
check "update from a missing repo fails" bash -c "! (cd '$ROOT_DIR' && bash installers/auto-update-wings.sh --force >> '$LOG' 2>&1)"
check "failed update keeps the binary" test "$(sha256sum /usr/local/bin/hydrodactyl-wings | cut -d' ' -f1)" = "$before"
check "failed update keeps the service running" systemctl is-active -q hydrodactyl-wings
cp /tmp/au.env.bak /etc/hydrodactyl/auto-update-wings.env

# --- service switch to the other variant --------------------------------------
check "switch to $OTHER exits 0" install_variant "$OTHER" 1
check "binary is now $OTHER" is_variant "$OTHER"
check "service active after switch" systemctl is-active -q hydrodactyl-wings
check "API answers after switch" api_ok
check "updater now tracks $OTHER" grep -q "WINGS_VARIANT=\"\?$OTHER" /etc/hydrodactyl/auto-update-wings.env
check "switched config stays namespaced" grep -q '^  root_directory: /var/lib/hydrodactyl/wings$' /etc/hydrodactyl/wings/config.yml
check "switched config has no foreign network" bash -c '! grep -qE "calagopus_nw|pterodactyl_nw|pelican_nw" /etc/hydrodactyl/wings/config.yml'

# --- uninstall ------------------------------------------------------------------
docker rm -f hw-game >/dev/null 2>&1
mkdir -p /var/lib/hydrodactyl/wings/volumes/g1
docker run -d --name hw-game -v /var/lib/hydrodactyl/wings/volumes/g1:/data busybox sleep 3600 >/dev/null
docker rm -f foreign-game >/dev/null 2>&1
mkdir -p /var/lib/pelican/volumes/f1
docker run -d --name foreign-game -v /var/lib/pelican/volumes/f1:/data busybox sleep 3600 >/dev/null
check "uninstall exits 0" bash -c "cd '$ROOT_DIR' && REMOVE_WINGS=true REMOVE_PANEL=false REMOVE_ELYTRA=false REMOVE_DATABASE=false REMOVE_DATA=false REMOVE_AUTO_UPDATERS=false bash installers/uninstall.sh >> '$LOG' 2>&1"
check "service is gone" bash -c '! systemctl is-active -q hydrodactyl-wings && test ! -e /etc/systemd/system/hydrodactyl-wings.service'
check "binary and config removed" bash -c 'test ! -e /usr/local/bin/hydrodactyl-wings && test ! -e /etc/hydrodactyl/wings'
check "server container on Hydrodactyl data removed" bash -c '! docker ps -aq --filter name=^hw-game$ | grep -q .'
check "foreign server container untouched" bash -c 'docker ps -q --filter name=^foreign-game$ | grep -q .'
check "foreign data untouched" test -d /var/lib/pelican/volumes/f1
check "foreign network untouched" test "$(bridge_of pterodactyl_nw)" = pterodactyl0
check "second uninstall is a safe no-op" bash -c "cd '$ROOT_DIR' && REMOVE_WINGS=true REMOVE_PANEL=false REMOVE_ELYTRA=false REMOVE_DATABASE=false REMOVE_DATA=false REMOVE_AUTO_UPDATERS=false bash installers/uninstall.sh >> '$LOG' 2>&1"

echo "$N tests, $F failed (log: $LOG)"; exit $((F>0))
