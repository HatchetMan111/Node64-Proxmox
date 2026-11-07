#!/usr/bin/env bash
# =============================================================================
#  🌐 Proxmox Node64 – One-Click Installer
#  https://github.com/HatchetMan111/Node64-Proxmox
#
#  Installiert Node64 (https://github.com/ipv64net/node64 – Monitoring,
#  Statusseiten, Reverse-Proxy, DNS-Filter, DynDNS, Honeypot) als
#  unprivilegierten LXC-Container mit Docker Engine.
#
#  Installation (auf Proxmox VE als root):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Node64-Proxmox/main/install/node64.sh)"
#
#  Mit Optionen:
#    .../install/node64.sh --id 220 --memory 4096 --ip 192.168.1.50/24
#
#  Update:
#    .../install/node64.sh --update
#
#  Deinstallieren:
#    .../install/node64.sh --uninstall
#
#  Status:
#    .../install/node64.sh --status
#
#  Debug (vollständiges bash -x-Log):
#    .../install/node64.sh --debug
# =============================================================================

set -Eeuo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
APP_NAME="node64"
IMAGE="ghcr.io/ipv64net/node64:latest"   # --image zum Überschreiben
WEB_PORT=8080                             # Web-UI (HTTP+HTTPS, TLS-Sniffing)
CT_ID=""                    # leer = automatisch nächste freie ID ab ID_SCAN_START
ID_SCAN_START=200
CT_HOSTNAME="node64"
CT_STORAGE="local-lvm"
CT_ROOTFS=8                 # GB (Docker Engine + Image; Node64 selbst ist winzig)
CT_CORES=2
CT_MEMORY=2048              # MB (Docker-Overhead + Node64 reicht das locker)
CT_SWAP=0
CT_BRIDGE="vmbr0"
CT_IP="dhcp"
CT_PASSWORD=""              # leer = automatisch generieren
CT_TEMPLATE=""
UNINSTALL=false
UPDATE=false
STATUS_CHECK=false
FORCE_RECREATE=false
ASSUME_YES=false
DEBUG=false
TMP_DIR=""
LOG_FILE="/tmp/node64-installer-$(date +%Y%m%d-%H%M%S).log"

