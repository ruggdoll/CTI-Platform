"""es_tag_latest.py — dernière version stable d'Elasticsearch publiée sur
docker.elastic.co, le seul registre de la plateforme sans tag 'latest'.
Accès anonyme (pull public), même mécanique que n'importe quel registre
Docker v2 : jeton via l'endpoint d'auth, puis la liste des tags. Ne garde
que les versions strictes X.Y.Z (exclut -SNAPSHOT, arm64…).

Appelé par provisioning/maj_nocturne.sh avant chaque `make pull-cti`.
"""
import re
import sys

import requests

REGISTRE = "https://docker.elastic.co"
IMAGE = "elasticsearch/elasticsearch"


def derniere_version() -> str:
    jeton = requests.get(
        "https://docker-auth.elastic.co/auth",
        params={"service": "token-service", "scope": f"repository:{IMAGE}:pull"},
        timeout=15,
    ).json()["token"]
    tags = requests.get(
        f"{REGISTRE}/v2/{IMAGE}/tags/list",
        headers={"Authorization": f"Bearer {jeton}"},
        timeout=15,
    ).json()["tags"]
    versions = [t for t in tags if re.fullmatch(r"\d+\.\d+\.\d+", t)]
    if not versions:
        raise RuntimeError("aucun tag X.Y.Z trouvé sur le registre Elastic")
    versions.sort(key=lambda v: tuple(int(x) for x in v.split(".")))
    return versions[-1]


if __name__ == "__main__":
    try:
        print(derniere_version())
    except Exception as exc:  # noqa: BLE001 — script utilitaire, une ligne d'erreur suffit
        print(f"es_tag_latest.py : {exc}", file=sys.stderr)
        sys.exit(1)
