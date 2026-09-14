#!/usr/bin/env bash
# diag_rootless.sh — diagnostic d'un hôte Docker ROOTLESS avant ou après un
# déploiement de la plateforme. Ne modifie rien : il constate et conclut.
#
# À lancer SUR LA MACHINE CIBLE, avec le compte qui lance les `make` :
#     bash provisioning/diag_rootless.sh
#
# Il répond à quatre questions qui, réunies, expliquent l'essentiel des échecs
# de déploiement distant constatés :
#   1. le démon est-il en mode rootless, et sur quel pilote de stockage ?
#   2. MinIO sait-il écrire dans un VOLUME nommé ? (droits du volume neuf)
#   3. MinIO sait-il écrire dans un RÉPERTOIRE lié de l'utilisateur ?
#      (contournement quand le pilote de stockage ne convient pas à MinIO)
#   4. les ports privilégiés 80/443 de la pile MISP sont-ils liables ?
set -u
IMAGE="${MINIO_IMAGE:-quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z}"
ok()   { printf '  \033[32mOK\033[0m     %s\n' "$1"; }
ko()   { printf '  \033[31mÉCHEC\033[0m  %s\n' "$1"; }
info() { printf '  ·      %s\n' "$1"; }

echo "== 1. mode du démon =="
if docker info --format '{{range .SecurityOptions}}{{.}} {{end}}' 2>/dev/null | grep -q rootless; then
  info "démon ROOTLESS"
else
  info "démon classique (rootful)"
fi
info "pilote de stockage : $(docker info --format '{{.Driver}}' 2>/dev/null)"
info "racine des données : $(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
info "version serveur    : $(docker version --format '{{.Server.Version}}' 2>/dev/null)"

echo "== 2. image MinIO =="
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  ok "image présente localement : $IMAGE"
else
  if docker pull "$IMAGE" >/dev/null 2>&1; then ok "image téléchargée depuis $IMAGE"
  else ko "téléchargement impossible : $IMAGE"; fi
fi
if docker manifest inspect minio/minio:latest >/dev/null 2>&1; then
  info "docker.io/minio/minio reste accessible anonymement"
else
  info "docker.io/minio/minio REFUSE l'accès anonyme — d'où l'épinglage sur quay.io"
fi

echo "== 3. MinIO sur un VOLUME nommé =="
VOL=diag_minio_volume_$$
docker volume create "$VOL" >/dev/null
SORTIE=$(docker run --rm --name diag_minio_$$ -v "$VOL":/data \
           -e MINIO_ROOT_USER=diagnostic -e MINIO_ROOT_PASSWORD=diagnostic123 \
           "$IMAGE" server /data 2>&1 & sleep 12; docker logs diag_minio_$$ 2>&1 | head -30; docker rm -f diag_minio_$$ >/dev/null 2>&1)
if grep -qi "file access denied\|permission denied\|drive may be faulty" <<<"$SORTIE"; then
  ko "MinIO ne peut pas écrire dans le volume nommé"
  grep -i "Error" <<<"$SORTIE" | head -3 | sed 's/^/         /'
  info "réparation : make minio-droits  (chown du volume par conteneur jetable)"
elif grep -qi "MinIO Object Storage Server\|API:" <<<"$SORTIE"; then
  ok "MinIO démarre sur un volume nommé"
else
  info "sortie non concluante :"; head -5 <<<"$SORTIE" | sed 's/^/         /'
fi
docker volume rm "$VOL" >/dev/null 2>&1

echo "== 4. MinIO sur un RÉPERTOIRE LIÉ de l'utilisateur =="
REP=$(mktemp -d "${HOME}/diag-minio-XXXXXX")
SORTIE=$(docker run --rm --name diag_minio_b_$$ -v "$REP":/data \
           -e MINIO_ROOT_USER=diagnostic -e MINIO_ROOT_PASSWORD=diagnostic123 \
           "$IMAGE" server /data 2>&1 & sleep 12; docker logs diag_minio_b_$$ 2>&1 | head -30; docker rm -f diag_minio_b_$$ >/dev/null 2>&1)
if grep -qi "file access denied\|permission denied\|drive may be faulty" <<<"$SORTIE"; then
  ko "MinIO ne peut pas écrire non plus dans un répertoire lié ($REP)"
  grep -i "Error" <<<"$SORTIE" | head -3 | sed 's/^/         /'
elif grep -qi "MinIO Object Storage Server\|API:" <<<"$SORTIE"; then
  ok "MinIO démarre sur un répertoire lié — repli utilisable : MINIO_DATA=$REP"
else
  info "sortie non concluante :"; head -5 <<<"$SORTIE" | sed 's/^/         /'
fi
rm -rf "$REP" 2>/dev/null || docker run --rm -v "$REP":/x alpine:3 rm -rf /x/. >/dev/null 2>&1

echo "== 5. ports privilégiés (pile MISP : 80 et 443) =="
DEBUT=$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null || echo "?")
info "ip_unprivileged_port_start = $DEBUT"
# On essaie un port privilégié LIBRE : tester 80 directement rendrait un faux
# négatif sur une machine où la pile MISP écoute déjà dessus.
PORT=""
for p in 81 82 83 88 89 444 445; do
  ss -ltn 2>/dev/null | grep -q ":$p " || { PORT=$p; break; }
done
PORT=${PORT:-81}
SORTIE=$(docker run --rm -p "127.0.0.1:$PORT:$PORT" alpine:3 true 2>&1)
if [ -z "$SORTIE" ]; then
  ok "les ports privilégiés sont liables (essai sur $PORT)"
elif grep -qi "permission denied\|bind: permission" <<<"$SORTIE"; then
  ko "les ports privilégiés NE SONT PAS liables par ce démon (essai sur $PORT)"
  info "en rootless : soit 'sudo sysctl -w net.ipv4.ip_unprivileged_port_start=0'"
  info "  (persistant via /etc/sysctl.d/), soit publier en haut port et mettre un"
  info "  relais devant : CORE_HTTP_PORT=8080 CORE_HTTPS_PORT=8443 dans .env"
else
  info "essai non concluant sur $PORT : $(head -1 <<<"$SORTIE")"
fi
echo "== fin du diagnostic =="
