"""Flux CTI du catalogue — ingestion dans MISP et/ou OpenCTI, un flux à la fois.

Source de vérité du CHOIX des flux : `~/CTI-feeds/flux-CTI.md` (dépôt
`ruggdoll/CTI-feeds`, §1 « Par quoi commencer »). Ce script ne fait qu'exécuter
la plomberie que ce catalogue documente ; il ne décide pas quel flux activer.

**Chaque flux vise UNE SEULE plateforme, jamais les deux à la fois** :
  * `plateforme="misp"`   — le flux se charge dans MISP (Sync Actions > Feeds,
    ou un événement isolé importé tel quel). Il y RESTE : `connector-misp` ne
    reprend vers OpenCTI que les événements dont l'organisation créatrice est
    `MISP_ORG` (voir `opencti/.env`) — c'est le chemin de retour du pont
    OpenCTI -> MISP, pas un chemin d'ingestion de flux tiers. Un flux MISP de
    ce script n'atteint donc JAMAIS OpenCTI de lui-même. C'est délibéré :
    décision de l'utilisateur du 2026-09-26, après avoir mesuré le risque pour
    les fiches CTI-pedia (dérive de confiance sur des entités déjà nommées,
    collisions de type). Élargir `MISP_IMPORT_CREATOR_ORGS` est un choix
    séparé, plus risqué, qui ne se prend jamais flux par flux — voir
    `make bridge-setup` et le Makefile pour ce réglage, JAMAIS ce script.
  * `plateforme="opencti"` — le flux est nativement STIX 2.1 et se pousse
    directement dans OpenCTI (comme `opencti_socle.py` le fait pour VIGINUM),
    sans jamais passer par MISP.

**Avant/après, côté CTI-pedia.** Ce script ne le fait pas lui-même (dépôt
séparé, environnement séparé) : depuis `~/CTI-pedia`, avec son propre
`.venv/bin/python`, `provisioning/fiche_audit.py` avant et après chaque flux
donne le compte de référence. Un écart nouveau qui n'est ni REL CONF, ni
REL TEXTE, ni HORS SCHÉMA, ni SURNUMÉR. (les quatre classes déjà tolérées,
calibrées sur le seul connecteur MITRE) vient du flux qu'on vient d'ouvrir.

Usage :
    flux_ingestion.py --list                    état de chaque flux du registre
    flux_ingestion.py --flux circl               dry-run sur CE flux seulement
    flux_ingestion.py --flux circl --yes         l'exécute
    flux_ingestion.py --tout --yes               tous les flux du registre, dans l'ordre
"""
from __future__ import annotations

import json
import pathlib
import sys
import time
import urllib.parse
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _config import MISP_KEY, MISP_URL, MISP_VERIFY_SSL, OPENCTI_URL, opencti_client  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]
CACHE = ROOT / "dist" / "flux-cti"

STIX_STANDARD = {
    "attack-pattern", "campaign", "course-of-action", "grouping", "identity",
    "indicator", "infrastructure", "intrusion-set", "location", "malware",
    "malware-analysis", "note", "observed-data", "opinion", "report",
    "threat-actor", "tool", "vulnerability", "relationship", "sighting",
    "marking-definition", "bundle",
}