# ── Farben & Logging ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "${BLUE}ℹ${NC}  $1"; }
ok()    { echo -e "${GREEN}✔${NC}  $1"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $1"; }
err()   { echo -e "${RED}✘${NC}  $1" >&2; }
die()   { err "$1"; exit 1; }
header(){ echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

# ── Vollständiges Log mitschneiden (Debugging-Anforderung) ─────────────────
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee "$LOG_FILE") 2>&1

# ── Cleanup & Fehlerkette ──────────────────────────────────────────────────
cleanup() {
    # if statt [[ ]] && – sonst gibt cleanup() bei leerem TMP_DIR Exit-Code 1
    # zurück und überschreibt den eigentlichen Exit-Status des Scripts.
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# Gibt bei Fehlern die KOMPLETTE Fehlerkette aus: Zeile, Befehl, Exit-Code,
# letzte Logzeilen sowie Container-Logs (Setup + Docker + journalctl), falls
# schon ein Container existiert.
on_error() {
    local ec=$1 line=$2 cmd=$3
    err "Installationsfehler – Exit-Code ${ec} in Zeile ${line}"
    err "Fehlgeschlagener Befehl: ${cmd}"
    if [[ -f "$LOG_FILE" ]]; then
        info "Letzte Logzeilen (${LOG_FILE}):"
        tail -n 15 "$LOG_FILE" | sed 's/^/    /' || true
    fi
    if [[ -n "${CT_ID:-}" ]] && pct status "$CT_ID" &>/dev/null; then
        info "Container-Logs (Setup + Docker):"
        pct exec "$CT_ID" -- sh -c '
            tail -n 25 /var/log/node64-setup.log 2>/dev/null
            tail -n 15 /var/log/node64-pull.log 2>/dev/null
            echo "--- docker logs node64 ---"
            docker logs --tail 25 node64 2>&1 2>/dev/null | tail -n 25
            echo "--- journalctl -u docker ---"
            journalctl -u docker --no-pager 2>/dev/null | tail -n 20
        ' 2>/dev/null | sed 's/^/    /' || true
        info "Container $CT_ID wurde NICHT gelöscht – Inspektion: pct enter $CT_ID"
        info "Aufräumen: pct stop $CT_ID && pct destroy $CT_ID --purge"
    fi
    info "Vollständiges Log: $LOG_FILE"
    info "Neu ausführen mit vollem bash -x-Trace:  --debug  (z. B. $(basename "$0") --debug)"
    exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ── Argumente parsen ───────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --id)             CT_ID="$2"; shift 2 ;;
            --hostname)       CT_HOSTNAME="$2"; shift 2 ;;
            --storage)        CT_STORAGE="$2"; shift 2 ;;
            --rootfs)         CT_ROOTFS="$2"; shift 2 ;;
            --cores)          CT_CORES="$2"; shift 2 ;;
            --memory)         CT_MEMORY="$2"; shift 2 ;;
            --swap)           CT_SWAP="$2"; shift 2 ;;
            --bridge)         CT_BRIDGE="$2"; shift 2 ;;
            --ip)             CT_IP="$2"; shift 2 ;;
            --password)       CT_PASSWORD="$2"; shift 2 ;;
            --template)       CT_TEMPLATE="$2"; shift 2 ;;
            --image)          IMAGE="$2"; shift 2 ;;
            --update)         UPDATE=true; shift ;;
            --uninstall)      UNINSTALL=true; shift ;;
            --status)         STATUS_CHECK=true; shift ;;
            --force-recreate) FORCE_RECREATE=true; shift ;;
            --yes|-y)         ASSUME_YES=true; shift ;;
            --debug)          DEBUG=true; shift ;;
            --help|-h)        usage; exit 0 ;;
            *)                die "Unbekanntes Argument: $1 (--help für Hilfe)" ;;
        esac
    done
    if $DEBUG; then
        set -x
        info "Debug-Modus aktiv (bash -x) – alles landet in $LOG_FILE"
    fi
}

usage() {
    cat <<'USAGE'
🌐  Proxmox Node64 – One-Click Installer
   Installiert ipv64.net/node64 (Monitoring, Statusseiten, Reverse-Proxy,
   DNS-Filter, DynDNS, Honeypot) als LXC-Container mit Docker.

Usage:
  bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Node64-Proxmox/main/install/node64.sh)" [OPTIONS]

Options:
  --id NUM            Container-ID (Default: automatisch nächste freie ab 200)
  --hostname TEXT     Hostname (Default: node64)
  --storage TEXT      Proxmox Storage (Default: local-lvm)
  --rootfs NUM        RootFS in GB (Default: 8)
  --cores NUM         CPU-Kerne (Default: 2)
  --memory NUM        RAM in MB (Default: 2048)
  --swap NUM          Swap in MB (Default: 0)
  --bridge TEXT       Netzwerk-Bridge (Default: vmbr0)
  --ip ADDR           Statische IP (z. B. 192.168.1.50/24) oder "dhcp" (Default: dhcp)
  --password TEXT     Root-Passwort (Default: automatisch generiert)
  --template TEXT     CT-Template (Default: neuestes debian-12-standard via pveam)
  --image REF         Node64-Image (Default: ghcr.io/ipv64net/node64:latest)
  --update            Node64 im bestehenden Container aktualisieren (docker compose pull)
  --uninstall         Container vollständig entfernen
  --status            Status anzeigen
  --force-recreate    Bei bestehendem Container: löschen und neu installieren
  --yes, -y           Rückfragen automatisch mit "ja" beantworten
  --debug             Vollständiges bash -x-Log ausgeben
  --help              Diese Hilfe

Ports im Container:  8080 = Web-UI (HTTP+HTTPS),  53/853 = DNS64/DoT,
                     80/443 = PROXY64 (Reverse-Proxy),  8443 = optional HTTPS

