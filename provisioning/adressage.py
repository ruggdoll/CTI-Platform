#!/usr/bin/env python3
"""Émet l'adressage que doit connaître un outil d'alimentation, depuis la plateforme.

    make adressage                          aperçu, secrets masqués
    make adressage ARGS=--secrets           fragment .env réel, redirigeable
    make adressage ARGS=--secrets > /chemin/vers/outil/.env

La documentation disait jusqu'ici à un outil d'alimentation d'aller lire
`opencti/.env` et `vendor/misp-docker/.env`. Cela suppose qu'il soit sur le
MÊME système de fichiers que la plateforme — vrai sur un poste de travail, faux
dès qu'elle tourne sur une autre machine, ce qui est le cas visé. Chacun
bricolait alors son extraction par ssh et grep, avec le risque d'oublier une
valeur ou d'en recopier une périmée.

La plateforme est la source de vérité de son propre adressage : elle l'émet.

Les secrets ne sortent qu'avec `--secrets`, pour que les exposer soit un geste
délibéré et non le résultat d'une commande tapée par curiosité.
"""
from __future__ import annotations

import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _config import (  # noqa: E402
    MISP_KEY,
    MISP_ORG,
    MISP_URL,
    OPENCTI_TOKEN,
    OPENCTI_URL,
    ROOT,
)

CERT = ROOT / "vendor" / "misp-docker" / "ssl" / "cert.pem"


def masque(v: str) -> str:
    return f"{v[:4]}…{v[-4:]} ({len(v)} car.)" if v else "ABSENT"


def cert_au_nom_de_l_hote() -> tuple[bool, str]:
    """Le certificat MISP porte-t-il autre chose que le CN=localhost livré ?

    Détermine si un consommateur peut vérifier le TLS. Poser MISP_VERIFY_SSL=1
    alors que le certificat auto-signé d'origine est en place ferait échouer
    tous ses appels ; poser 0 alors qu'un vrai certificat existe affaiblit la
    liaison sans raison. On regarde plutôt que de deviner.
    """
    if not CERT.exists():
        return False, "aucun certificat dans vendor/misp-docker/ssl/"
    try:
        sujet = subprocess.run(
            ["openssl", "x509", "-noout", "-subject", "-in", str(CERT)],
            capture_output=True, text=True, timeout=10,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return False, "openssl indisponible : impossible de lire le certificat"
    if "CN = localhost" in sujet or "CN=localhost" in sujet:
        return False, "certificat auto-signé CN=localhost (celui livré par la pile)"
    return True, f"certificat propre à l'hôte ({sujet.removeprefix('subject=').strip()})"


def main() -> None:
    args = sys.argv[1:]
    secrets = "--secrets" in args

    verifiable, motif = cert_au_nom_de_l_hote()
    tls = "1" if verifiable else "0"

    if "localhost" in OPENCTI_URL or "localhost" in MISP_URL:
        print("/!\\ Cette plateforme est déclarée sur « localhost » : l'adressage émis ne",
              file=sys.stderr)
        print("    servira à aucun outil situé sur une AUTRE machine. Reconstruire les",
              file=sys.stderr)
        print("    .env avec « make init HOST=<fqdn|ip> » si elle doit être jointe de loin.",
              file=sys.stderr)
        print(file=sys.stderr)

    if not secrets:
        print("# Aperçu — secrets masqués. Pour le fragment réel, redirigeable :")
        print("#     make adressage ARGS=--secrets > /chemin/vers/outil/.env")
        print()

    print(f"MISP_URL={MISP_URL}")
    print(f"MISP_KEY={MISP_KEY if secrets else masque(MISP_KEY)}")
    # Le commentaire va sur SA ligne : les lecteurs de .env des outils font un
    # simple partition("=") et prendraient un commentaire de fin de ligne pour
    # une partie de la valeur — ici, MISP_VERIFY_SSL deviendrait non vide, donc
    # vrai, et toute la liaison MISP échouerait sur le certificat auto-signé.
    print(f"# {motif}")
    print(f"MISP_VERIFY_SSL={tls}")
    print(f"MISP_ORG={MISP_ORG}")
    print()
    print(f"OPENCTI_URL={OPENCTI_URL}")
    print(f"OPENCTI_TOKEN={OPENCTI_TOKEN if secrets else masque(OPENCTI_TOKEN)}")

    if secrets:
        print("Ces valeurs ouvrent un accès complet aux deux plateformes.",
              file=sys.stderr)
        print("La clé MISP émise est celle de l'ADMIN : une rotation par "
              "« make misp-setup » cassera", file=sys.stderr)
        print("tout traitement qui s'en sert. Préférer une clé d'automation "
              "dédiée (Administration >", file=sys.stderr)
        print("Auth Keys > Add) pour ce qui tourne sans surveillance.",
              file=sys.stderr)


if __name__ == "__main__":
    main()