# ---------------------------------------------------------------------------
# Registre — un flux = une entrée. `cle` sert à --flux. Ordre = ordre
# recommandé par flux-CTI.md §1 (« en une ligne, pour un CSIRT qui démarre »),
# moins ce qui est déjà en place ou explicitement écarté (voir "note" ci-dessous).
# ---------------------------------------------------------------------------
REGISTRE = [
    {
        "cle": "attack",
        "nom": "MITRE ATT&CK",
        "plateforme": "note",
        "detail": "déjà en place — connector-mitre (make attack-status pour l'état).",
    },
    {
        "cle": "galaxy",
        "nom": "MISP Galaxy",
        "plateforme": "note",
        "detail": "aucune action séparée : arrive avec les tags galaxy des "
                  "événements MISP dès qu'un feed en pose. socle_misp.py "
                  "tient déjà les galaxies à jour.",
    },
    {
        "cle": "datasets-filigran",
        "nom": "Filigran — datasets (secteurs/pays/régions)",
        "plateforme": "note",
        "detail": "ÉCARTÉ PAR PRÉCÉDENT (docker-compose.yml, connector-opencti "
                  "retiré le 2026-09-08) : 32 610 messages sur une base neuve "
                  "et des rapports VIGINUM recréés sous notre paternité, sans "
                  "dédup. Si repris un jour : PAS via un connecteur qui "
                  "réimporte tout, un import de fichier ciblé (sectors.json/"
                  "geography.json/companies.json, §B.3 du catalogue) après "
                  "revue manuelle.",
    },
    {
        "cle": "circl",
        "nom": "CIRCL — feed OSINT",
        "plateforme": "misp",
        "misp_url_match": "circl.lu/doc/misp/feed-osint",
        "distribution_attendue": "3",
    },
    {
        "cle": "botvrij",
        "nom": "Botvrij.eu",
        "plateforme": "misp",
        "misp_url_match": "botvrij.eu/data/feed-osint",
        "distribution_attendue": "3",
    },
    {
        "cle": "cert-fr",
        "nom": "CERT-FR / ANSSI",
        "plateforme": "misp",
        "misp_url_match": "misp.cert.ssi.gouv.fr/feed-misp",
        "misp_ajout": {  # absent des feeds par défaut de MISP : à ajouter
            "name": "CERT-FR / ANSSI",
            "provider": "CERT-FR",
            "url": "https://misp.cert.ssi.gouv.fr/feed-misp/",
            "source_format": "misp",
            "distribution": "3",
        },
    },
    {
        "cle": "threatfox",
        "nom": "abuse.ch — ThreatFox",
        "plateforme": "misp",
        "misp_url_match": "threatfox.abuse.ch/downloads/misp",
        "misp_ajout": {"name": "ThreatFox", "provider": "abuse.ch",
                       "url": "https://threatfox.abuse.ch/downloads/misp/",
                       "source_format": "misp", "distribution": "3"},
        "fenetre_jours": 30,  # §1.3 : détection, se scope dans le temps
    },
    {
        "cle": "urlhaus",
        "nom": "abuse.ch — URLhaus",
        "plateforme": "misp",
        "misp_url_match": "urlhaus.abuse.ch/downloads/misp",
        "misp_ajout": {"name": "URLhaus", "provider": "abuse.ch",
                       "url": "https://urlhaus.abuse.ch/downloads/misp/",
                       "source_format": "misp", "distribution": "3"},
        "fenetre_jours": 30,
    },
    {
        "cle": "malwarebazaar",
        "nom": "abuse.ch — MalwareBazaar",
        "plateforme": "misp",
        "misp_url_match": "bazaar.abuse.ch/downloads/misp",
        "misp_ajout": {"name": "MalwareBazaar", "provider": "abuse.ch",
                       "url": "https://bazaar.abuse.ch/downloads/misp/",
                       "source_format": "misp", "distribution": "3"},
    },
    {
        "cle": "rosti",
        "nom": "Rösti (réemballage — fenêtre 90 jours recommandée)",
        "plateforme": "misp",
        "misp_url_match": "misp.rosti.dev",
        "misp_ajout": {
            "name": "Rösti",
            "provider": "Rösti (Johannes Bader)",
            "url": "https://misp.rosti.dev/",
            "source_format": "misp",
            "distribution": "3",
        },
        "fenetre_jours": 90,
    },
    {
        "cle": "capec",
        "nom": "MITRE CAPEC (référentiel, un seul bundle)",
        "plateforme": "opencti",
        "url": "https://raw.githubusercontent.com/mitre/cti/master/capec/2.1/stix-capec.json",
    },
    {
        "cle": "atlas",
        "nom": "MITRE ATLAS (référentiel IA, un seul bundle)",
        "plateforme": "opencti",
        "url": "https://raw.githubusercontent.com/mitre-atlas/atlas-navigator-data/main/dist/stix-atlas.json",
    },
    {
        "cle": "disarm",
        "nom": "DISARM Foundation (manipulation de l'information)",
        "plateforme": "opencti",
        "url": "https://raw.githubusercontent.com/DISARMFoundation/DISARMframeworks/main/generated_files/DISARM_STIX/DISARM.json",
    },
    # -- §1.2 « La connaissance » : ceux-ci portent des Report avec acteurs et
    # indicateurs — c'est le palier qui NOMME des acteurs/malwares déjà
    # curatés par CTI-pedia. Le contrôle avant/après fiche_audit.py est ici
    # le seul filet ; chacun s'exécute et s'audite SÉPARÉMENT, jamais en lot.
    {
        "cle": "cisa",
        "nom": "CISA — avis conjoints (bundle par avis, liste pinnée à étoffer)",
        "plateforme": "opencti",
        "urls": [
            "https://www.cisa.gov/sites/default/files/2026-07/AA26-204A.stix_.json",
            # AA25-141B (LummaC2) ÉCARTÉ le 2026-09-26, décision de l'utilisateur :
            # export mal structuré (LummaC2 en malware ET en threat-actor, AgentTesla
            # typé threat-actor, une entité malware littéralement nommée "n/a"),
            # confidence/created_by_ref non renseignés sur des entités déjà
            # curatées par CTI-pedia (Amadey, Agent Tesla, Lumma Stealer). Ne pas
            # rajouter sans une passe de nettoyage dédiée.
        ],
    },
    {
        "cle": "ncsc-uk",
        "nom": "NCSC-UK — Malware Analysis Reports (liste pinnée)",
        "plateforme": "opencti",
        "urls": [
            "https://www.ncsc.gov.uk/sites/default/files/documents/NCSC-MAR-Cyclops-Blink-STIX2.1.json",
            "https://www.ncsc.gov.uk/sites/default/files/documents/NCSC-Malware-Analysis-Report-Small-Sieve.json",
        ],
    },
    {
        "cle": "talos",
        "nom": "Cisco Talos — IOCs (un bundle par billet, arbre GitHub complet)",
        "plateforme": "opencti",
        "github_tree": {"repo": "Cisco-Talos/IOCs", "branch": "main",
                         "suffixe": ".json", "prefixe": None},
        # Constaté le 2026-09-26 : les 132 bundles valides portent 48 noms de
        # malware/threat-actor/intrusion-set/tool, dont ~19 collisionnent une
        # fiche CTI-pedia sous le même nom (LockBit existe même en Malware ET
        # Intrusion-Set) et ~18 la doublonnent sous un nom différent — Talos
        # colle l'identifiant MITRE au nom (`"Emotet - S0367"`) alors que la
        # fiche existante porte le nom nu (`"Emotet"`). Décision utilisateur :
        # ne garder que la matière que CTI-pedia ne couvre pas déjà.
        "filtre_entites_nommees": True,
    },
    {
        "cle": "afrintel",
        "nom": "AFRINTEL (incidents visant l'Afrique)",
        "plateforme": "opencti",
        "github_tree": {"repo": "Hatchepsoute/AFRINTEL", "branch": "main",
                         "suffixe": "_opencti.json", "prefixe": "stix/"},
    },
    {
        "cle": "fdc",
        "nom": "FDC Threat Intelligence (enquêtes indépendantes)",
        "plateforme": "opencti",
        "github_tree": {"repo": "freedatacenter/threat-intelligence", "branch": "main",
                         "suffixe": "iocs.stix2.json", "prefixe": "reports/"},
    },
    {
        "cle": "elastic",
        "nom": "Elastic Security Labs (un bundle par campagne)",
        "plateforme": "opencti",
        "github_tree": {"repo": "elastic/labs-releases", "branch": "main",
                         "suffixe": "stix-bundle.json", "prefixe": "indicators/"},
    },
    {
        "cle": "assoechap",
        "nom": "AssoEchap — stalkerware-indicators (bundle unique)",
        "plateforme": "opencti",
        "url": "https://raw.githubusercontent.com/AssoEchap/stalkerware-indicators/master/generated/stalkerware.stix2",
    },
]


