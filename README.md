# 🌐 Node64-Proxmox

**One-Click-Installer für [Node64](https://github.com/ipv64net/node64) auf Proxmox VE** – im Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE).

Node64 (der offizielle Container von [ipv64.net](https://ipv64.net)) ist ein All-in-One-Netzwerk-Tool fürs Heimnetz – komplett lokal betrieben, keine Cloud nötig:

- **Healthchecks / Monitoring** mit Statusseiten (Uptime-Kuma-Alternative)
- **PROXY64** – Reverse Proxy
- **DNS64** – DNS-Filter (Adblock-resolver)
- **DynDNS64** – DynDNS-Updater für ipv64.net
- **Honeypot64** – Honeypot-Sensoren

Ein einziges Go-Binary mit eingebetteter Web-UI und SQLite (Daten in `/data`).

## ⚡ Installation

Auf dem **Proxmox VE Host als root** (One-Liner):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Node64-Proxmox/main/install/node64.sh)"
```

Das Script:

1. erstellt einen **unprivilegierten LXC-Container** (`nesting=1,keyctl=1`, `onboot=1`) – ID automatisch die nächste freie ab 200, Name/Hostname `node64`
2. installiert **Docker Engine + Compose-Plugin** (offizielles apt-Repo)
3. startet Node64 als Container (`network_mode: host`, Volume `node64-data:/data`, `restart: unless-stopped`)
4. **verifiziert** sich selbst: Docker aktiv → Container-Healthcheck `healthy` → Web-UI antwortet (HTTP-Check) → Summary mit finaler URL

Am Ende ist die Weboberfläche erreichbar unter `http://<LXC-IP>:8080`.

## 📋 Voraussetzungen

- Proxmox VE 8.x, Root-Zugriff
- `local-lvm`-Storage (oder `--storage` anpassen)
- Internetverbindung (apt + Container-Registry)
- ~2 GB RAM, 8 GB Disk

## ⚙️ Optionen

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Node64-Proxmox/main/install/node64.sh)" -- --id 220 --memory 4096 --ip 192.168.1.50/24
```

| Option | Default | Bedeutung |
|---|---|---|
| `--id NUM` | nächste freie ab 200 | Container-ID |
| `--hostname TEXT` | `node64` | Hostname |
| `--storage TEXT` | `local-lvm` | Proxmox Storage |
| `--rootfs NUM` | `8` | RootFS in GB |
| `--cores NUM` | `2` | CPU-Kerne |
| `--memory NUM` | `2048` | RAM in MB |
| `--bridge TEXT` | `vmbr0` | Netzwerk-Bridge |
| `--ip ADDR` | `dhcp` | Statische IP (`192.168.1.50/24`) oder `dhcp` |
| `--password TEXT` | automatisch | Root-Passwort |
| `--template TEXT` | neuestes debian-12-standard | CT-Template |
| `--image REF` | `ghcr.io/ipv64net/node64:latest` | Node64-Image |
| `--update` | – | Node64 im bestehenden Container aktualisieren |
| `--uninstall` | – | Container vollständig entfernen |
| `--status` | – | Status anzeigen |
| `--force-recreate` | – | Container löschen und neu installieren |
| `--yes, -y` | – | Rückfragen automatisch bejahen |
| `--debug` | – | Vollständiges `bash -x`-Log |

💡 **Tipp:** Läuft bereits ein Container mit Hostname `node64`, wechselt das Script automatisch in den Update-Modus (keine Daten gehen verloren).

## 🔌 Ports

Node64 läuft mit `network_mode: host` (offizielle Empfehlung für DNS64/CDN64) – alle Ports binden direkt an die IP des LXC:

| Port | Funktion |
|---|---|
| **8080** | Web-UI (HTTP **und** HTTPS, automatische TLS-Erkennung) |
| 53 / 853 | DNS64 / DNS-over-TLS/-QUIC |
| 80 / 443 | PROXY64 (Reverse Proxy / DoH) |
| 8443 | optionaler reiner HTTPS-Port (`NODE64_HTTPS_PORT`) |

## 🚀 Nach der Installation

1. `http://<LXC-IP>:8080` im Browser öffnen
2. Beim ersten Start richtet der **Setup-Wizard** das Admin-Konto ein (alternativ per Umgebungsvariablen `NODE64_ADMIN_USER` / `NODE64_ADMIN_PASSWORD` in `/opt/node64/docker-compose.yml`)
3. Module (DNS64, PROXY64, …) in der Web-UI aktivieren

## 🔄 Update

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Node64-Proxmox/main/install/node64.sh)" -- --update
```

Zieht das neueste `:latest`-Image und startet den Container neu – Daten im Volume bleiben erhalten. Manuell im Container:

```bash
pct enter <CT-ID>
cd /opt/node64 && docker compose pull && docker compose up -d
```

## 🗑️ Deinstallation

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Node64-Proxmox/main/install/node64.sh)" -- --uninstall
```

Entfernt Container **inkl. aller Node64-Daten** (SQLite, Zertifikate, Backups im Volume `node64-data`).

## 🔁 Reboot-Sicherheit

- LXC: `onboot: 1` → Container startet mit dem Proxmox-Host
- `docker.service` ist enabled (systemd)
- Node64-Container: `restart: unless-stopped` → Docker startet ihn bei Boot und bei Crash automatisch neu

## 🩺 Fehlerdiagnose

- Das Install-Script schreibt **alles** nach `/tmp/node64-installer-<zeitstempel>.log`
- Bei Fehlern gibt der ERR-Trap die **komplette Fehlerkette** aus: Exit-Code, Zeile, Befehl, letzte Logzeilen, Container-Logs (`node64-setup.log`, `docker logs node64`, `journalctl -u docker`) – der Container bleibt zur Inspektion erhalten
- Vollständiges Shell-Trace: Installation mit `--debug` wiederholen
- Live-Logs: `pct enter <CT-ID>` → `docker logs -f node64` bzw. `journalctl -u docker -f`
- Daten liegen im Docker-Volume `node64-data` (`/var/lib/docker/volumes/node64-data/_data` im LXC)

## 📜 Lizenz

Apache-2.0 – passend zu [ipv64net/node64](https://github.com/ipv64net/node64) (Apache-2.0).