Examples:
  # Standard-Installation (nächste freie ID ab 200):
  bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Node64-Proxmox/main/install/node64.sh)"

  # Mit eigener ID, statischer IP und mehr RAM:
  ... --id 220 --memory 4096 --ip 192.168.1.50/24

  # Update / Status / Deinstallation:
  ... --update
  ... --status
  ... --uninstall --yes
USAGE
}

# ── Hilfsfunktionen ────────────────────────────────────────────────────────
# Nächste freie Container-ID finden (ID-Vorgabe wird bei Belegung erhöht)
find_free_id() {
    [[ -z "$CT_ID" ]] && CT_ID="$ID_SCAN_START"
    local orig_id="$CT_ID"
    while pct list 2>/dev/null | awk '{print $1}' | grep -qx -- "$CT_ID"; do
        CT_ID=$((CT_ID + 1))
    done
    # if statt [[ ]] && – sonst gibt die Funktion 1 zurück, wenn die ID frei war
    if [[ "$CT_ID" != "$orig_id" ]]; then
        info "Container $orig_id ist belegt – verwende stattdessen ID $CT_ID"
    fi
    return 0
}

# Existiert bereits ein Container mit dem Ziel-Hostnamen? → dessen ID
find_existing_ct() {
    pct list 2>/dev/null | awk -v h="$CT_HOSTNAME" \
        'NR>1 { for (i=2; i<=NF; i++) if ($i==h) { print $1; exit } }'
}

ct_exists() {
    pct list 2>/dev/null | awk '{print $1}' | grep -qx -- "$1"
}