# ---------------------------------------------------------------------------
# MISP — activer/ajouter un feed existant, puis déclencher une récupération
# ---------------------------------------------------------------------------
def _misp_headers():
    return {"Authorization": MISP_KEY, "Accept": "application/json",
            "Content-Type": "application/json"}


def _misp_get(chemin: str):
    import requests
    r = requests.get(f"{MISP_URL}{chemin}", headers=_misp_headers(),
                      verify=MISP_VERIFY_SSL, timeout=30)
    r.raise_for_status()
    return r.json()


def _misp_post(chemin: str, corps: dict | None = None):
    import requests
    r = requests.post(f"{MISP_URL}{chemin}", headers=_misp_headers(),
                       json=corps or {}, verify=MISP_VERIFY_SSL, timeout=30)
    r.raise_for_status()
    return r.json()


def misp_feed_existant(url_match: str) -> dict | None:
    for f in _misp_get("/feeds"):
        ff = f["Feed"]
        if url_match in ff.get("url", ""):
            return ff
    return None


def traite_misp(entree: dict, pousser: bool) -> None:
    nom = entree["nom"]
    feed = misp_feed_existant(entree["misp_url_match"])
    if not feed and entree.get("misp_ajout"):
        if not pousser:
            print(f"   à AJOUTER (absent des feeds par défaut) puis activer et récupérer")
            return
        corps = {"Feed": entree["misp_ajout"]}
        r = _misp_post("/feeds/add", corps)
        feed = (r.get("Feed") or {})
        if not feed:
            print(f"   [!] échec de l'ajout : {r}")
            return
        print(f"   ajouté (id={feed.get('id')})")
    elif not feed:
        print(f"   [!] introuvable dans /feeds — pas d'ajout défini, à instruire")
        return

    fid = feed["id"]
    deja_active = feed.get("enabled") in (True, "1", 1)
    if not deja_active and not pousser:
        print(f"   id={fid} : à ACTIVER puis récupérer (dry-run)")
        return
    if not deja_active:
        _misp_post(f"/feeds/enable/{fid}")
        print(f"   id={fid} activé")
    else:
        print(f"   id={fid} déjà activé")

    fenetre = entree.get("fenetre_jours")
    if fenetre:
        print(f"   RAPPEL : ce flux se veut fenêtré à {fenetre} jours (§1.3/§1.2 du "
              f"catalogue) — MISP n'a pas de purge automatique par âge sur un feed, "
              f"un ménage périodique (Sync Actions > Feeds > events) reste à faire "
              f"à la main si le volume dérive.")

    if not pousser:
        print("   récupération : (dry-run, rien déclenché)")
        return
    r = _misp_post(f"/feeds/fetchFromFeed/{fid}")
    print(f"   récupération déclenchée : {r.get('result', r)}")


