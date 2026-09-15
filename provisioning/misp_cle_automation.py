#!/usr/bin/env python3
"""Crée une clé d'automation MISP DÉDIÉE, distincte de la clé admin.

    make cle-automation                                   crée et affiche
    make cle-automation ARGS="--commentaire 'CTI-farm'"    en la nommant
    make cle-automation ARGS=--lister                      inventaire, sans secret
    make cle-automation ARGS=--env > /chemin/outil/.env    adressage complet

Le README recommande depuis toujours une clé dédiée « pour qu'une rotation de
la clé admin ne casse pas les traitements » — mais rien ne la produisait, si
bien que `make adressage` émet la clé admin faute de mieux. Or `make misp-setup`
la régénère : tout outil d'alimentation qui s'en sert tombe alors en 403, sans
que la cause soit lisible de son côté.

LA CLÉ DOIT APPARTENIR À UN AUTRE UTILISATEUR. `make misp-setup` appelle
`cake user change_authkey`, qui invalide TOUTES les clés de l'utilisateur visé,
pas seulement la précédente. Une clé d'automation créée sur le compte admin
tombe donc avec lui — mesuré le 2026-09-15 : HTTP 403 après rotation. Cet outil
crée donc un utilisateur dédié (rôle « User » : API autorisée, création
d'events permise, ni administration ni synchronisation) et mine la clé pour
LUI. Une rotation de la clé admin ne le touche pas.

MISP ne montre la valeur d'une clé qu'UNE SEULE FOIS, à la création : elle
n'est pas récupérable ensuite, seulement révocable et remplaçable.
"""
from __future__ import annotations

import json
import pathlib
import secrets as secrets_mod
import ssl
import string
import sys
import urllib.error
import urllib.request
from datetime import date, datetime

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _config import ADMIN_EMAIL, MISP_KEY, MISP_URL, MISP_VERIFY_SSL  # noqa: E402
from adressage import avertit_localhost, lignes_env  # noqa: E402

VERT, ROUGE, FIN = "\033[32m", "\033[31m", "\033[0m"

# Rôle « User » : perm_auth (API) et perm_add (créer des events), sans
# administration ni synchronisation. Le moins-disant qui permette d'alimenter.
ROLE_UTILISATEUR = "3"


