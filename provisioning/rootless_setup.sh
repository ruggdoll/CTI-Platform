#!/usr/bin/env bash
# rootless_setup.sh — installe et démarre le démon Docker ROOTLESS du compte
# courant. Appelé par prepare_host.sh, mais utilisable seul :
#
#   bash provisioning/rootless_setup.sh
#
# À lancer en tant que l'utilisateur qui fera tourner la plateforme, dans une
# vraie session (connexion SSH, console, ou `machinectl shell`) — PAS via
# `sudo -u`, qui ne fournit ni XDG_RUNTIME_DIR ni bus systemd : le client
# Docker y reste muet sans que rien n'explique pourquoi.
#
# Idempotent : sur un compte déjà configuré, il constate et redémarre au besoin.
set -euo pipefail

ok()   { printf '  \033[32mOK\033[0m     %s\n' "$1"; }
ko()   { printf '  \033[31mÉCHEC\033[0m  %s\n' "$1"; }
info() { printf '  ·      %s\n' "$1"; }
mourir(){ ko "$1"; exit 1; }

[ "$(id -u)" -ne 0 ] || mourir "à lancer en tant qu'utilisateur NON root : le rootless n'a pas de sens sous root"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
export PATH=/usr/bin:$PATH
[ -d "$XDG_RUNTIME_DIR" ] || mourir "$XDG_RUNTIME_DIR absent — il manque « loginctl enable-linger $(id -un) » (root)"

command -v dockerd-rootless-setuptool.sh >/dev/null 2>&1 \
  || mourir "dockerd-rootless-setuptool.sh introuvable — paquet docker-ce-rootless-extras manquant"
command -v newuidmap >/dev/null 2>&1 \
  || mourir "newuidmap introuvable — paquet uidmap manquant (le rootless ne démarrera pas)"

if systemctl --user cat docker.service >/dev/null 2>&1; then
  ok "service utilisateur docker déjà installé"
else
  dockerd-rootless-setuptool.sh install >/dev/null
  ok "démon rootless installé pour $(id -un)"
fi

# Ces deux variables sont ce qui rend le client utilisable dans les sessions
# suivantes. .profile sert aux shells de login (ce qu'ouvre SSH avec `bash -l`),
# .bashrc aux shells interactifs : il faut les deux.
for FICHIER in "$HOME/.profile" "$HOME/.bashrc"; do
  grep -q 'DOCKER_HOST=unix:///run/user' "$FICHIER" 2>/dev/null && continue
  cat >> "$FICHIER" <<'EOF'

# Docker rootless (CTI-Platform)
export PATH=/usr/bin:$PATH
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock
EOF
  info "environnement ajouté à $(basename "$FICHIER")"
done

export DOCKER_HOST="unix://${XDG_RUNTIME_DIR}/docker.sock"
systemctl --user enable docker.service >/dev/null 2>&1 || true
# Relance possible sur une plateforme VIVANTE : ne pas faire rebondir un démon
# qui tourne, cela arrêterait tous les conteneurs le temps du redémarrage.
if systemctl --user is-active --quiet docker.service; then
  info "démon déjà actif — laissé en place"
else
  systemctl --user start docker.service
fi
for _ in $(seq 40); do docker info >/dev/null 2>&1 && break; sleep 0.5; done
docker info >/dev/null 2>&1 || mourir "le démon rootless ne répond pas — journalctl --user -u docker"

PILOTE=$(docker info --format '{{.Driver}}')
SECU=$(docker info --format '{{range .SecurityOptions}}{{.}} {{end}}')
case "$SECU" in *rootless*) ok "démon ROOTLESS opérationnel, pilote $PILOTE" ;;
                *) ko "le démon répond mais n'est PAS rootless (options : $SECU)" ;; esac
case "$PILOTE" in
  overlay*) : ;;
  *) info "pilote $PILOTE : MinIO peut refuser d'écrire ; diag_rootless.sh dira si le repli MINIO_DATA est nécessaire" ;;
esac
info "ulimit -n = $(ulimit -n), memlock = $(ulimit -l)"
ok "docker compose $(docker compose version --short 2>/dev/null || echo '?')"
