#!/usr/bin/env bash
# prepare_host.sh — prépare une Debian 13 (trixie) vierge à faire tourner
# CTI-Platform en Docker ROOTLESS. Tout ce qui exige root est ici, et rien
# d'autre : après ce script, la plateforme se construit sans aucun privilège.
#
#   sudo provisioning/prepare_host.sh --user cti-platform --host <fqdn> \
#        [--ip <adresse>] [--ssh-key <fichier|clé publique>]
#
# Derrière un proxy inverse (deux identités), remplacer --host par :
#   --domaine here.local        -> enregistre misp.here.local ET opencti.here.local
#
# Puis, en tant que l'utilisateur créé :
#   git clone --recurse-submodules <dépôt> ~/CTI-Platform && cd ~/CTI-Platform
#   make build-cti HOST=<fqdn>
#
# Idempotent : relançable sur un hôte déjà préparé, il constate et n'abîme rien.
#
# Ce que ce script existe pour éviter, constaté sur un déploiement réel :
#   - `uidmap` absent : le démon rootless ne démarre pas, message obscur ;
#   - pas de linger : les conteneurs meurent à la déconnexion SSH ;
#   - vm.max_map_count par défaut : Elasticsearch refuse de démarrer ;
#   - ports 80/443 non liables par un démon rootless ;
#   - nofile/memlock trop bas : un démon rootless ne peut PAS les relever ;
#   - le FQDN laissé sur 127.0.1.1 par l'installateur Debian : MISP et OpenCTI
#     fabriquent alors toutes leurs URL absolues sur du loopback.
set -euo pipefail

ok()   { printf '  \033[32mOK\033[0m     %s\n' "$1"; }
ko()   { printf '  \033[31mÉCHEC\033[0m  %s\n' "$1"; }
info() { printf '  ·      %s\n' "$1"; }
etape(){ printf '\n\033[1m== %s\033[0m\n' "$*"; }
mourir(){ ko "$1"; exit 1; }

UTILISATEUR=""; NOM_PUBLIC=""; ADRESSE=""; CLE_SSH=""; DOMAINE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --user) UTILISATEUR="${2:-}"; shift 2 ;;
    --host) NOM_PUBLIC="${2:-}"; shift 2 ;;
    --domaine) DOMAINE="${2:-}"; shift 2 ;;
    --ip)   ADRESSE="${2:-}";    shift 2 ;;
    --ssh-key) CLE_SSH="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) mourir "argument inconnu : $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || mourir "à lancer en root (sudo)"
[ -n "$UTILISATEUR" ] || mourir "--user <compte> est obligatoire (le compte qui fera tourner la plateforme)"
# --domaine dérive les deux identités du mode proxy inverse ; --host reste la
# forme à une seule façade. Les deux noms doivent résoudre de la même façon.
if [ -n "$DOMAINE" ]; then
  NOMS="misp.$DOMAINE opencti.$DOMAINE"
  NOM_PUBLIC="misp.$DOMAINE"
else
  NOMS="$NOM_PUBLIC"
fi
[ -n "$NOM_PUBLIC" ] || mourir "--host <fqdn|ip> ou --domaine <domaine> est obligatoire (par quoi les CLIENTS joindront la plateforme)"

etape "0  Hôte"
. /etc/os-release
DISTRO="${ID:-debian}"; NOM_CODE="${VERSION_CODENAME:-trixie}"
info "${PRETTY_NAME:-inconnu}, noyau $(uname -r)"
[ "${ID:-}" = "debian" ] || info "ATTENTION : ce script vise Debian ; les noms de paquets peuvent différer ici"
case "${VERSION_ID:-0}" in
  13|14|15) ok "version supportée" ;;
  *) info "ATTENTION : testé sur Debian 13 (trixie), pas sur cette version" ;;
esac
# overlay2 natif en rootless exige >= 5.11 ; en dessous, repli fuse-overlayfs
NOYAU_MAJ=$(uname -r | cut -d. -f1); NOYAU_MIN=$(uname -r | cut -d. -f2)
if [ "$NOYAU_MAJ" -gt 5 ] || { [ "$NOYAU_MAJ" -eq 5 ] && [ "$NOYAU_MIN" -ge 11 ]; }; then
  ok "noyau >= 5.11 : overlay2 utilisable en rootless"
