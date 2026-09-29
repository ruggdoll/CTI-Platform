#!/usr/bin/env bash
# maj_nocturne.sh — MAJ quotidienne (fenêtre 3h-4h) : pull des images puis
# redémarrage complet. Appelé par le timer posé par `make maj-nocturne-on`.
# Tags 'latest' partout (MISP compris, via misp-nginx en frontend séparé) sauf
# Elasticsearch (docker.elastic.co ne publie pas de tag 'latest' : ES_TAG est
# résolue dynamiquement ci-dessous plutôt que pilotée par un tag mobile).
#
# `set -e` + pull AVANT down : si le pull échoue (image indisponible, réseau),
# le script s'arrête là et les piles déjà debout ne sont JAMAIS coupées pour
# une image qu'on n'a pas réussi à récupérer.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

log() { printf '[%s] %s\n' "$(date -Is)" "$1"; }

log "résolution ES_TAG (docker.elastic.co ne publie pas de tag 'latest')"
if es_tag=$(.venv/bin/python provisioning/es_tag_latest.py); then
  sed -i "s/^ES_TAG=.*/ES_TAG=${es_tag}/" opencti/.env
  log "ES_TAG=${es_tag}"
else
  log "résolution ES_TAG échouée — on garde la version actuelle de opencti/.env (pas fatal, le reste continue)"
fi

log "pull MISP + OpenCTI"
make pull-cti

log "redémarrage MISP + OpenCTI"
make down-cti
make up-cti

# CISO-Assistant est découplé (jamais dans build-cti) : pas installé sur tous
# les hôtes. Même critère que `make up-ciso` (CISO_HOSTNAME configuré) pour
# décider s'il y a quelque chose à mettre à jour — sinon on l'ignore proprement
# plutôt que de faire échouer toute la MAJ nocturne sur un produit absent.
if grep -qsE '^CISO_HOSTNAME=.+' ciso-assistant/.env 2>/dev/null; then
  log "pull CISO-Assistant"
  make pull-ciso
  log "redémarrage CISO-Assistant"
  make down-ciso
  make up-ciso
else
  log "CISO-Assistant non installé (pas de CISO_HOSTNAME dans ciso-assistant/.env) — ignoré"
fi

log "terminé"
