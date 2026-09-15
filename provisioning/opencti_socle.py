"""Socle de connaissance OpenCTI — à poser à la construction, après l'ATT&CK.

Deux couches, dans cet ordre :

  1. **MITRE ATT&CK** (connector-mitre, démarré par `make opencti-up`) : le
     référentiel sur lequel se raccrochent tous les rapports par `external_id`
     T1xxx. `make attack-status` dit où il en est ; on n'enchaîne pas tant
     qu'il n'est pas complet.
  2. **Rapports STIX publics de VIGINUM** (ce script) : annexes techniques
     officielles publiées par le SGDSN sur github.com/VIGINUM-FR/Rapports-
     Techniques, en STIX 2.1 natif, TLP:CLEAR. Source gouvernementale
     (`confidence` 90) et française — donc pas de plancher d'ancienneté.

Ces bundles remplacent le rapport de contrôle synthétique : ils valident la
même chaîne (OpenCTI -> live stream -> connector-misp-intel -> MISP) avec de la
donnée réelle qu'on veut de toute façon en base, et ils exercent en prime le
workflow « importer un bundle tiers » (valider, inspecter, importer).

À savoir : ces bundles utilisent des types **propres à OpenCTI**
(`media-content`, `channel`, `narrative`, `text`). C'est du STIX étendu, pas du
STIX invalide : une validation en mode strict les rejette. On valide donc la
structure du bundle et les objets STIX standards, en tolérant les types
personnalisés.

Usage : opencti_socle.py [--yes] [--list] [--pin SHA]
  sans --yes : télécharge, valide, inspecte et s'arrête (dry-run).
"""
import json
import pathlib
import sys
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _config import OPENCTI_URL, opencti_client

ROOT = pathlib.Path(__file__).resolve().parents[1]
CACHE = ROOT / "dist" / "socle-viginum"

# Épinglé par SHA : le contenu amont ne doit pas faire varier le socle ni le
# contrôle de bout en bout. Relever le SHA volontairement, pas au fil de l'eau.
PIN = "933c7332db292fe7a1f73a13058b19e1210b0b1a"
RAW = "https://raw.githubusercontent.com/VIGINUM-FR/Rapports-Techniques"

BUNDLES = [
    ("202306 - RRN",
     "20230822_VIGINUM_TLP_CLEAR_RRN A complex and persistent information manipulation campaign_full.json"),
    ("202402 - Portal Kombat",
     "20240212_VIGINUM_TLP CLEAR_Portal Kombat A structured and coordinated "
     "pro-Russian propaganda network_full.json"),
    ("202406 - Matriochka",
     "20240610_VIGINUM_TLP CLEAR_Matriochka A Pro-Russian Digital Information "
     "Campaign Targeting Media and Fact-Checkers_full.json"),
    ("202412 - BIG",
     "20241202_VIGINUM_TLP_CLEAR_Un-notorious big_ an information manipulation "
     "campaign targeting french overseas terroritories and corsica_full.json"),
]

# Types STIX 2.1 standards ; tout le reste est une extension OpenCTI, tolérée
# mais comptée à part pour que ce soit visible.
STIX_STANDARD = {
    "attack-pattern", "campaign", "course-of-action", "grouping", "identity",
    "indicator", "infrastructure", "intrusion-set", "location", "malware",
    "malware-analysis", "note", "observed-data", "opinion", "report",
    "threat-actor", "tool", "vulnerability", "relationship", "sighting",
    "marking-definition", "bundle", "domain-name", "ipv4-addr", "ipv6-addr",
    "url", "file", "email-addr", "email-message", "user-account", "artifact",
    "autonomous-system", "directory", "mutex", "network-traffic", "process",
    "software", "windows-registry-key", "x509-certificate",
}


