#!/usr/bin/env bash
# Construction complète de la plateforme, dans le bon ordre, avec les attentes.
#
# Les étapes ci-dessous ne sont pas interchangeables : le socle de connaissance
# (référentiels MISP, ATT&CK) doit être en place AVANT que la moindre donnée
# n'arrive, sans quoi les tags ne sont pas validés, les faux positifs ne sont
# pas filtrés, et les techniques citées dans un rapport créent des souches
# vides à fusionner ensuite. Cette orchestration existe pour qu'on n'ait pas à
# s'en souvenir.
#
# Idempotent : relançable sur une plateforme déjà partiellement construite.
# Usage : make build HOST=<fqdn|ip>
set -euo pipefail
cd "$(dirname "$0")/.."

etape() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
attendre() {   # attendre <libellé> <timeout_s> <commande de test>
  local libelle="$1" limite="$2"; shift 2
  local t0=$SECONDS
  until "$@" >/dev/null 2>&1; do
    if (( SECONDS - t0 > limite )); then
      echo "  échec : $libelle toujours indisponible après ${limite}s" >&2
      return 1
    fi
    sleep 5
  done
  echo "  $libelle prêt en $((SECONDS - t0))s"
}

HOST_ARG="${HOST:-}"
PY=./.venv/bin/python

etape "1/9  Fichiers d'environnement"
if [ -n "$HOST_ARG" ]; then make --no-print-directory init HOST="$HOST_ARG"; else make --no-print-directory init; fi
HOST_REEL=$(grep -E '^OPENCTI_HOST=' opencti/.env | cut -d= -f2)

etape "2/9  Pile MISP"
make --no-print-directory up
KEY=$(grep -E '^MISP_KEY=' opencti/.env | cut -d= -f2)
attendre "API MISP" 900 bash -c \
  "curl -sk -H 'Authorization: $KEY' -H 'Accept: application/json' \
   https://$HOST_REEL/organisations/view/1 | grep -q '\"Organisation\"'"

etape "3/9  Environnement Python"
[ -x "$PY" ] || make --no-print-directory venv

etape "4/9  Socle MISP (galaxies, taxonomies, warninglists)"
make --no-print-directory socle-misp

etape "5/9  Pile OpenCTI + socle ATT&CK"
make --no-print-directory opencti-up
attendre "API OpenCTI" 1800 bash -c \
  "curl -s -o /dev/null -w '%{http_code}' http://$HOST_REEL:8080/graphql | grep -qE '200|400|405'"
echo "  chargement de l'ATT&CK (sans concurrence) — cela prend plusieurs minutes"
$PY provisioning/attack_status.py --wait

etape "6/9  Pont OpenCTI -> MISP"
make --no-print-directory bridge-setup
make --no-print-directory opencti-up

etape "7/9  Socle OpenCTI (rapports STIX publics VIGINUM)"
$PY provisioning/opencti_socle.py --yes

etape "8/9  Connecteurs de flux OpenCTI"
make --no-print-directory opencti-feeds

etape "9/9  Arrêt propre à l'extinction"
# Sans cette unité, une extinction (ou le redémarrage d'un correctif de
# sécurité) tue MariaDB et Elasticsearch au bout des 15 s de dockerd.
# AUTOSTART=0 pour s'en passer.
if [ "${AUTOSTART:-1}" = "1" ]; then
  make --no-print-directory autostart
else
  echo "  ignorée (AUTOSTART=0)"
fi

printf '\n\033[1m== Plateforme construite\033[0m\n'
echo "  MISP    : https://$HOST_REEL"
echo "  OpenCTI : http://$HOST_REEL:8080"
echo "  Contrôle de bout en bout : make bridge-test"