confirm() {
    $ASSUME_YES && return 0
    local reply
    read -r -p "$1 [y/N]: " reply || return 1
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ── Voraussetzungen prüfen ─────────────────────────────────────────────────
check_prerequisites() {
    header "Prüfe Voraussetzungen"

    [[ $EUID -ne 0 ]] && die "Bitte als root ausführen (sudo bash ...)"
    command -v pct &>/dev/null   || die "pct nicht gefunden – läuft dieses Script auf einem Proxmox VE Host?"

    # Template/Storage nur für Installations-Modi relevant (status/update/uninstall nicht)
    if $UNINSTALL || $UPDATE || $STATUS_CHECK; then
        return 0
    fi

    command -v pveam &>/dev/null || die "pveam nicht gefunden – ist Proxmox VE korrekt installiert?"

    # Template automatisch finden/downloaden
    if [[ -z "$CT_TEMPLATE" ]]; then
        local t
        # sort -V: bei mehreren gecachten Versionen das neueste Template nehmen
        t=$(pveam list local 2>/dev/null | grep -i "debian-12-standard" | sort -V | tail -1 || true)
        if [[ -z "$t" ]]; then
            info "Lade Debian-12-Template herunter (einmalig)..."
            local tpl_name
            tpl_name=$(pveam available --section system 2>/dev/null \
                | grep -o "debian-12-standard_[^ ]*\.tar\.zst" | sort -V | tail -1 || true)
            [[ -z "$tpl_name" ]] && die "Kein Debian-12-Template gefunden.\n  Bitte prüfen: pveam update && pveam available --section system"
            pveam download local "$tpl_name" 2>&1 | tail -3
            t=$(pveam list local 2>/dev/null | grep -i "debian-12-standard" | head -1 || true)
            [[ -z "$t" ]] && die "Template-Download fehlgeschlagen.\n  Bitte manuell: pveam update && pveam download local $tpl_name"
        fi
        CT_TEMPLATE=$(basename "$(echo "$t" | awk '{print $1}')")
    fi
    ok "Template: $CT_TEMPLATE"

    # Statische IP grob validieren (nur Warnung)
    if [[ "$CT_IP" != "dhcp" && ! "$CT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ && ! "$CT_IP" =~ ^(dhcp|dhcp6|auto|manual)$ ]]; then
        warn "CT_IP='$CT_IP' sieht nicht wie eine gültige IP/CIDR aus – pct create könnte fehlschlagen"
    fi
}

# ── Deinstallieren ─────────────────────────────────────────────────────────
do_uninstall() {
    local ct_id="$1"
    header "Entferne Container $ct_id ($CT_HOSTNAME)"

    confirm "Container $ct_id inkl. aller Node64-Daten (SQLite, Zertifikate, Backups) wirklich löschen?" \
        || die "Abgebrochen (mit --yes überspringst du die Rückfrage)."

    pct stop "$ct_id" 2>/dev/null || true
    sleep 2
    pct destroy "$ct_id" --purge 2>/dev/null
    ok "Container $ct_id entfernt"
    exit 0
}

# ── Status ─────────────────────────────────────────────────────────────────
do_status() {
    local ct_id="$1"
    header "Status: Container $ct_id ($CT_HOSTNAME)"

    if ! ct_exists "$ct_id"; then
        warn "Container $ct_id existiert nicht"
        exit 0
    fi

    local state
    state=$(pct status "$ct_id" 2>/dev/null || echo "unknown")
    info "Container: $state"

    if [[ "$state" == *"running"* ]]; then
        local health
        health=$(pct exec "$ct_id" -- docker inspect -f '{{.State.Health.Status}}' node64 2>/dev/null || echo "unbekannt")
        if [[ "$health" == "healthy" ]]; then
            ok "Node64-Container: healthy (Docker-Healthcheck)"
        else
            warn "Node64-Container: $health"
            pct exec "$ct_id" -- docker logs --tail 10 node64 2>&1 2>/dev/null | tail -10 || true
        fi

        local ct_ip
        ct_ip=$(pct exec "$ct_id" -- hostname -I 2>/dev/null | awk '{print $1}')
        if [[ -n "$ct_ip" ]]; then
            info "IP: $ct_ip"
            if command -v curl &>/dev/null; then
                # curl -w gibt bei Verbindungsfehler bereits '000' aus – kein '|| echo 000',
                # sonst entstehen Werte wie '000000' und der Check wird falsch-positiv.
                local code
                code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${ct_ip}:${WEB_PORT}/" 2>/dev/null || true)
                if [[ "$code" =~ ^[0-9]{3}$ && "$code" != "000" ]]; then
                    ok "Web-UI antwortet: http://${ct_ip}:${WEB_PORT} (HTTP $code)"
                    return 0
                fi
                warn "Web-UI antwortet nicht von außen (HTTP ${code:-000})"
            fi
        fi
        pct exec "$ct_id" -- systemctl status docker --no-pager 2>/dev/null | head -10 || true
    fi
    exit 0
}

# ── In-Container-Setup-Script erzeugen (idempotent) ────────────────────────
write_inner_script() {
    cat > "$TMP_DIR/setup-inner.sh" <<'INNEREOF'
#!/usr/bin/env bash
# =============================================================================
# Node64 In-Container-Setup (idempotent – safe für Update & Re-Run)
# Wird vom Installer via `pct push` + `pct exec` ausgeführt (als root).
# Installiert Docker Engine + Compose und startet den Node64-Container.
# =============================================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
[[ "${N64_DEBUG:-0}" == "1" ]] && set -x
exec > >(tee /var/log/node64-setup.log) 2>&1

step() { echo -e "\n━━━ [setup] $* ━━━"; }

step "1/5 apt: Basispakete (curl, ca-certificates, gnupg)"
apt-get update -qq
apt-get install -y --no-install-recommends curl ca-certificates gnupg

step "2/5 Docker Engine + Compose-Plugin (offizielles apt-Repo, idempotent)"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

step "3/5 Docker-Daemon starten und auf Bereitschaft warten"
systemctl enable --now docker
local_ready=false
for _ in $(seq 1 30); do
    if docker info >/dev/null 2>&1; then local_ready=true; break; fi
    sleep 1
done
if ! $local_ready; then
    echo "Docker-Daemon startet nicht:"
    journalctl -u docker --no-pager 2>/dev/null | tail -n 25
    systemctl status docker --no-pager -l 2>/dev/null | head -n 20
    exit 1
fi

step "4/5 Node64-Image laden + docker compose starten"
IMAGE="${NODE64_IMAGE:?NODE64_IMAGE nicht gesetzt}"
FALLBACK_IMAGE="x64gmbh/node64:latest"
if ! docker pull --quiet "$IMAGE" 2>/var/log/node64-pull.log; then
    echo "docker pull $IMAGE fehlgeschlagen:"
    tail -n 20 /var/log/node64-pull.log
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
        echo "Nutze vorhandenes lokales Image: $IMAGE"
    elif docker pull --quiet "$FALLBACK_IMAGE" 2>>/var/log/node64-pull.log; then
        IMAGE="$FALLBACK_IMAGE"
        echo "Weiche aus auf Fallback-Image: $IMAGE"
    else
        echo "Auch Fallback-Image fehlgeschlagen:"
        tail -n 20 /var/log/node64-pull.log
        exit 1
    fi
fi

mkdir -p /opt/node64
cat > /opt/node64/docker-compose.yml <<COMPOSEEOF
services:
  node64:
    image: ${IMAGE}
    container_name: node64
    # host networking = Node64-Empfehlung für DNS64/CDN64; alle Ports binden
    # direkt an die IP des LXC (8080 Web-UI, 53/853 DNS, 80/443 Proxy).
    network_mode: host
    volumes:
      - node64-data:/data
    restart: unless-stopped

volumes:
  node64-data:
COMPOSEEOF

cd /opt/node64
docker compose up -d

step "5/5 Aufräumen (dangling images)"
docker image prune -f >/dev/null 2>&1 || true

echo -e "\n━━━ [setup] In-Container-Setup abgeschlossen ━━━"
INNEREOF
}

# ── Setup im Container ausführen (genutzt von install + update) ────────────
run_inner_setup() {
    local ct_id="$1"
    header "Richte Node64 in Container $ct_id ein (Image: ${IMAGE})"

    TMP_DIR=$(mktemp -d /tmp/node64-install-XXXXXX)
    write_inner_script
    pct push "$ct_id" "$TMP_DIR/setup-inner.sh" /root/setup-inner.sh

    info "Führe In-Container-Setup aus (apt, Docker Engine, Image-Pull – kann einige Minuten dauern)..."
    pct exec "$ct_id" -- env NODE64_IMAGE="$IMAGE" N64_DEBUG="$([[ $DEBUG == true ]] && echo 1 || echo 0)" \
        bash /root/setup-inner.sh
    ok "In-Container-Setup abgeschlossen"
}

# ── Verifikation: Docker-Container + Web-UI ────────────────────────────────
verify_installation() {
    local ct_id="$1"
    header "Verifiziere Installation"

    info "Docker-Service prüfen..."
    if ! pct exec "$ct_id" -- systemctl is-active --quiet docker; then
        err "Service 'docker' läuft nicht."
        pct exec "$ct_id" -- sh -c 'systemctl status docker --no-pager -l | head -30; \
            echo "--- journalctl ---"; journalctl -u docker --no-pager | tail -40' || true
        die "Docker-Service-Check fehlgeschlagen.\n  Debug: pct enter $ct_id && journalctl -u docker -e"
    fi
    ok "Docker läuft (systemctl is-active)"

    info "Node64-Container-Health prüfen (Image-Healthcheck, alle 30 s)..."
    local health="" healthy=false
    for _ in $(seq 1 36); do
        # docker inspect liefert starting/healthy/unhealthy – leer bei Fehler
        health=$(pct exec "$ct_id" -- docker inspect -f '{{.State.Health.Status}}' node64 2>/dev/null || true)
        if [[ "$health" == "healthy" ]]; then
            healthy=true
            break
        fi
        sleep 5
    done

    if ! $healthy; then
        err "Node64-Container ist nicht 'healthy' (Status: ${health:-unbekannt})."
        pct exec "$ct_id" -- sh -c 'docker logs --tail 40 node64 2>&1; \
            echo "--- docker inspect ---"; docker inspect node64 --format "{{json .State}}" 2>/dev/null' || true
        die "Health-Check fehlgeschlagen.\n  Debug: pct enter $ct_id && docker logs node64"
    fi
    ok "Node64-Container: healthy"

    info "Warte auf Web-UI (Port ${WEB_PORT})..."
    local web_ok=false web_code
    for _ in $(seq 1 24); do
        # curl -w liefert bei Verbindungsfehler '000'; keine zweite Ausgabe via || echo
        web_code="$(pct exec "$ct_id" -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            "http://127.0.0.1:${WEB_PORT}/" 2>/dev/null || true)"
        if [[ "$web_code" =~ ^[0-9]{3}$ && "$web_code" != "000" ]]; then
            web_ok=true
            break
        fi
        sleep 5
    done

    $web_ok || die "Web-UI auf Port ${WEB_PORT} antwortet nicht.\n  Debug: pct enter $ct_id && docker logs node64"
    ok "Web-UI erreichbar im Container (HTTP $web_code)"

    # Externer Check vom Proxmox-Host (soft – nur Warnung, Firewall/Netz kann berechtigt blocken)
    local ct_ip ext_code
    ct_ip=$(pct exec "$ct_id" -- hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -n "$ct_ip" ]] && command -v curl &>/dev/null; then
        ext_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${ct_ip}:${WEB_PORT}/" 2>/dev/null || true)
        if [[ "$ext_code" =~ ^[0-9]{3}$ && "$ext_code" != "000" ]]; then
            ok "Web-UI vom Host erreichbar: http://${ct_ip}:${WEB_PORT} (HTTP $ext_code)"
        else
            warn "Web-UI vom Host aus nicht erreichbar (HTTP ${ext_code:-000}) – im Container läuft sie; ggf. Firewall/Netz prüfen."
        fi
    fi
}

# ── Zusammenfassung ────────────────────────────────────────────────────────
print_summary() {
    header "🌐  Node64 ist bereit!"

    local ct_ip
    if [[ "$CT_IP" == "dhcp" ]]; then
        ct_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')
    else
        ct_ip="${CT_IP%%/*}"
    fi
    [[ -z "$ct_ip" ]] && ct_ip="<IP-ADRESSE>"

    echo ""
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}  🌐 Web-UI:    http://${ct_ip}:${WEB_PORT}  (HTTP+HTTPS, TLS-Sniffing)${NC}"
    echo -e "  ${GREEN}  🐚 Terminal:  pct enter ${CT_ID}${NC}"
    echo -e "  ${GREEN}  🔑 Root-PW:   ${CT_PASSWORD}${NC}"
    echo -e "  ${GREEN}  📦 Image:     ${IMAGE}${NC}"
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}So geht's weiter:${NC}"
    echo "  1. http://${ct_ip}:${WEB_PORT} im Browser öffnen"
    echo "  2. Beim ersten Start richtet der Setup-Wizard das Admin-Konto ein"
    echo "     (alternativ env NODE64_ADMIN_USER / NODE64_ADMIN_PASSWORD)"
    echo "  3. Module aktivieren: Healthchecks, PROXY64, DNS64, DynDNS64, Honeypot"
    echo ""
    echo -e "  ${CYAN}Weitere Ports (in der Web-UI aktivieren):${NC}"
    echo "  53/853 = DNS64/DoT,  80/443 = PROXY64,  8443 = optional HTTPS"
    echo ""
    echo -e "  ${CYAN}Nützliche Befehle:${NC}"
    echo "  Status:    ${APP_NAME}-Installer mit --status (dieses Script)"
    echo "  Logs:      pct exec ${CT_ID} -- docker logs -f node64"
    echo "  Compose:   pct exec ${CT_ID} -- sh -c 'cd /opt/node64 && docker compose ps'"
    echo "  Daten:     pct exec ${CT_ID} -- sh -c 'cd /opt/node64 && docker volume inspect node64-data'"
    echo "  Update:    dieses Script mit --update"
    echo ""
}