else
  info "noyau < 5.11 : Docker rootless retombera sur fuse-overlayfs (MinIO y est capricieux)"
fi
MEM_MO=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
info "mémoire : ${MEM_MO} Mo"
[ "$MEM_MO" -ge 15000 ] || info "ATTENTION : moins de 15 Go — MISP (~4 Go) + OpenCTI (~12 Go) seront à l'étroit"

etape "1  Adresse publique"
if [ -z "$ADRESSE" ]; then
  ADRESSE=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  info "adresse détectée : ${ADRESSE:-aucune}"
fi
[ -n "$ADRESSE" ] || mourir "aucune adresse globale trouvée — préciser --ip <adresse>"
case "$ADRESSE" in 127.*|::1) mourir "--ip $ADRESSE est du loopback : les conteneurs n'y joindront jamais l'hôte" ;; esac
for NOM in $NOMS; do
if [ "$NOM" != "$ADRESSE" ]; then
  # l'installateur Debian écrit « 127.0.1.1 <fqdn> <court> » : à remplacer, pas à doubler
  # Comparaison champ par champ : dans un FQDN, `.` est un joker pour grep et
  # un motif naïf produit des faux positifs.
  if awk '$1=="127.0.1.1"{for(i=2;i<=NF;i++) if($i==N) trouve=1} END{exit !trouve}' N="$NOM" /etc/hosts; then
    cp -n /etc/hosts /etc/hosts.avant-cti-platform
    sed -i "/^127\.0\.1\.1[[:space:]]/d" /etc/hosts
    info "ligne 127.0.1.1 retirée (sauvegarde : /etc/hosts.avant-cti-platform)"
  fi
  if awk '$1==IP{for(i=2;i<=NF;i++) if($i==N) trouve=1} END{exit !trouve}' IP="$ADRESSE" N="$NOM" /etc/hosts; then
    ok "/etc/hosts : $NOM -> $ADRESSE déjà présent"
  else
    printf '%s\t%s\t%s\n' "$ADRESSE" "$NOM" "${NOM%%.*}" >> /etc/hosts
    ok "/etc/hosts : $NOM -> $ADRESSE ajouté"
  fi
fi
# ahostsv4, pas hosts : ce dernier interroge aussi le DNS public pour l'AAAA
# quand /etc/hosts (qu'on vient d'écrire) ne porte qu'une ligne IPv4, et la
# renvoie en premier (préférence IPv6 de la résolution système) — une adresse
# PUBLIQUE potentiellement injoignable depuis les conteneurs, à la place du
# LAN qu'on vient d'y écrire. Le SERVEUR n'a pas à dépendre du DNS public
# pour se joindre lui-même ; que le nom résolve pour de vrais clients
# externes est une question distincte, hors du périmètre de CE contrôle.
RESOLU=$(getent ahostsv4 "$NOM" 2>/dev/null | awk '{print $1; exit}' || true)
case "$RESOLU" in
  "")     mourir "$NOM ne se résout pas (IPv4)" ;;
  127.*)  mourir "$NOM résout sur $RESOLU (loopback) — corriger /etc/hosts" ;;
  *)      ok "$NOM résout sur $RESOLU" ;;
esac
done
etape "2  Paquets"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq uidmap dbus-user-session fuse-overlayfs slirp4netns iptables \
                       git make python3 python3-venv curl ca-certificates gnupg openssl >/dev/null
ok "dépendances posées (uidmap, dbus-user-session, slirp4netns, outillage)"
if [ -n "$DOMAINE" ]; then
  # Autorité locale de la façade HTTPS (Traefik n'en tient pas une lui-même,
  # contrairement à Caddy) : mkcert génère et signe le certificat des deux
  # noms, `make init`/`make proxy-cert` l'invoquent sous le compte de service.
  apt-get install -y -qq mkcert >/dev/null
  ok "mkcert installé : $(mkcert -version 2>&1 | head -1)"
fi