# ---------------------------------------------------------------------------
# OpenCTI — un seul bundle STIX pinné, comme opencti_socle.py pour VIGINUM
# ---------------------------------------------------------------------------
def telecharge(cle: str, url: str) -> pathlib.Path:
    """Constaté sur NCSC-UK (Cloudflare) et déjà documenté par flux-CTI.md pour
    Talos/TweetFeed : plusieurs sources renvoient une erreur (500, 403) au
    User-Agent par défaut de `urllib`, mais répondent normalement à un agent
    de navigateur — pas un blocage réel du contenu, juste de la bibliothèque."""
    CACHE.mkdir(parents=True, exist_ok=True)
    cible = CACHE / f"{cle}.json"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=120) as r:
        cible.write_bytes(r.read())
    return cible


def inspecte(chemin: pathlib.Path) -> dict:
    b = json.loads(chemin.read_text(encoding="utf-8"))
    objs = b.get("objects") or []
    types: dict[str, int] = {}
    custom = set()
    for o in objs:
        t = o.get("type", "?")
        types[t] = types.get(t, 0) + 1
        if t not in STIX_STANDARD:
            custom.add(t)
    return {"objets": len(objs), "types": types, "custom": sorted(custom)}


def valide_stix(chemin: pathlib.Path) -> tuple[bool, list[str]]:
    try:
        from stix2validator import ValidationOptions, validate_file
    except ImportError:
        return True, ["stix2validator absent — validation ignorée"]
    try:
        res = validate_file(str(chemin), ValidationOptions(strict=False))
    except Exception as e:
        return True, [f"validation impossible : {str(e)[:80]}"]
    durs = []
    for obj in getattr(res, "object_results", []) or []:
        for err in getattr(obj, "errors", []) or []:
            if "cannot locate a schema for the object's type" not in str(err).lower():
                durs.append(str(err)[:110])
    return not durs, list(dict.fromkeys(durs))[:5]