# ── Update (Container bleibt, App wird aktualisiert) ───────────────────────
do_update() {
    local ct_id="$1"
    header "Aktualisiere Node64 in Container $ct_id"

    pct exec "$ct_id" -- systemctl is-active docker &>/dev/null \
        || warn "Docker läuft aktuell nicht – Update wird ihn starten."

    run_inner_setup "$ct_id"
    verify_installation "$ct_id"
    print_summary
    exit 0
}

# ── Container erstellen ────────────────────────────────────────────────────
create_container() {
    header "Erstelle LXC-Container (ID: $CT_ID)"

    pct create "$CT_ID" "local:vztmpl/${CT_TEMPLATE}" \
        --hostname "$CT_HOSTNAME" \
        --storage "$CT_STORAGE" \
        --rootfs "${CT_STORAGE}:${CT_ROOTFS}" \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --swap "$CT_SWAP" \
        --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},firewall=0" \
        --password "$CT_PASSWORD" \
        --unprivileged 1 \
        --features nesting=1,keyctl=1 \
        --onboot 1 \
        --start 0 \
        2>&1 | tail -3

    ok "Container $CT_ID erstellt ($CT_CORES vCPU, ${CT_MEMORY} MB RAM, ${CT_ROOTFS} GB Disk, onboot=1, unprivileged, nesting+keyctl)"
}

