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
if [ -n "${DOMAINE:-}" ]; then make --no-print-directory init DOMAINE="$DOMAINE"
elif [ -n "$HOST_ARG" ]; then make --no-print-directory init HOST="$HOST_ARG"
else make --no-print-directory init; fi

# Les sondes du build visent la BOUCLE LOCALE et les ports publiés, jamais les
# noms publics : la construction ne doit dépendre ni du DNS, ni d'un proxy qui
# n'est démarré qu'en fin de parcours. Les URL publiques ne servent qu'à
# l'affichage final.
lire() { grep -E "^$2=" "$1" | cut -d= -f2- | head -1; }
SONDE_MISP="https://127.0.0.1:$(lire vendor/misp-docker/.env CORE_HTTPS_PORT)"
SONDE_OCTI="http://127.0.0.1:$(lire opencti/.env OPENCTI_PORT)"
URL_MISP=$(lire vendor/misp-docker/.env BASE_URL)
URL_OCTI=$(lire opencti/.env OPENCTI_BASE_URL)
[ -n "$URL_OCTI" ] || URL_OCTI="$(lire opencti/.env OPENCTI_EXTERNAL_SCHEME)://$(lire opencti/.env OPENCTI_HOST):$(lire opencti/.env OPENCTI_PORT)"

etape "2/9  Pile MISP"
make --no-print-directory up
KEY=$(grep -E '^MISP_KEY=' opencti/.env | cut -d= -f2)
attendre "API MISP" 900 bash -c \
  "curl -sk -H 'Authorization: $KEY' -H 'Accept: application/json' \
   $SONDE_MISP/organisations/view/1 | grep -q '\"Organisation\"'"

# La façade HTTPS démarre ICI, pas avec le reste de la pile OpenCTI : les
# outils de provisionnement joignent MISP par son URL PUBLIQUE, qui ne répond
# que par elle dès lors que les piles sont repliées sur la boucle locale.
# `compose up -d proxy` crée le réseau du projet OpenCTI (et celui de
# CISO-Assistant, si CISO_HOSTNAME est renseigné, pour que sa façade soit prête
# le jour où on la démarre — 'make build' ne la construit jamais elle-même,
# voir plus bas) au passage ; le reste de la pile suivra à l'étape 5/9.
if grep -qsE '^MISP_HOSTNAME=.+' opencti/.env; then
  etape "2 bis/9  Façade HTTPS"
  make --no-print-directory proxy-up
  attendre "MISP par son nom public ($URL_MISP)" 300 bash -c \
    "curl -sk -o /dev/null -w '%{http_code}' $URL_MISP/users/login | grep -qE '200|302'"
fi

etape "3/9  Environnement Python"
[ -x "$PY" ] || make --no-print-directory venv

etape "4/9  Socle MISP (galaxies, taxonomies, warninglists)"
make --no-print-directory socle-misp

etape "5/9  Pile OpenCTI + socle ATT&CK"
make --no-print-directory opencti-up
attendre "API OpenCTI" 1800 bash -c \
  "curl -sk -o /dev/null -w '%{http_code}' $SONDE_OCTI/graphql | grep -qE '200|400|405'"
echo "  chargement de l'ATT&CK (sans concurrence) — cela prend plusieurs minutes"
$PY provisioning/attack_status.py --wait

if grep -qsE '^MISP_HOSTNAME=.+' opencti/.env; then
  echo "  façade HTTPS incluse (profil proxy) — $URL_MISP et $URL_OCTI"
fi

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
echo "  MISP    : $URL_MISP"
echo "  OpenCTI : $URL_OCTI"
# CISO-Assistant (GRC) est un produit SÉPARÉ, hors du périmètre de cette
# plateforme : aucune donnée échangée avec MISP/OpenCTI, un public souvent
# plus large (audit, direction), des exigences de rétention différentes.
# 'make build' ne la construit donc jamais — 'make ciso-up' la démarre
# volontairement, à part, quand on le décide.
if grep -qsE '^CISO_HOSTNAME=.+' ciso-assistant/.env 2>/dev/null; then
  echo "  CISO-Assistant (GRC) : façade prête, pas démarrée — make ciso-up (produit séparé)"
fi
echo "  Contrôle de bout en bout : make bridge-test"