etape "3  Docker CE + extras rootless"
# Le paquet docker.io de Debian entre en conflit avec docker-ce et ne fournit
# pas les extras rootless : mieux vaut s'arrêter ici que produire un demi-état.
if dpkg -l docker.io 2>/dev/null | grep -q '^ii'; then
  mourir "le paquet docker.io de Debian est installé — le retirer (apt purge docker.io) avant de relancer"
fi
if ! command -v dockerd-rootless-setuptool.sh >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${DISTRO}/gpg" | gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRO} ${NOM_CODE} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
                         docker-compose-plugin docker-ce-rootless-extras >/dev/null
  ok "Docker CE installé : $(docker --version)"
else
  ok "Docker déjà présent : $(docker --version)"
fi
# Le démon SYSTÈME n'a rien à faire ici : on déploie en rootless, et un démon
# root actif en parallèle ne sert qu'à récupérer par erreur un socket privilégié.
systemctl disable --now docker.service docker.socket >/dev/null 2>&1 || true
systemctl is-active --quiet docker.service && ko "le démon rootful tourne encore" || ok "démon rootful désactivé"

etape "4  Ports privilégiés 80/443"
ROOTLESSKIT=$(command -v rootlesskit || echo /usr/bin/rootlesskit)
if [ -x "$ROOTLESSKIT" ]; then
  setcap cap_net_bind_service=ep "$ROOTLESSKIT"
  ok "$ROOTLESSKIT : $(getcap "$ROOTLESSKIT" | sed 's/.* //')"
  info "un démon rootless peut désormais lier 80 et 443, sans ouvrir 80-1023 aux autres comptes"
else
  ko "rootlesskit introuvable — publier en haut port (CORE_HTTP_PORT/CORE_HTTPS_PORT) et mettre un relais devant"
fi

etape "5  Réglages noyau"
cat > /etc/sysctl.d/99-cti-platform.conf <<'EOF'
# Elasticsearch (pile OpenCTI) alloue ses index en memory-mapped files : sous
# 262144 il refuse de démarrer, et le contrôle est bloquant en conteneur.
vm.max_map_count=1048575
EOF
sysctl -q -p /etc/sysctl.d/99-cti-platform.conf
ok "vm.max_map_count = $(cat /proc/sys/vm/max_map_count)"

etape "6  Compte « $UTILISATEUR »"
if id "$UTILISATEUR" >/dev/null 2>&1; then
  ok "compte déjà présent (uid $(id -u "$UTILISATEUR"))"
else
  useradd --create-home --shell /bin/bash "$UTILISATEUR"
  ok "compte créé (uid $(id -u "$UTILISATEUR"))"
fi
UID_CIBLE=$(id -u "$UTILISATEUR")
FOYER=$(getent passwd "$UTILISATEUR" | cut -d: -f6)
# Le compte est créé sans mot de passe : sans clé, personne ne peut s'y
# connecter — et le démon rootless exige une VRAIE session, pas un `sudo -u`.
if [ -n "$CLE_SSH" ]; then
  [ -f "$CLE_SSH" ] && CONTENU=$(cat "$CLE_SSH") || CONTENU="$CLE_SSH"
  install -d -m 700 -o "$UTILISATEUR" -g "$UTILISATEUR" "$FOYER/.ssh"
  touch "$FOYER/.ssh/authorized_keys"
  if grep -qxF "$CONTENU" "$FOYER/.ssh/authorized_keys"; then
    ok "clé SSH déjà autorisée pour $UTILISATEUR"
  else
    printf '%s\n' "$CONTENU" >> "$FOYER/.ssh/authorized_keys"
    ok "clé SSH autorisée pour $UTILISATEUR"
  fi
  chown "$UTILISATEUR:$UTILISATEUR" "$FOYER/.ssh/authorized_keys"
  chmod 600 "$FOYER/.ssh/authorized_keys"
elif [ ! -s "$FOYER/.ssh/authorized_keys" ] 2>/dev/null; then
  info "aucune clé SSH pour $UTILISATEUR : y accéder par « machinectl shell $UTILISATEUR@ »,"
  info "  ou relancer avec --ssh-key <fichier>. Un sudo -u ne convient PAS pour le rootless."
