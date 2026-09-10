"""Aligne l'organisation MISP #1 sur MISP_ORG (source unique : opencti/.env).

Le pont MISP -> OpenCTI ne réimporte que les events de `MISP_IMPORT_CREATOR_ORGS`
et le pont retour crée les siens sous `MISP_OWNER_ORG` : les deux valent
`MISP_ORG`. Si l'organisation par défaut de MISP garde son nom d'installation,
les deux plateformes ne se voient pas. Ce script renomme l'org #1 en conservant
son UUID (donc sans casser les events déjà créés). Idempotent.

Usage : misp_org.py [--dry-run]
"""
import pathlib
import sys

import urllib3

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _config import MISP_KEY, MISP_ORG, MISP_URL

urllib3.disable_warnings()


def main():
    dry = "--dry-run" in sys.argv[1:]
    if not MISP_KEY or MISP_KEY == "CHANGEME":
        raise SystemExit("clé MISP absente : lancer 'make misp-setup' (MISP doit être démarré)")
    from pymisp import PyMISP

    m = PyMISP(MISP_URL, MISP_KEY, ssl=False, tool="cti-platform-org")
    org = m.get_organisation(1, pythonify=False)["Organisation"]
    print(f"MISP : {MISP_URL} — org #1 « {org['name']} » (uuid {org['uuid']})")
    if org["name"] == MISP_ORG:
        print(f"  déjà nommée {MISP_ORG} — rien à faire")
        return
    if dry:
        print(f"  à renommer en {MISP_ORG}")
        return
    r = m.update_organisation({"id": 1, "name": MISP_ORG}, pythonify=False)
    if "errors" in r:
        raise SystemExit(f"échec du renommage : {r['errors']}")
    print(f"  renommée en {MISP_ORG} (uuid inchangé)")


if __name__ == "__main__":
    main()
