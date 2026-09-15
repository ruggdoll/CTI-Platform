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

Une clé créée ici survit à cette rotation. MISP ne montre sa valeur qu'UNE
SEULE FOIS, à la création : elle n'est pas récupérable ensuite, seulement
révocable et remplaçable.
"""
from __future__ import annotations

import json
import pathlib
import ssl
import sys
import urllib.error
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _config import MISP_KEY, MISP_URL, MISP_VERIFY_SSL  # noqa: E402
from adressage import avertit_localhost, lignes_env  # noqa: E402

VERT, ROUGE, FIN = "\033[32m", "\033[31m", "\033[0m"


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


def lister() -> None:
    d = _appel("/auth_keys/index")
    lignes = d if isinstance(d, list) else d.get("AuthKeys", [])
    if not lignes:
        print("  aucune clé d'automation enregistrée")
        return
    print(f"  {'id':>4}  {'début…fin':<14} {'expiration':<12} commentaire")
    for e in lignes:
        a = e.get("AuthKey", e)
        exp = a.get("expiration") or "0"
        exp = "jamais" if str(exp) in {"0", "", "None"} else str(exp)[:10]
        print(f"  {str(a.get('id','?')):>4}  {a.get('authkey_start','?')}…{a.get('authkey_end','?'):<6} "
              f"{exp:<12} {a.get('comment','') or '(sans commentaire)'}")


def cree(commentaire: str, expiration: str) -> str:
    moi = _appel("/users/view/me")
    uid = (moi.get("User") or {}).get("id")
    if not uid:
        raise SystemExit(f"{ROUGE}impossible de déterminer l'utilisateur courant{FIN}")
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

    from datetime import date
    commentaire = opt("--commentaire", f"outil d'alimentation — créée le {date.today()}")
    expiration = opt("--expire", "")
    cle = cree(commentaire, expiration)

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
