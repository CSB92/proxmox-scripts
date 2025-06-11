#!/usr/bin/env bash
#=================================================
# Proxmox VE LXC Installer for JDownloader 2 with XFCE + noVNC
# by ChatGPT | Inspired by tteck | Revised by Gemini
#=================================================

set -euo pipefail
shopt -s nocaseglob

YW=$(echo "\033[33m")  # Gelb
GN=$(echo "\033[32m")  # Grün
RD=$(echo "\033[31m")  # Rot
BL=$(echo "\033[36m")  # Blau
RESET=$(echo "\033[m") # Reset
BOLD=$(echo "\033[1m")

header_info() {
  echo -e "${BL}${BOLD}
  ┌──────────────────────────────────────┐
  │   JDownloader 2 LXC Installer        │
  │   with XFCE + noVNC (Web GUI)        │
  └──────────────────────────────────────┘${RESET}"
}

error_exit() {
  echo -e "${RD}Error: $1${RESET}" >&2
  exit 1
}

# --- Benutzerabfragen ---
read -r -p "Container ID (z.B. 1231): " CT_ID
read -r -p "Hostname (z.B. jdownloader): " CT_HOSTNAME
read -r -p "Disk-Größe in GB (z.B. 8G): " CT_DISK_SIZE
read -r -p "Arbeitsspeicher in MB (z.B. 2048): " CT_MEM
read -r -p "Anzahl der CPU-Kerne (z.B. 2): " CT_CORES
read -r -p "Passwort für Linux & VNC: " CT_PASSWORD

# --- Vordefinierte Variablen ---
CT_NET="dhcp"
CT_USER="jdownloader"
CT_UNPRIVILEGED=1

header_info
echo -e "${YW}→ Starte LXC Erstellung...${RESET}"

pveam update >/dev/null
TEMPLATE=$(pveam available | grep debian-12-standard | tail -1 | awk '{print $2}')
[ -z "$TEMPLATE" ] && error_exit "Kein Debian 12 Template gefunden!"

pct create "$CT_ID" "local:vztmpl/$TEMPLATE" \
  -hostname "$CT_HOSTNAME" \
  -cores "$CT_CORES" \
  -memory "$CT_MEM" \
  -net0 name=eth0,bridge=vmbr0,ip="$CT_NET" \
  -unprivileged "$CT_UNPRIVILEGED" \
  -rootfs "local-lvm:$CT_DISK_SIZE" \
  -features nesting=1

pct start "$CT_ID"
sleep 5 # Kurze Pause, damit der Container Zeit hat, das Netzwerk zu initialisieren

echo -e "${YW}→ Installiere Software im Container...${RESET}"

# --- Software-Installation in einem Block ausführen ---
pct exec "$CT_ID" -- bash -c "
  # System aktualisieren und Abhängigkeiten installieren
  apt update && apt upgrade -y
  apt install -y xfce4 xfce4-goodies tigervnc-standalone-server tigervnc-common wget openjdk-17-jre-headless git apache2-utils curl unzip sudo

  # Benutzer anlegen und konfigurieren
  useradd -m -s /bin/bash $CT_USER
  echo '$CT_USER:$CT_PASSWORD' | chpasswd
  usermod -aG sudo $CT_USER

  # JDownloader herunterladen
  mkdir -p /home/$CT_USER/jdownloader
  cd /home/$CT_USER/jdownloader
  wget http://installer.jdownloader.org/JDownloader.jar
  chown -R $CT_USER:$CT_USER /home/$CT_USER

  # TigerVNC einrichten
  mkdir -p /home/$CT_USER/.vnc
  echo '$CT_PASSWORD' | vncpasswd -f > /home/$CT_USER/.vnc/passwd
  chown -R $CT_USER:$CT_USER /home/$CT_USER/.vnc
  chmod 600 /home/$CT_USER/.vnc/passwd

  cat <<EOF > /home/$CT_USER/.vnc/xstartup
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
xrdb \$HOME/.Xresources
startxfce4 &
EOF
  chmod +x /home/$CT_USER/.vnc/xstartup
  chown $CT_USER:$CT_USER /home/$CT_USER/.vnc/xstartup

  # VNC-Server systemd Service erstellen
  cat <<EOF >/etc/systemd/system/vncserver@.service
[Unit]
Description=TigerVNC Server for %i
After=network.target

[Service]
Type=forking
User=%i
PAMName=login
PIDFile=/home/%i/.vnc/%H:1.pid
ExecStart=/usr/bin/vncserver -depth 24 -geometry 1920x1080 -localhost :1
ExecStop=/usr/bin/vncserver -kill :1

[Install]
WantedBy=multi-user.target
EOF

  # noVNC (Web-Proxy für VNC) installieren
  git clone https://github.com/novnc/noVNC.git /opt/noVNC
  git clone https://github.com/novnc/websockify.git /opt/noVNC/utils/websockify
  ln -s /opt/noVNC/vnc.html /opt/noVNC/index.html

  # noVNC systemd Service erstellen
  cat <<EOF >/etc/systemd/system/novnc.service
[Unit]
Description=noVNC WebSocket Proxy
Wants=vncserver@$CT_USER.service
After=vncserver@$CT_USER.service

[Service]
Type=simple
ExecStart=/opt/noVNC/utils/launch.sh --vnc localhost:5901 --listen 6080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  # JDownloader Autostart einrichten
  mkdir -p /home/$CT_USER/.config/autostart
  cat <<EOF > /home/$CT_USER/.config/autostart/jdownloader.desktop
[Desktop Entry]
Type=Application
Name=JDownloader 2
Exec=java -jar /home/$CT_USER/jdownloader/JDownloader.jar
StartupNotify=false
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
  chown -R $CT_USER:$CT_USER /home/$CT_USER/.config

  # Dienste aktivieren und starten
  systemctl daemon-reload
  systemctl enable --now vncserver@$CT_USER.service
  systemctl enable --now novnc.service
"

IP=$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}')

echo -e "${GN}
╭──────────────────────────────────────╮
│        INSTALLATION FERTIG           │
╰──────────────────────────────────────╯
Zugriff auf die JDownloader GUI via Browser:
→ ${BOLD}http://$IP:6080${RESET}

Anmeldedaten (VNC & Linux User):
→ Benutzer: ${BOLD}$CT_USER${RESET}
→ Passwort: ${BOLD}$CT_PASSWORD${RESET}

Proxmox CT ID: ${BOLD}$CT_ID${RESET}
${RESET}"