def _nettoie_refs_nulles(chemin: pathlib.Path) -> tuple[pathlib.Path, int]:
    """Retire les `None` littéraux glissés dans une liste `*_refs`.

    Constaté sur un bundle CISA (AA26-204A) : le `Report` porte deux `None`
    en fin de son `object_refs` — un défaut de l'export source, pas du
    contenu. `pycti` plante dessus (`TypeError` dans `is_id_supported`,
    qui ne s'attend jamais à un élément nul). Même principe que
    `opencti_socle.ecarte_orphelines` pour VIGINUM/RRN : on écrit une copie
    filtrée à côté, le fichier téléchargé n'est jamais modifié.
    """
    b = json.loads(chemin.read_text(encoding="utf-8"))
    retires = 0
    for o in b.get("objects") or []:
        for k, v in list(o.items()):
            if k.endswith("_refs") and isinstance(v, list) and any(x is None for x in v):
                avant = len(v)
                o[k] = [x for x in v if x is not None]
                retires += avant - len(o[k])
    # Deuxième défaut constaté (même bundle AA26-204A) : une relation dont
    # source_ref/target_ref pointe vers un objet absent du bundle (une identité
    # externe non incluse) — MISSING_REFERENCE_ERROR côté OpenCTI, la relation
    # est perdue et le reste de l'import continue en bruitant un traceback par
    # occurrence. Même geste que `opencti_socle.ecarte_orphelines` pour VIGINUM.
    ids = {o.get("id") for o in b.get("objects") or []}
    objets = b.get("objects") or []
    gardes = [o for o in objets
              if o.get("type") != "relationship"
              or (o.get("source_ref") in ids and o.get("target_ref") in ids)]
    ecartees = len(objets) - len(gardes)
    if ecartees:
        b["objects"] = gardes
        retires += ecartees
    if not retires:
        return chemin, 0
    cible = chemin.with_suffix(".nettoye.json")
    cible.write_text(json.dumps(b), encoding="utf-8")
    return cible, retires


ENTITES_CTI_PEDIA = {"malware", "threat-actor", "intrusion-set", "tool"}


def _filtre_entites_nommees(chemin: pathlib.Path) -> tuple[pathlib.Path, int]:
    """Retire les objets malware/threat-actor/intrusion-set/tool (et toute
    relation ou référence qui les touche) d'un bundle avant import.

    Ces quatre types sont la matière que CTI-pedia curate fiche par fiche
    (alias sourcés, confiance, relations vérifiées). Un flux externe qui
    réexporte les mêmes noms — parfois identiques, parfois avec l'identifiant
    MITRE collé au nom (Talos : `"Emotet - S0367"` au lieu de `"Emotet"`) —
    crée soit un doublon soit un écrasement de la fiche existante. On ne
    garde que ce que CTI-pedia ne couvre pas : indicateurs, rapports,
    techniques et les relations entre eux.
    """
    b = json.loads(chemin.read_text(encoding="utf-8"))
    objets = b.get("objects") or []
    ecartes = {o.get("id") for o in objets if o.get("type") in ENTITES_CTI_PEDIA}
    if not ecartes:
        return chemin, 0
    gardes = []
    for o in objets:
        if o.get("id") in ecartes:
            continue
        if o.get("type") == "relationship" and (
            o.get("source_ref") in ecartes or o.get("target_ref") in ecartes
        ):
            continue
        for k, v in list(o.items()):
            if k.endswith("_refs") and isinstance(v, list):
                o[k] = [x for x in v if x not in ecartes]
        gardes.append(o)
    retires = len(objets) - len(gardes)
    b["objects"] = gardes
    cible = chemin.with_suffix(".filtre.json")
    cible.write_text(json.dumps(b), encoding="utf-8")
    return cible, retires