def telecharge(dossier: str, fichier: str) -> pathlib.Path:
    CACHE.mkdir(parents=True, exist_ok=True)
    cible = CACHE / f"{dossier.split(' - ')[-1].lower().replace(' ', '-')}.json"
    if cible.exists():
        return cible
    url = f"{RAW}/{PIN}/{urllib.parse.quote(dossier)}/{urllib.parse.quote(fichier)}"
    with urllib.request.urlopen(url, timeout=120) as r:
        cible.write_bytes(r.read())
    return cible


# Messages du validateur qui ne signalent PAS un bundle invalide : ils disent
# seulement que le type n'est pas au catalogue STIX 2.1 standard. Les bundles
# OpenCTI portent légitimement media-content, channel, narrative, text, event.
_TOLERE = ("cannot locate a schema for the object's type",)


def valide_stix(chemin: pathlib.Path) -> tuple[bool, list[str]]:
    """Validation STIX 2.1 par `stix2validator`, en tolérant les extensions OpenCTI.

    Renvoie (valide, messages). `valide` est False uniquement sur une vraie
    faute de structure : un type inconnu du schéma standard n'en est pas une.
    """
    try:
        from stix2validator import ValidationOptions, validate_file
    except ImportError:
        return True, ["stix2validator absent — validation ignorée (pip install stix2-validator)"]
    try:
        res = validate_file(str(chemin), ValidationOptions(strict=False))
    except Exception as e:  # un validateur qui plante ne doit pas bloquer le socle
        return True, [f"validation impossible : {str(e)[:80]}"]
    durs, tolerés = [], 0
    for obj in getattr(res, "object_results", []) or []:
        for err in getattr(obj, "errors", []) or []:
            if any(t in str(err).lower() for t in _TOLERE):
                tolerés += 1
            else:
                durs.append(str(err)[:110])
    msgs = list(dict.fromkeys(durs))[:5]
    if tolerés:
        msgs.append(f"{tolerés} type(s) hors schéma standard — extensions OpenCTI, toléré")
    return not durs, msgs


def inspecte(chemin: pathlib.Path) -> dict:
    """Contrôles de structure exigés avant tout import d'un bundle tiers."""
    b = json.loads(chemin.read_text(encoding="utf-8"))
    pb = []
    if b.get("type") != "bundle":
        pb.append("l'objet racine n'est pas un bundle")
    objs = b.get("objects") or []
    if not objs:
        pb.append("bundle vide")
    types, sans_id, custom = {}, 0, set()
    for o in objs:
        t = o.get("type", "?")
        types[t] = types.get(t, 0) + 1
        if not o.get("id"):
            sans_id += 1
        if t not in STIX_STANDARD:
            custom.add(t)
    if sans_id:
        pb.append(f"{sans_id} objet(s) sans id")
    ids = {o.get("id") for o in objs}
    orphelines = sum(1 for o in objs if o.get("type") == "relationship"
                     and (o.get("source_ref") not in ids or o.get("target_ref") not in ids))
    reports = [o for o in objs if o.get("type") == "report"]
    return {"objets": len(objs), "types": types, "custom": sorted(custom),
            "relations_orphelines": orphelines, "problemes": pb,
            "reports": [(r.get("name", "?"), r.get("published", "?")) for r in reports],
            "marquages": sorted({m for o in objs for m in (o.get("object_marking_refs") or [])})}


def ecarte_orphelines(chemin: pathlib.Path) -> tuple[pathlib.Path, int]:
    """Écarte les relations dont une extrémité est absente du bundle.

    Au SHA épinglé, le bundle RRN de VIGINUM porte une relation qui pointe vers
    un indicateur absent du bundle. OpenCTI la refuse — MISSING_REFERENCE_ERROR
    — et pycti journalise un traceback complet au milieu du build, pour un
    objet qui de toute façon ne peut PAS exister dans le graphe : sa cible
    n'est nulle part. Un opérateur qui lit le journal ne peut pas distinguer
    cette trace d'un incident réel.

    On les retire donc avant l'import, et on dit combien. Le fichier source
    téléchargé n'est pas modifié : la copie filtrée est écrite à côté, ce qui
    garde vérifiable ce que la source publie réellement.
    """
    b = json.loads(chemin.read_text(encoding="utf-8"))
    objs = b.get("objects") or []
    ids = {o.get("id") for o in objs}
    gardes = [o for o in objs
              if o.get("type") != "relationship"
              or (o.get("source_ref") in ids and o.get("target_ref") in ids)]
    ecartees = len(objs) - len(gardes)
    if not ecartees:
        return chemin, 0
    b["objects"] = gardes
    cible = chemin.with_suffix(".importable.json")
    cible.write_text(json.dumps(b), encoding="utf-8")
    return cible, ecartees


