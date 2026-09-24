"""Câblage du pont OpenCTI -> MISP, en une commande (`make bridge-setup`).

Le connecteur `connector-misp-intel` ne republie dans MISP que ce que lui donne
un **live stream** OpenCTI. Ce stream était jusqu'ici créé à la main dans l'UI
et son id recopié dans `opencti/.env` : c'est l'étape qui manquait pour qu'une
infra fraîchement déployée voie réellement ses deux plateformes s'alimenter.

Ce script est idempotent. Il :
  1. crée le label `export-misp` s'il n'existe pas (tous les Reports produits
     par l'outillage d'alimentation doivent le porter) ;
  2. crée — ou retrouve — le live stream « OpenCTI -> MISP » filtré sur
     `entity_type = Report` ET `objectLabel = export-misp` ;
  3. écrit son id dans `opencti/.env` (CONNECTOR_MISP_INTEL_STREAM_ID).

Il reste ensuite à recréer le conteneur pour qu'il prenne l'id :
    make up-cti

Usage : bridge_setup.py [--name NOM] [--dry-run]
"""
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _config import OPENCTI_URL, opencti_client  # adressage : voir _config.py

ROOT = pathlib.Path(__file__).resolve().parents[1]
ENV = ROOT / "opencti" / ".env"
LABEL = "export-misp"
DEFAULT_NAME = "OpenCTI -> MISP"

LIST_Q = """
query StreamCollections {
  streamCollections(first: 200) {
    edges { node { id name description filters stream_live stream_public } }
  }
}
"""

ADD_Q = """
mutation StreamCollectionAdd($input: StreamCollectionAddInput!) {
  streamCollectionAdd(input: $input) { id name stream_live }
}
"""

EDIT_Q = """
mutation StreamCollectionEdit($id: ID!, $input: [EditInput!]!) {
  streamCollectionEdit(id: $id) { fieldPatch(input: $input) { id name filters } }
}
"""


def stream_filters(label_id):
    """Filtre du stream : les Reports étiquetés export-misp.

    `CONNECTOR_LIVE_STREAM_NO_DEPENDENCIES=false` côté connecteur fait suivre
    les objets contenus dans le rapport — inutile de les filtrer ici (à ne pas
    confondre avec la collection TAXII, qui exige la branche
    `dynamicRegardingOf` explicite, voir docs/DELIVERY.md).
    """
    return json.dumps({
        "mode": "and",
        "filters": [
            # `key` doit être un TABLEAU côté OpenCTI 7.x : une chaîne renvoie
            # UNSUPPORTED_ERROR « The provided filter key is not an array ».
            {"key": ["entity_type"], "values": ["Report"], "operator": "eq", "mode": "or"},
            {"key": ["objectLabel"], "values": [label_id], "operator": "eq", "mode": "or"},
        ],
        "filterGroups": [],
    })


def set_env(key, value):
    lines = ENV.read_text(encoding="utf-8").splitlines()
    for i, line in enumerate(lines):
        if line.startswith(f"{key}="):
            if line == f"{key}={value}":
                return False
            lines[i] = f"{key}={value}"
            break
    else:
        lines.append(f"{key}={value}")
    ENV.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return True


def main():
    args = sys.argv[1:]
    name = args[args.index("--name") + 1] if "--name" in args else DEFAULT_NAME
    dry = "--dry-run" in args
    c = opencti_client()
    print(f"OpenCTI : {OPENCTI_URL}")

    label = c.label.read(filters={"mode": "and", "filterGroups": [], "filters": [
        {"key": "value", "values": [LABEL]}]})
    if label:
        print(f"  label {LABEL} : existant ({label['id']})")
    elif dry:
        print(f"  label {LABEL} : à créer")
        return
    else:
        label = c.label.create(value=LABEL, color="#d81b60")
        print(f"  label {LABEL} : créé ({label['id']})")

    existing = [e["node"] for e in c.query(LIST_Q)["data"]["streamCollections"]["edges"]]
    want = stream_filters(label["id"])
    stream = next((s for s in existing if s["name"] == name), None)
    if stream is None:
        if dry:
            print(f"  live stream « {name} » : à créer")
            return
        stream = c.query(ADD_Q, {"input": {
            "name": name,
            "description": "Reports étiquetés export-misp, republiés dans MISP "
                           "par connector-misp-intel.",
            "filters": want,
            # stream_live=False => le connecteur reçoit un HTTP 410 « This live
            # stream is stopped » et sa boucle ListenStream s'arrête aussitôt.
            "stream_live": True,
            "stream_public": False,
        }})["data"]["streamCollectionAdd"]
        print(f"  live stream « {name} » : créé et démarré ({stream['id']})")
    else:
        print(f"  live stream « {name} » : existant ({stream['id']})")
        patch = []
        if stream.get("filters") != want:
            patch.append({"key": "filters", "value": [want]})
        if not stream.get("stream_live"):
            patch.append({"key": "stream_live", "value": ["true"]})
        if patch and not dry:
            c.query(EDIT_Q, {"id": stream["id"], "input": patch})
            print("    réaligné : " + ", ".join(p["key"] for p in patch))

    if dry:
        return
    changed = set_env("CONNECTOR_MISP_INTEL_STREAM_ID", stream["id"])
    print(f"  opencti/.env : CONNECTOR_MISP_INTEL_STREAM_ID={stream['id']}"
          f"{'' if changed else ' (inchangé)'}")
    if changed:
        print("\n→ recréer le connecteur pour qu'il prenne l'id : make up-cti")


if __name__ == "__main__":
    main()