def _un_bundle(cle_fichier: str, url: str, pousser: bool, c=None, filtre_entites: bool = False) -> bool:
    """Télécharge, inspecte, valide et (si `pousser`) importe UN bundle.

    Rend True si poussé (ou validé en dry-run), False sur échec — pour que
    l'appelant sache s'il faut avancer le manifeste d'un flux multi-fichiers.
    """
    try:
        chemin = telecharge(cle_fichier, url)
    except Exception as e:
        print(f"   [!] {cle_fichier} : téléchargement impossible : {str(e)[:80]}")
        return False
    # Constaté sur Cisco Talos/IOCs : les fichiers de 2022 sont en STIX 1.1.1
    # (`observables`/`stix_header`, pas de clé `objects`) tandis que les
    # récents sont en bundle STIX 2.0/2.1 — même dépôt, deux formats selon la
    # date. pycti ne lit que le second. On ignore proprement le premier
    # plutôt que de planter sur un import invalide.
    try:
        brut = json.loads(chemin.read_text(encoding="utf-8"))
    except Exception:
        brut = {}
    if brut.get("type") != "bundle":
        print(f"   {cle_fichier} — pas un bundle STIX 2.x (format hérité) — ignoré")
        return True
    info = inspecte(chemin)
    ok, msgs = valide_stix(chemin)
    print(f"   {cle_fichier} — {info['objets']} objets"
          f" ({', '.join(f'{t}×{n}' for t, n in sorted(info['types'].items(), key=lambda x: -x[1])[:5])})")
    if info["custom"]:
        print(f"      extensions hors STIX 2.1 strict : {', '.join(info['custom'])}")
    for m in msgs:
        print(f"      stix2validator : {m}")
    if not ok:
        print("      [!] bundle invalide — non poussé")
        return False
    if not pousser:
        print("      → dry-run : validé, rien poussé")
        return True
    chemin_final, retires = _nettoie_refs_nulles(chemin)
    if retires:
        print(f"      {retires} référence(s) nulle(s) retirée(s) d'une liste *_refs "
              f"(défaut de l'export source) — copie filtrée poussée, fichier "
              f"téléchargé inchangé")
    if filtre_entites:
        chemin_final, retires2 = _filtre_entites_nommees(chemin_final)
        if retires2:
            print(f"      {retires2} objet(s) malware/threat-actor/intrusion-set/tool "
                  f"(et relations liées) retiré(s) — matière déjà curatée par "
                  f"CTI-pedia, non réimportée depuis ce flux")
    (c or opencti_client()).stix2.import_bundle_from_file(str(chemin_final), update=True)
    print("      poussé dans OpenCTI")
    return True


def _github_tree_fichiers(repo: str, branch: str, prefixe: str | None, suffixe: str) -> list[str]:
    """Liste récursive d'un dépôt public GitHub (API tree), sans jeton —
    la limite non authentifiée (60 req/h) suffit pour un tirage ponctuel."""
    url = f"https://api.github.com/repos/{repo}/git/trees/{branch}?recursive=1"
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json",
                                                "User-Agent": "cti-platform-flux-ingestion"})
    with urllib.request.urlopen(req, timeout=60) as r:
        data = json.loads(r.read())
    chemins = [e["path"] for e in data.get("tree", []) if e.get("type") == "blob"]
    return [p for p in chemins
            if p.endswith(suffixe) and (prefixe is None or p.startswith(prefixe))]


def _manifeste(cle: str) -> set[str]:
    p = CACHE / f"{cle}.manifeste.json"
    if p.exists():
        return set(json.loads(p.read_text(encoding="utf-8")))
    return set()