fi
# Plages d'UID/GID déléguées : sans elles, newuidmap ne peut pas construire
# l'espace de noms utilisateur et le démon rootless ne démarre pas du tout.
if grep -q "^${UTILISATEUR}:" /etc/subuid && grep -q "^${UTILISATEUR}:" /etc/subgid; then
  ok "subuid/subgid : $(grep "^${UTILISATEUR}:" /etc/subuid)"
else
  DEBUT=$(( 100000 + UID_CIBLE * 65536 ))
  usermod --add-subuids "${DEBUT}-$((DEBUT + 65535))" --add-subgids "${DEBUT}-$((DEBUT + 65535))" "$UTILISATEUR"
  ok "subuid/subgid attribués : ${DEBUT}-$((DEBUT + 65535))"
fi
# Elasticsearch réclame 65536 descripteurs et la pile pose memlock illimité.
# Un démon rootless ne peut pas dépasser les limites de son utilisateur.
cat > "/etc/security/limits.d/99-cti-platform.conf" <<EOF
$UTILISATEUR soft nofile 65536
$UTILISATEUR hard nofile 1048576
$UTILISATEUR soft memlock unlimited
$UTILISATEUR hard memlock unlimited
EOF
ok "limites nofile/memlock accordées à $UTILISATEUR"
# À l'extinction, systemd arrête la session utilisateur, donc le démon Docker,
# qui arrête les conteneurs. Le plafond par défaut (2 min) ne laisse pas à
# MariaDB le temps de vider un gros buffer pool ni à Elasticsearch d'écrire son
# translog : ils sont tués en pleine écriture et repartent en récupération.
# Drop-in ciblé sur CETTE instance, pas sur toutes les sessions de la machine.
install -d "/etc/systemd/system/user@${UID_CIBLE}.service.d"
cat > "/etc/systemd/system/user@${UID_CIBLE}.service.d/10-cti-platform.conf" <<EOF
[Service]
# Laisser aux deux piles le temps de se fermer proprement (voir make autostart).
TimeoutStopSec=300
EOF
systemctl daemon-reload
ok "délai d'arrêt de la session $UTILISATEUR porté à 300 s"
# Sans linger, la session systemd de l'utilisateur disparaît à la déconnexion
# et emporte le démon rootless — donc toute la plateforme.
loginctl enable-linger "$UTILISATEUR"
for _ in $(seq 20); do [ -d "/run/user/$UID_CIBLE" ] && break; sleep 0.5; done
[ -d "/run/user/$UID_CIBLE" ] && ok "linger actif, /run/user/$UID_CIBLE en place" \
                              || mourir "/run/user/$UID_CIBLE absent — session utilisateur non démarrée"

etape "7  Démon rootless de « $UTILISATEUR »"
SUITE="$(cd "$(dirname "$0")" && pwd)/rootless_setup.sh"
[ -f "$SUITE" ] || mourir "provisioning/rootless_setup.sh introuvable à côté de ce script"
install -m 0755 "$SUITE" "/tmp/rootless_setup.$$.sh"
runuser -u "$UTILISATEUR" -- env \
  XDG_RUNTIME_DIR="/run/user/$UID_CIBLE" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_CIBLE/bus" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  bash "/tmp/rootless_setup.$$.sh"
rm -f "/tmp/rootless_setup.$$.sh"

printf '\n\033[1m== Hôte prêt\033[0m\n'
echo "  Se connecter en $UTILISATEUR — connexion SSH réelle, ou « machinectl shell"
echo "  $UTILISATEUR@ » ; JAMAIS sudo -u, qui ne donne ni XDG_RUNTIME_DIR ni bus"
echo "  systemd et laisse le client Docker muet. Puis :"
echo
echo "    git clone --recurse-submodules https://github.com/ruggdoll/CTI-Platform ~/CTI-Platform"
echo "    cd ~/CTI-Platform && make build-cti ${DOMAINE:+DOMAINE=$DOMAINE}${DOMAINE:-HOST=$NOM_PUBLIC}"
echo
echo "  make init détectera le démon rootless et visera $RESOLU pour extra_hosts."
