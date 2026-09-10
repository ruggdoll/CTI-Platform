"""Socle de connaissance MISP — à poser à la construction de la plateforme.

Avant tout flux, MISP doit disposer de ses référentiels : sans eux, les tags ne
sont pas validés, les acteurs ne sont pas reconnus et rien ne filtre les faux
positifs. Sur une instance neuve, MISP livre les fichiers mais laisse **tout
désactivé** — constaté le 2026-09-08 : 143 warninglists et 182 taxonomies
présentes, 0 activée.

Ce que pose ce script (idempotent) :
  * galaxies       — acteurs, malwares, outils, ATT&CK ; c'est la table
                     canonique des alias, la plus rentable du pipeline ;
  * taxonomies     — celles qu'utilisent les importateurs (tlp, PAP,
                     admiralty-scale, osint, misp), activées ;
  * warninglists   — filtre anti-faux-positifs (DNS publics, CDN, RFC1918…),
                     toutes activées ;
  * modèles d'objets et noticelists — mis à jour.

Usage : misp_socle.py [--dry-run]
"""
import pathlib
import sys

import urllib3

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _config import MISP_KEY, MISP_URL, MISP_VERIFY_SSL

urllib3.disable_warnings()

# Taxonomies effectivement utilisées par les outils d'alimentation et le
# pipeline rapports. En activer 182 chargerait des milliers de tags inutiles.
TAXONOMIES = ["tlp", "PAP", "admiralty-scale", "osint", "misp", "estimative-language"]


def main():
    dry = "--dry-run" in sys.argv[1:]
    if not MISP_KEY:
        raise SystemExit("clé MISP introuvable : lancer 'make init HOST=<fqdn|ip>'")
    from pymisp import PyMISP

    m = PyMISP(MISP_URL, MISP_KEY, ssl=MISP_VERIFY_SSL, tool="cti-platform-socle")
    print(f"MISP : {MISP_URL}{'  (dry-run)' if dry else ''}\n")

    print("1. mise à jour des référentiels")
    for libelle, appel in (("galaxies", m.update_galaxies),
                           ("taxonomies", m.update_taxonomies),
                           ("warninglists", m.update_warninglists),
                           ("modèles d'objets", m.update_object_templates),
                           ("noticelists", m.update_noticelists)):
        if dry:
            print(f"   {libelle} : à mettre à jour")
            continue
        try:
            r = appel()
            msg = r.get("message") or r.get("name") or "ok" if isinstance(r, dict) else "ok"
        except Exception as e:  # une mise à jour qui échoue ne doit pas tout bloquer
            msg = f"échec : {e}"
        print(f"   {libelle} : {msg}")

    print("\n2. taxonomies utilisées par la plateforme")
    index = {t["Taxonomy"]["namespace"]: t["Taxonomy"] for t in m.taxonomies(pythonify=False)}
    for ns in TAXONOMIES:
        t = index.get(ns)
        if not t:
            print(f"   {ns:20} absente de cette instance")
            continue
        if t["enabled"]:
            print(f"   {ns:20} déjà activée")
        elif dry:
            print(f"   {ns:20} à activer")
        else:
            m.enable_taxonomy(t["id"])
            m.enable_taxonomy_tags(t["id"])
            print(f"   {ns:20} activée (+ ses tags)")

    print("\n3. warninglists (filtre anti-faux-positifs)")
    wl = m.warninglists(pythonify=False)
    wl = wl.get("Warninglists", wl) if isinstance(wl, dict) else wl
    off = [w["Warninglist"] for w in wl if not w["Warninglist"]["enabled"]]
    if not off:
        print(f"   {len(wl)} warninglists, toutes activées")
    elif dry:
        print(f"   {len(off)} warninglists à activer (sur {len(wl)})")
    else:
        r = m.toggle_warninglist(warninglist_name="%", force_enable=True)
        print(f"   {r.get('success', r)}")

    print("\n4. galaxies")
    g = m.galaxies(pythonify=False)
    print(f"   {len(g)} galaxies disponibles")
    print("\n→ socle en place." if not dry else "\n→ dry-run : rien n'a été modifié.")


if __name__ == "__main__":
    main()