# ── Hauptprogramm ──────────────────────────────────────────────────────────
main() {
    parse_args "$@"

    echo ""
    echo -e "  ${BOLD}🌐  Proxmox Node64 – Installer${NC}"
    echo -e "  ${CYAN}https://github.com/HatchetMan111/Node64-Proxmox${NC}"
    echo -e "  ${CYAN}App: https://github.com/ipv64net/node64 (Image ${IMAGE}, Apache-2.0)${NC}"
    echo -e "  ${CYAN}Log: $LOG_FILE${NC}"
    echo ""

    check_prerequisites

    # Bestehenden Container anhand Hostname finden (ID-Vorgabe hat Vorrang)
    local existing_id=""
    if [[ -n "$CT_ID" ]] && ct_exists "$CT_ID"; then
        existing_id="$CT_ID"
    else
        existing_id=$(find_existing_ct || true)
    fi

    if $UNINSTALL; then
        [[ -z "$existing_id" ]] && die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden (--id angeben?)."
        do_uninstall "$existing_id"
    fi

    if $STATUS_CHECK; then
        [[ -z "$existing_id" ]] && die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden (--id angeben?)."
        do_status "$existing_id"
    fi

    if $UPDATE; then
        [[ -z "$existing_id" ]] && die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden (--id angeben?)."
        do_update "$existing_id"
    fi

    # Neuinstallation
    if [[ -n "$existing_id" ]]; then
        if $FORCE_RECREATE; then
            warn "--force-recreate: bestehender Container $existing_id wird GELÖSCHT (alle Daten verloren)!"
            confirm "Wirklich neu erstellen?" || die "Abgebrochen. (Tipp: --update aktualisiert ohne Datenverlust)"
            pct stop "$existing_id" 2>/dev/null || true
            sleep 2
            pct destroy "$existing_id" --purge 2>/dev/null
            CT_ID=""
        else
            info "Container '$CT_HOSTNAME' existiert bereits (ID $existing_id) – wechsle in den Update-Modus."
            info "(Neuinstallation erzwingen: --force-recreate)"
            do_update "$existing_id"
        fi
    fi

    find_free_id

    if [[ -z "$CT_PASSWORD" ]]; then
        CT_PASSWORD=$(openssl rand -hex 12 2>/dev/null \
            || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' || echo "changeme")
        info "Root-Passwort automatisch generiert"
    fi

    create_container

    pct start "$CT_ID" 2>&1 | tail -2
    ok "Container gestartet"

    info "Warte auf Netzwerk..."
    for _ in $(seq 1 60); do
        [[ -n "$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | tr -d ' \n')" ]] && break
        sleep 1
    done
    [[ -z "$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | tr -d ' \n')" ]] \
        && die "Container hat nach 60 s keine IP (Bridge/Netz prüfen: pct exec $CT_ID -- ip a)"

    run_inner_setup "$CT_ID"
    verify_installation "$CT_ID"
    print_summary
}

main "$@"
