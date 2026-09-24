#!/usr/bin/env bash
# Sauvegarde complète de la plateforme CTI : volumes Docker, montages liés (root),
# configuration (.env), état et caches des importateurs, et les trois dépôts git.
# N'inclut PAS les images Docker (elles se retéléchargent depuis les registres).
#
# Aucune compression : le gros du contenu (index Lucene, pages InnoDB, objets MinIO,
# pièces jointes MISP) est déjà compressé — gzip coûterait des dizaines de minutes
# pour un gain marginal. Archive tar simple, lecture/écriture au débit du disque.
#
# Usage : provisioning/backup_infra.sh [répertoire de destination]
# À exécuter conteneurs ARRÊTÉS (cohérence des bases MySQL / Elasticsearch).
set -euo pipefail

DEST="${1:-/home/deel/backups}"
STAMP="$(date +%Y-%m-%d)"
NAME="cti-infra-${STAMP}"
WORK="${DEST}/${NAME}"
# racine du dépôt déduite du script : aucun chemin en dur, le clone peut
# porter n'importe quel nom de dossier.
REPO_PLATFORM="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM_DIR="$(basename "$REPO_PLATFORM")"
# dépôt d'alimentation (optionnel) : CONTENT_REPO_DIR=/chemin ; sinon rien de plus n'est sauvegardé
REPO_FARM="${CONTENT_REPO_DIR:-}"
REPO_FEEDS="$(ls -d /tmp/claude-1000/*/*/scratchpad/CTI-feeds 2>/dev/null | head -1 || true)"
HELPER="alpine:latest"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

if [ "$(docker ps -q | wc -l)" -ne 0 ]; then
  log "ATTENTION : des conteneurs tournent — arrêter les piles d'abord (make down / make opencti-down)"
  exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK"/{volumes,bind-mounts,config,repos,state}
log "destination : $WORK"

# --- 1. volumes Docker -------------------------------------------------------
log "volumes Docker"
docker volume ls --format '{{.Name}}' | while read -r v; do
  docker run --rm -v "${v}:/src:ro" -v "$WORK/volumes:/dst" "$HELPER" \
    tar cf "/dst/${v}.tar" -C /src . 2>/dev/null || { log "  échec $v"; continue; }
  printf '  %-64s %s\n' "$v" "$(du -h "$WORK/volumes/${v}.tar" | cut -f1)"
done

# --- 2. montages liés de la pile MISP (appartiennent à root) -----------------
log "montages liés MISP (configs, files, logs, ssl, gnupg)"
docker run --rm -v "${REPO_PLATFORM}/vendor/misp-docker:/src:ro" -v "$WORK/bind-mounts:/dst" "$HELPER" \
  tar cf /dst/misp-docker-bind-mounts.tar -C /src configs files logs ssl gnupg 2>/dev/null || true
du -h "$WORK/bind-mounts/misp-docker-bind-mounts.tar" 2>/dev/null | sed 's/^/  /'