def main():
    args = sys.argv[1:]
    if "--pin" in args:
        globals()["PIN"] = args[args.index("--pin") + 1]
    pousser = "--yes" in args
    print(f"OpenCTI : {OPENCTI_URL}")
    print(f"VIGINUM Rapports-Techniques, épinglé sur {PIN[:12]}\n")

    fichiers, ko = [], False
    for dossier, fichier in BUNDLES:
        try:
            chemin = telecharge(dossier, fichier)
        except Exception as e:
            print(f"  {dossier:26} téléchargement impossible : {str(e)[:70]}")
            ko = True
            continue
        info = inspecte(chemin)
        stix_ok, stix_msgs = valide_stix(chemin)
        if not stix_ok:
            info["problemes"].append("STIX invalide")
        etat = "OK" if not info["problemes"] else "; ".join(info["problemes"])
        print(f"  {dossier:26} {info['objets']:>4} objets  {etat}")
        for m in stix_msgs:
            print(f"      stix2validator : {m}")
        for nom, pub in info["reports"]:
            print(f"      Report « {nom[:56]} » publié {str(pub)[:10]}")
        gros = sorted(info["types"].items(), key=lambda x: -x[1])[:6]
        print(f"      types : {', '.join(f'{t}×{n}' for t, n in gros)}")
        if info["custom"]:
            print(f"      extensions OpenCTI (hors STIX 2.1 strict) : {', '.join(info['custom'])}")
        if info["relations_orphelines"]:
            print(f"      /!\\ {info['relations_orphelines']} relation(s) orpheline(s)")
        if info["problemes"]:
            ko = True
        fichiers.append(chemin)

    if ko:
        raise SystemExit("\nUn bundle au moins est inexploitable — rien n'est importé.")
    if not pousser:
        print(f"\n→ dry-run : {len(fichiers)} bundle(s) validés, rien n'est importé."
              " Relancer avec --yes pour pousser dans OpenCTI.")
        return

    c = opencti_client()
    print()
    for chemin in fichiers:
        source, ecartees = ecarte_orphelines(chemin)
        c.stix2.import_bundle_from_file(str(source), update=False)
        if ecartees:
            print(f"  poussé : {chemin.name}  "
                  f"({ecartees} relation(s) orpheline(s) écartée(s) — cible absente du bundle)")
        else:
            print(f"  poussé : {chemin.name}")

    # Le pont retour ne reprend que les Reports étiquetés export-misp. Poser ce
    # label n'altère pas le contenu de la source : c'est notre marqueur de
    # routage interne, pas une affirmation CTI.
    print("\n  étiquetage export-misp (routage vers MISP) :")
    for chemin in fichiers:
        b = json.loads(chemin.read_text(encoding="utf-8"))
        for o in b.get("objects") or []:
            if o.get("type") != "report":
                continue
            r = c.report.read(filters={"mode": "and", "filterGroups": [], "filters": [
                {"key": ["name"], "values": [o.get("name")]}]})
            if not r:
                print(f"    Report « {str(o.get('name'))[:50]} » pas encore visible "
                      "(worker en retard) — relancer plus tard")
                continue
            c.stix_domain_object.add_label(id=r["id"], label_name="export-misp")
            print(f"    {str(o.get('name'))[:60]}")
    print("\n→ socle VIGINUM importé et routé vers MISP.")


if __name__ == "__main__":
    import urllib.parse  # noqa: E402  (utilisé par telecharge)
    main()