def _manifeste_ajoute(cle: str, chemin: str) -> None:
    p = CACHE / f"{cle}.manifeste.json"
    dejafait = _manifeste(cle)
    dejafait.add(chemin)
    p.write_text(json.dumps(sorted(dejafait)), encoding="utf-8")


def traite_opencti(entree: dict, pousser: bool) -> None:
    c = opencti_client() if pousser else None
    filtre = entree.get("filtre_entites_nommees", False)

    if entree.get("url"):
        _un_bundle(entree["cle"], entree["url"], pousser, c, filtre_entites=filtre)
        return

    if entree.get("urls"):
        for i, url in enumerate(entree["urls"]):
            _un_bundle(f"{entree['cle']}-{i}", url, pousser, c, filtre_entites=filtre)
        return

    gt = entree.get("github_tree")
    if gt:
        try:
            fichiers = _github_tree_fichiers(gt["repo"], gt["branch"], gt.get("prefixe"), gt["suffixe"])
        except Exception as e:
            print(f"   [!] listage GitHub impossible : {str(e)[:100]}")
            return
        dejafait = _manifeste(entree["cle"])
        restants = [f for f in fichiers if f not in dejafait]
        print(f"   {len(fichiers)} fichier(s) dans le dépôt, {len(restants)} pas encore traité(s)"
              f" (déjà fait : {len(dejafait)})")
        for chemin_repo in restants:
            chemin_repo_encode = "/".join(urllib.parse.quote(seg) for seg in chemin_repo.split("/"))
            url = (f"https://raw.githubusercontent.com/{gt['repo']}/{gt['branch']}/{chemin_repo_encode}")
            ok = _un_bundle(chemin_repo.replace("/", "_"), url, pousser, c, filtre_entites=filtre)
            if ok and pousser:
                _manifeste_ajoute(entree["cle"], chemin_repo)
        return

    print("   [!] entrée sans url/urls/github_tree — rien à faire")


# ---------------------------------------------------------------------------
def affiche_etat():
    print(f"MISP   : {MISP_URL}")
    print(f"OpenCTI: {OPENCTI_URL}\n")
    for e in REGISTRE:
        print(f"[{e['cle']:16}] {e['nom']}  ({e['plateforme']})")
        if e["plateforme"] == "note":
            print(f"   {e['detail']}")
        elif e["plateforme"] == "misp":
            f = misp_feed_existant(e["misp_url_match"])
            if f:
                print(f"   id={f['id']} enabled={f['enabled']} distribution={f['distribution']}")
            else:
                print("   absent de MISP" + (" (ajout défini)" if e.get("misp_ajout") else " (PAS d'ajout défini)"))
        elif e["plateforme"] == "opencti":
            if e.get("url"):
                print(f"   {e['url']}")
            elif e.get("urls"):
                print(f"   {len(e['urls'])} URL(s) pinnée(s)")
            elif e.get("github_tree"):
                gt = e["github_tree"]
                dejafait = _manifeste(e["cle"])
                print(f"   arbre github.com/{gt['repo']} — {len(dejafait)} fichier(s) déjà traité(s)")


def main():
    args = sys.argv[1:]
    pousser = "--yes" in args
    if "--list" in args:
        affiche_etat()
        return
    if "--flux" in args:
        cle = args[args.index("--flux") + 1]
        cibles = [e for e in REGISTRE if e["cle"] == cle]
        if not cibles:
            raise SystemExit(f"flux inconnu : {cle} (voir --list)")
    elif "--tout" in args:
        cibles = REGISTRE
    else:
        print(__doc__)
        return

    print(f"{'(dry-run — rien ne sera modifié sans --yes)' if not pousser else '(exécution)'}\n")
    for e in cibles:
        print(f"=== {e['nom']} [{e['plateforme']}]")
        if e["plateforme"] == "note":
            print(f"   {e['detail']}")
        elif e["plateforme"] == "misp":
            traite_misp(e, pousser)
        elif e["plateforme"] == "opencti":
            traite_opencti(e, pousser)
        print()


if __name__ == "__main__":
    main()
