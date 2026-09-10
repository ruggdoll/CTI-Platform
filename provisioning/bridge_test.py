"""Contrôle bout en bout du pont OpenCTI -> MISP (`make bridge-test`).

Crée un rapport de contrôle **dans OpenCTI** (défini par provisioning/selftest/
bridge_report.yaml, créé directement par l'API — identité technique, observable,
Report étiqueté export-misp, comme le ferait n'importe quel outil d'alimentation),
puis attend que
`connector-misp-intel` le republie dans MISP et cherche l'observable qu'il
porte côté MISP. Rien n'est injecté dans MISP par ce script : si l'observable
y apparaît, c'est que la chaîne complète fonctionne.

Le contrôle NE LAISSE RIEN DERRIÈRE LUI : les objets créés (Report, indicateur,
observable et identité technique côté OpenCTI, event côté MISP) sont supprimés à
la fin, y compris quand le contrôle échoue. Sans cela l'artefact reste en base,
compte pour un rapport dans les états et remonte en défaut de QA — c'est arrivé.

Usage : bridge_test.py [--timeout SECONDES] [--keep]
  --keep : conserve les objets de contrôle au lieu de les supprimer (débogage)
"""
import pathlib
import sys
import time

import urllib3
import yaml

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _config import MISP_KEY, MISP_URL, OPENCTI_URL, opencti_client

urllib3.disable_warnings()
ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = ROOT / "provisioning" / "selftest" / "bridge_report.yaml"


def purge(c, m, needle, title, author, event_uuid=None):
    """Supprime tout ce que le contrôle a pu créer. Idempotent et silencieux :
    appelé aussi sur les chemins d'échec, où une partie des objets n'existe pas."""
    def one(label, fn):
        try:
            fn()
            print(f"   nettoyage : {label}")
        except Exception:
            pass

    def f(key, value):
        return {"mode": "and", "filterGroups": [],
                "filters": [{"key": key, "values": [value]}]}

    if event_uuid:
        one("event MISP", lambda: m.delete_event(event_uuid))
    for rep in c.report.list(filters=f("name", title)) or []:
        one(f"Report OpenCTI {rep['id']}",
            lambda i=rep["id"]: c.stix_domain_object.delete(id=i))
    for ind in c.indicator.list(filters=f("name", needle)) or []:
        one(f"indicateur {needle}",
            lambda i=ind["id"]: c.stix_domain_object.delete(id=i))
    for obs in c.stix_cyber_observable.list(filters=f("value", needle)) or []:
        one(f"observable {needle}",
            lambda i=obs["id"]: c.stix_cyber_observable.delete(id=i))
    for ide in c.identity.list(filters=f("name", author)) or []:
        one(f"identité « {author} »",
            lambda i=ide["id"]: c.stix_domain_object.delete(id=i))