# --- 3. configuration : secrets et environnement -----------------------------
log "configuration (.env, crontab, inventaire des images)"
for f in "${REPO_PLATFORM}/vendor/misp-docker/.env" "${REPO_PLATFORM}/opencti/.env" "${REPO_PLATFORM}/ciso-assistant/.env" ${REPO_FARM:+"${REPO_FARM}/.env"}; do
  [ -f "$f" ] && cp -a "$f" "$WORK/config/$(echo "${f#$REPO_PLATFORM/}" | tr / _)"
done
crontab -l > "$WORK/config/crontab.txt" 2>/dev/null || echo "(pas de crontab)" > "$WORK/config/crontab.txt"
docker images --format '{{.Repository}}:{{.Tag}}' | sort > "$WORK/config/images-presentes.txt"

# --- 4. état et caches des importateurs --------------------------------------
log "état des importateurs, caches de collecte, livrables"
[ -n "$REPO_FARM" ] && tar cf "$WORK/state/content-state.tar" -C "$REPO_FARM" importers/.state importers/.cron importers/.cache 2>/dev/null || true
[ -d "$REPO_PLATFORM/dist" ] && tar cf "$WORK/state/dist.tar" -C "$REPO_PLATFORM" dist 2>/dev/null || true
du -h "$WORK"/state/*.tar 2>/dev/null | sed 's/^/  /'

# --- 5. dépôts git (arbre de travail + historique) ---------------------------
log "dépôts git"
tar cf "$WORK/repos/CTI-Platform.tar" -C "$(dirname "$REPO_PLATFORM")" \
  --exclude="$PLATFORM_DIR/.venv" \
  --exclude="$PLATFORM_DIR/dist" \
  --exclude="$PLATFORM_DIR/vendor/misp-docker/configs" \
  --exclude="$PLATFORM_DIR/vendor/misp-docker/files" \
  --exclude="$PLATFORM_DIR/vendor/misp-docker/logs" \
  --exclude="$PLATFORM_DIR/vendor/misp-docker/ssl" \
  --exclude="$PLATFORM_DIR/vendor/misp-docker/gnupg" \
  "$PLATFORM_DIR" 2>/dev/null || true
[ -n "$REPO_FARM" ] && tar cf "$WORK/repos/content-repo.tar" -C "$(dirname "$REPO_FARM")" --exclude="$(basename "$REPO_FARM")/.venv" --exclude="$(basename "$REPO_FARM")/importers/.cache" "$(basename "$REPO_FARM")" 2>/dev/null || true
if [ -n "$REPO_FEEDS" ] && [ -d "$REPO_FEEDS" ]; then
  tar cf "$WORK/repos/CTI-feeds.tar" -C "$(dirname "$REPO_FEEDS")" "$(basename "$REPO_FEEDS")" 2>/dev/null || true
fi
du -h "$WORK"/repos/*.tar 2>/dev/null | sed 's/^/  /'

# --- 6. manifeste ------------------------------------------------------------
log "manifeste"
{
  echo "# Sauvegarde de la plateforme CTI — ${STAMP}"
  echo
  echo "Machine : $(hostname) — $(uname -sr) | Docker : $(docker --version)"
  echo "Conteneurs arrêtés pendant la sauvegarde (volumes cohérents). Sans compression."
  echo
  echo "## Contenu"
  echo "- volumes/     : un .tar par volume Docker — MySQL MISP, Elasticsearch, RabbitMQ (file d'ingestion),"
  echo "                 Redis, MinIO, cache MISP, plus les volumes anonymes des conteneurs retirés"
  echo "- bind-mounts/ : configs, files (pièces jointes MISP), logs, ssl, gnupg de la pile MISP"
  echo "- config/      : fichiers .env (SECRETS : clés MISP, jeton OpenCTI, ciso-assistant/.env s'il existe), crontab, images à retélécharger"
  echo "- state/       : déduplication des importateurs, caches de collecte du dépôt d'alimentation s'il est désigné, dist/"
  echo "- repos/       : les trois dépôts git avec leur historique"
  echo
  echo "## Restauration"
  echo "1. détarer les dépôts, remettre les .env dans vendor/misp-docker/, opencti/ et ciso-assistant/ s'il existe (et celui du dépôt d'alimentation s'il était sauvegardé)"
  echo "2. volumes : docker volume create <nom> puis"
  echo "   docker run --rm -v <nom>:/dst -v \$PWD/volumes:/src alpine tar xf /src/<nom>.tar -C /dst"
  echo "3. montages liés : tar xf bind-mounts/misp-docker-bind-mounts.tar -C <clone>/vendor/misp-docker (en root)"
  echo "4. git submodule update --init dans CTI-Platform, puis make up et make opencti-up"
  echo
  echo "## Dépôts au moment de la sauvegarde"
  for r in "$REPO_PLATFORM" ${REPO_FARM:+"$REPO_FARM"} "$REPO_FEEDS"; do
    [ -d "$r/.git" ] || continue
    echo "- $(basename "$r") : $(git -C "$r" log --format='%h %an <%ae> %s' -1 | cut -c1-110)"
  done
  echo
  echo "## Tailles"
  ( cd "$WORK" && find . -name '*.tar' | sort | while read -r f; do printf '%8s  %s\n' "$(du -h "$f" | cut -f1)" "$f"; done )
} > "$WORK/MANIFEST.md"

# --- 7. archive finale -------------------------------------------------------
log "archive finale"
tar cf "${DEST}/${NAME}.tar" -C "$DEST" "$NAME"
chmod 600 "${DEST}/${NAME}.tar"
rm -rf "$WORK"
log "terminé : ${DEST}/${NAME}.tar ($(du -h "${DEST}/${NAME}.tar" | cut -f1))"