def _appel(chemin: str, corps: dict | None = None) -> dict:
    ctx = None if MISP_VERIFY_SSL else ssl._create_unverified_context()
    donnees = json.dumps(corps).encode() if corps is not None else None
    req = urllib.request.Request(
        f"{MISP_URL}{chemin}",
        data=donnees,
        headers={"Authorization": MISP_KEY, "Accept": "application/json",
                 "Content-Type": "application/json"},
        method="POST" if corps is not None else "GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=30, context=ctx) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        detail = e.read()[:400].decode(errors="replace")
        raise SystemExit(f"{ROUGE}MISP a refusé {chemin} : HTTP {e.code}{FIN}\n  {detail}") from e
    except (urllib.error.URLError, TimeoutError) as e:
        raise SystemExit(f"{ROUGE}MISP injoignable sur {MISP_URL} : {e}{FIN}") from e


def _date(v) -> str:
    """MISP renvoie ces champs en secondes epoch ; 0 vaut « pas d'expiration »."""
    if v in (None, "", "0", 0):
        return "jamais"
    try:
        return datetime.fromtimestamp(int(v)).strftime("%Y-%m-%d")
    except (TypeError, ValueError, OSError):
        return str(v)[:11]


def lister() -> None:
    d = _appel("/auth_keys/index")
    lignes = d if isinstance(d, list) else d.get("AuthKeys", [])
    if not lignes:
        print("  aucune clé d'automation enregistrée")
        return
    print(f"  {'id':>4}  {'début…fin':<14} {'créée':<11} {'expiration':<11} commentaire")
    for e in lignes:
        a = e.get("AuthKey", e)
        print(f"  {str(a.get('id','?')):>4}  {a.get('authkey_start','?')}…{a.get('authkey_end','?'):<6} "
              f"{_date(a.get('created')):<11} {_date(a.get('expiration')):<11} "
              f"{a.get('comment','') or '(sans commentaire)'}")


def _mot_de_passe() -> str:
    """MISP exige une complexité. Ce compte ne sert que par API : le mot de
    passe n'est ni affiché ni conservé — s'il fallait une session web un jour,
    l'admin le réinitialise."""
    alpha = string.ascii_lowercase + string.ascii_uppercase + string.digits
    return ("".join(secrets_mod.choice(alpha) for _ in range(20))
            + "aA1!" + secrets_mod.choice("#$%&*+-="))


def utilisateur_dedie(email: str, role_id: str) -> str:
    """Renvoie l'id du compte dédié, en le créant s'il n'existe pas.

    Idempotent : relancer la commande réutilise le compte et n'y ajoute qu'une
    clé de plus. C'est voulu — on peut vouloir une clé par consommateur.
    """
    for u in _appel("/admin/users"):
        c = u.get("User", u)
        if (c.get("email") or "").lower() == email.lower():
            return str(c.get("id"))

    moi = (_appel("/users/view/me").get("User") or {})
    org = moi.get("org_id")
    if not org:
        raise SystemExit(f"{ROUGE}organisation de l'utilisateur courant introuvable{FIN}")
    rep = _appel("/admin/users/add", {
        "email": email, "org_id": org, "role_id": role_id,
        "password": _mot_de_passe(), "change_pw": 0, "termsaccepted": 1,
        "autoalert": 0, "disabled": 0,
    })
    uid = (rep.get("User") or rep).get("id")
    if not uid:
        raise SystemExit(f"{ROUGE}création du compte refusée{FIN}\n  {json.dumps(rep)[:400]}")
    print(f"  {VERT}compte dédié créé{FIN} — {email} (rôle {role_id}, organisation {org})",
          file=sys.stderr)
    return str(uid)


def cree(commentaire: str, expiration: str, email: str, role_id: str) -> str:
    uid = utilisateur_dedie(email, role_id)
    rep = _appel(f"/auth_keys/add/{uid}", {"comment": commentaire, "expiration": expiration})
    a = rep.get("AuthKey", rep)
    brute = a.get("authkey_raw") or a.get("authkey")
    if not brute:
        raise SystemExit(f"{ROUGE}MISP n'a pas renvoyé la clé en clair{FIN}\n  {json.dumps(rep)[:400]}")
    return brute


def main() -> None:
    args = sys.argv[1:]
    if "--lister" in args:
        lister()
        return

    def opt(nom: str, defaut: str) -> str:
        return args[args.index(nom) + 1] if nom in args and len(args) > args.index(nom) + 1 else defaut

    commentaire = opt("--commentaire", f"outil d'alimentation — créée le {date.today()}")
    expiration = opt("--expire", "")
    domaine = ADMIN_EMAIL.partition("@")[2] or "cti-lab.local"
    email = opt("--utilisateur", f"automation@{domaine}")
    role = opt("--role", ROLE_UTILISATEUR)
    cle = cree(commentaire, expiration, email, role)

    if "--env" in args:
        avertit_localhost()
        for ligne in lignes_env(secrets=True, misp_key=cle):
            print(ligne)
        print(f"{VERT}clé d'automation créée{FIN} — « {commentaire} »", file=sys.stderr)
        print("MISP ne la montrera plus : ce fragment est le seul endroit où elle "
              "apparaît.", file=sys.stderr)
        return

    print(f"  {VERT}clé d'automation créée{FIN} — « {commentaire} »")
    print(f"  MISP_KEY={cle}")
    print()
    print("  MISP ne montrera plus cette valeur : la conserver maintenant, ou la révoquer")
    print("  et en créer une autre. Elle survit à « make misp-setup », contrairement à la")
    print("  clé admin. Inventaire : make cle-automation ARGS=--lister")


if __name__ == "__main__":
    main()