def run(c, needle, title, timeout, found):
    """Déroule le contrôle. `found` reçoit l'uuid de l'event MISP dès qu'il est
    connu, pour que le nettoyage puisse l'atteindre même si la suite échoue."""
    print("1. création du rapport DANS OpenCTI (API, comme n'importe quel outil d'alimentation)")
    spec = yaml.safe_load(SPEC.read_text(encoding="utf-8"))
    author = c.identity.create(type="Organization", name=spec["author"]["name"],
                               description=spec["author"]["description"].strip())
    obs = c.stix_cyber_observable.create(observableData={"type": "Domain-Name", "value": needle},
                                         createdBy=author["id"], update=True)
    rep = c.report.create(name=title, description=spec["report"]["description"].strip(),
                          published=spec["report"]["published"] + "T00:00:00Z",
                          report_types=["threat-report"], confidence=int(spec.get("confidence", 70)),
                          createdBy=author["id"], objectLabel=["export-misp"],
                          externalReferences=[], update=True)
    c.report.add_stix_object_or_stix_relationship(id=rep["id"], stixObjectOrStixRelationshipId=obs["id"])
    print(f"   Report {rep['id']} créé avec l'observable {needle}, label export-misp")

    deadline = time.time() + 120
    rep = None
    while time.time() < deadline:
        rep = c.report.read(filters={"mode": "and", "filterGroups": [], "filters": [
            {"key": "name", "values": [title]}]})
        if rep:
            break
        time.sleep(5)
    if not rep:
        raise SystemExit("le rapport n'est pas visible dans OpenCTI (worker d'import en retard ?)")
    labels = [lab["value"] for lab in rep.get("objectLabel") or []]
    print(f"   Report OpenCTI {rep['id']} — labels {labels}")
    if "export-misp" not in labels:
        raise SystemExit("le rapport ne porte pas le label export-misp : le pont l'ignorera")

    print("\n2. attente de la reprise par connector-misp-intel puis recherche DANS MISP")
    from pymisp import PyMISP
    m = PyMISP(MISP_URL, MISP_KEY, ssl=False, tool="cti-platform-bridge-test")
    deadline = time.time() + timeout
    t0 = time.time()
    while time.time() < deadline:
        hits = m.search(controller="attributes", value=needle, pythonify=False)
        attrs = (hits.get("Attribute") or []) if isinstance(hits, dict) else []
        if attrs:
            a = attrs[0]
            ev = m.get_event(a["event_id"], pythonify=False)["Event"]
            print(f"\n   OK — observable {needle} trouvé dans MISP après {time.time() - t0:.0f}s")
            print(f"   event MISP #{ev['id']} « {ev['info']} » — org {ev['Orgc']['name']}, "
                  f"distribution {ev['distribution']}, publié={ev['published']}")
            print(f"   attribut : {a['type']} = {a['value']}")
            print(f"   l'uuid de l'event MISP est celui du Report OpenCTI ({rep['id']}) :"
                  " il vient bien du pont, il n'a pas été créé côté MISP")
            found["event_uuid"] = ev["uuid"]
            print("\n=> chaîne OpenCTI -> live stream -> connector-misp-intel -> MISP : OK")
            return m
        time.sleep(15)
        print(f"   … {time.time() - t0:.0f}s", flush=True)
    raise SystemExit(
        f"\néchec : {needle} n'est pas arrivé dans MISP en {timeout}s.\n"
        "Pistes : 'make bridge-setup' lancé ? conteneur connector-misp-intel recréé "
        "depuis ('make opencti-up') ? logs : docker logs cti-platform-opencti-connector-misp-intel-1")


def main():
    args = sys.argv[1:]
    keep = "--keep" in args
    timeout = int(args[args.index("--timeout") + 1]) if "--timeout" in args else 900
    spec = yaml.safe_load(SPEC.read_text(encoding="utf-8"))
    needle = spec["observables"][0]["domain"][0]
    title = spec["report"]["name"]
    author = spec["author"]["name"]
    print(f"OpenCTI {OPENCTI_URL}  ->  MISP {MISP_URL}")
    print(f"rapport de contrôle : « {title} »  /  observable attendu : {needle}\n")

    c = opencti_client()
    found = {}
    m = None
    try:
        m = run(c, needle, title, timeout, found)
    finally:
        # Le nettoyage est le comportement par défaut, y compris après un échec :
        # un contrôle d'infrastructure ne doit rien laisser dans la base de
        # renseignement. `--keep` sert au débogage.
        if keep:
            print("\n--keep : objets de contrôle conservés dans OpenCTI et MISP")
        else:
            print("\nnettoyage des objets de contrôle")
            if m is None:
                from pymisp import PyMISP
                try:
                    m = PyMISP(MISP_URL, MISP_KEY, ssl=False,
                               tool="cti-platform-bridge-test")
                except Exception:
                    m = None
            purge(c, m, needle, title, author, found.get("event_uuid"))


if __name__ == "__main__":
    main()
