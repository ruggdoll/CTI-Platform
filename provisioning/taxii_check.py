"""Test de la collection TAXII 2.1 « abonnés » d'OpenCTI depuis un client TAXII
standard (taxii2-client), comme le ferait un client qui la branche chez lui.

Vérifie : découverte du serveur, présence de la collection, pagination
complète (ou bornée par --max-pages), validité STIX 2.1 de chaque objet
(bibliothèque stix2, propriétés custom OpenCTI tolérées), et intégrité des
références : tout `object_refs` d'un Report, tout `source_ref`/`target_ref`
d'une relation doit pointer vers un objet servi par la collection.

Usage : taxii_check.py [--url <base OpenCTI>] [--collection ID]  (défaut : opencti/.env)
                       [--max-pages N] [--added-after ISO8601]
Sortie : synthèse par type + code retour 1 si une référence est cassée ou un
objet invalide.
"""
import os
import pathlib
import sys
import time
from collections import Counter

import requests
import stix2
from taxii2client.v21 import Collection, Server

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _config import OPENCTI_URL  # adressage : voir provisioning/_config.py


class BearerAuth(requests.auth.AuthBase):
    def __init__(self, tok):
        self.tok = tok

    def __call__(self, r):
        r.headers["Authorization"] = f"Bearer {self.tok}"
        return r


def token():
    tok = os.environ.get("OPENCTI_ADMIN_TOKEN")
    if tok:
        return tok
    env = pathlib.Path(__file__).resolve().parent.parent / "opencti" / ".env"
    for line in env.read_text().splitlines():
        if line.startswith("OPENCTI_ADMIN_TOKEN="):
            return line.split("=", 1)[1].strip()
    sys.exit("OPENCTI_ADMIN_TOKEN introuvable")


def main():
    args = sys.argv[1:]

    def opt(name, default=None):
        return args[args.index(name) + 1] if name in args else default

    base = opt("--url", OPENCTI_URL)
    tok = token()
    auth = {"auth": BearerAuth(tok)}
    server = Server(f"{base}/taxii2/", **auth)
    print("serveur :", server.title, "| API roots :", [r.url for r in server.api_roots])
    root = server.api_roots[0]
    cols = root.collections
    print("collections :", [(c.id, c.title) for c in cols])
    cid = opt("--collection") or cols[0].id
    col = Collection(f"{root.url}collections/{cid}/", **auth)
    print("collection :", col.title, "| can_read :", col.can_read, "| media :", col.media_types)

    max_pages = int(opt("--max-pages", "0"))
    added_after = opt("--added-after")
    limit = 500
    ids, types, invalid = set(), Counter(), []
    reports, rels = [], []
    nxt, page, t0 = None, 0, time.time()
    while True:
        kw = {"limit": limit}
        if nxt:
            kw["next"] = nxt
        if added_after:
            kw["added_after"] = added_after
        env = col.get_objects(**kw)
        page += 1
        objs = env.get("objects", [])
        for o in objs:
            ids.add(o["id"])
            types[o["type"]] += 1
            try:
                stix2.parse(o, allow_custom=True, version="2.1")
            except Exception as e:  # noqa: BLE001
                invalid.append((o["id"], str(e)[:100]))
            if o["type"] == "report":
                reports.append(o)
            elif o["type"] == "relationship":
                rels.append(o)
        print(f"  page {page}: {len(objs)} objets, total {len(ids)} ({time.time() - t0:.0f}s) more={env.get('more')}",
              flush=True)
        nxt = env.get("next")
        if not env.get("more") or not nxt or (max_pages and page >= max_pages):
            break

    complete = not env.get("more")
    state = "COMPLÈTE" if complete else "PARTIELLE (--max-pages)"
    print(f"\n{len(ids)} objets uniques, {page} pages, collecte {state}")
    for t, n in types.most_common():
        print(f"  {t:28s} {n}")
    print(f"objets STIX invalides : {len(invalid)}")
    for i, e in invalid[:10]:
        print("   ", i, e)
    rc = 1 if invalid else 0
    if complete:
        missing_refs = Counter()
        for r in reports:
            for ref in r.get("object_refs", []):
                if ref not in ids:
                    missing_refs[ref.split("--")[0]] += 1
        broken_rels = sum(1 for r in rels if r["source_ref"] not in ids or r["target_ref"] not in ids)
        print(f"object_refs de Report non servis : {sum(missing_refs.values())} {dict(missing_refs)}")
        print(f"relations à extrémité non servie : {broken_rels}/{len(rels)}")
        rc |= bool(missing_refs) or bool(broken_rels)
    sys.exit(rc)


if __name__ == "__main__":
    main()
