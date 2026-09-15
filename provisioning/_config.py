"""Adressage de la plateforme, lu une seule fois et partagé par tous les outils.

Rien n'est codé en dur : les URL et les jetons viennent des fichiers .env générés
par `make init HOST=<fqdn|ip>` (gitignorés), ou de variables d'environnement qui
les emportent. C'est ce qui permet de déployer la même base de code sur un poste
local (`localhost`) comme sur une machine distante jointe par FQDN ou par IP.

Ordre de résolution :
  1. variables d'environnement OPENCTI_URL / OPENCTI_TOKEN / MISP_URL / MISP_KEY
  2. opencti/.env      (OPENCTI_EXTERNAL_SCHEME, OPENCTI_HOST, OPENCTI_PORT, OPENCTI_ADMIN_TOKEN, MISP_KEY)
     vendor/misp-docker/.env (BASE_URL, ADMIN_KEY)

Usage :
    from _config import opencti_client, OPENCTI_URL, MISP_URL, MISP_KEY, MISP_ORG
    c = opencti_client()
"""
from __future__ import annotations

import os
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]


def _read_env(path: pathlib.Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.exists():
        return out
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


_OCTI = _read_env(ROOT / "opencti" / ".env")
_MISP = _read_env(ROOT / "vendor" / "misp-docker" / ".env")


def _opencti_url() -> str:
    if os.environ.get("OPENCTI_URL"):
        return os.environ["OPENCTI_URL"].rstrip("/")
    # Derrière un proxy inverse, l'URL publique n'a plus le port interne :
    # OPENCTI_BASE_URL la porte telle quelle et l'emporte sur la reconstruction.
    if _OCTI.get("OPENCTI_BASE_URL"):
        return _OCTI["OPENCTI_BASE_URL"].rstrip("/")
    scheme = _OCTI.get("OPENCTI_EXTERNAL_SCHEME", "http")
    host = _OCTI.get("OPENCTI_HOST", "localhost")
    port = _OCTI.get("OPENCTI_PORT", "8080")
    return f"{scheme}://{host}:{port}"


OPENCTI_URL = _opencti_url()
OPENCTI_TOKEN = os.environ.get("OPENCTI_TOKEN") or _OCTI.get("OPENCTI_ADMIN_TOKEN", "")
MISP_URL = (os.environ.get("MISP_URL") or _MISP.get("BASE_URL", "https://localhost")).rstrip("/")
MISP_KEY = os.environ.get("MISP_KEY") or _OCTI.get("MISP_KEY", "") or _MISP.get("ADMIN_KEY", "")
# Vérification TLS côté MISP : le certificat livré par la stack est auto-signé
# (CN=localhost), donc désactivée par défaut. MISP_VERIFY_SSL=1 dès qu'un vrai
# certificat au nom de HOST est en place.
MISP_VERIFY_SSL = os.environ.get("MISP_VERIFY_SSL", "0") not in {"0", "false", "no", ""}
# organisation MISP de la plateforme : celle qui porte les events créés par le
# pont OpenCTI -> MISP et la seule que connector-misp réimporte (MISP_ORG dans
# opencti/.env, source unique pour les deux piles).
MISP_ORG = os.environ.get("MISP_ORG") or _OCTI.get("MISP_ORG", "ruggdoll")
# identité du compte admin MISP : sert à dériver le domaine des comptes de
# service créés à côté (cf. provisioning/misp_cle_automation.py).
ADMIN_EMAIL = os.environ.get("ADMIN_EMAIL") or _MISP.get("ADMIN_EMAIL", "admin@cti-lab.local")


def opencti_client(**kw):
    """Client pycti configuré pour cette plateforme. Lève une erreur explicite si
    le jeton manque, plutôt que d'échouer en HTTP 401 plus loin."""
    if not OPENCTI_TOKEN:
        raise SystemExit(
            "jeton OpenCTI introuvable : lancer 'make init HOST=<fqdn|ip>' ou définir OPENCTI_TOKEN"
        )
    from pycti import OpenCTIApiClient

    kw.setdefault("log_level", "error")
    kw.setdefault("ssl_verify", False)
    return OpenCTIApiClient(OPENCTI_URL, OPENCTI_TOKEN, **kw)
