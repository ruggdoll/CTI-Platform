"""État du socle MITRE ATT&CK dans OpenCTI, et reste à ingérer.

Le socle ATT&CK est le référentiel sur lequel se raccrochent tous les rapports
(attack-pattern par `external_id` T1xxx). Il doit être complet AVANT de lancer
les connecteurs de flux (`make opencti-feeds`) : un rapport importé plus tôt
crée des attack-patterns en souche qu'il faut fusionner ensuite.

Usage : attack_status.py [--wait] [--timeout SECONDES]
  --wait : bloque jusqu'à ce que le socle soit complet (pour un build enchaîné).
"""
import pathlib
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _config import OPENCTI_URL, opencti_client

# Ordres de grandeur ATT&CK Enterprise + Mobile + ICS. Ce sont des REPÈRES
# d'affichage, PAS un critère de complétude : le nombre exact varie d'une
# version d'ATT&CK à l'autre (mesuré : 709 techniques, pas 800), et jauger sur
# une valeur devinée fait attendre indéfiniment un seuil inatteignable.
# `campaigns` est dans la liste EXPRÈS : c'est le type qui manquait quand un
# CONNECTOR_SCOPE mal formé a été posé sur le connecteur MITRE (2026-09-09), et
# son absence faisait échouer en boucle toutes les relations qui le référencent
# sans qu'aucun compteur d'entités ne le signale. Un socle à 0 campagne est un
# socle cassé, pas un socle en cours.
# Mesurés sur un import complet (2026-09-09) : ~1600 techniques, 189 groupes,
# 855 malwares, 1211 mitigations, 65 campagnes. Une première mesure donnait 709
# techniques — c'était un import TRONQUÉ (relations en échec, file purgée) : ne
# jamais figer un repère sur une observation partielle, et ne jamais gater
# dessus. Ces valeurs ne servent qu'à l'affichage.
ATTENDU = {"attackPatterns": 1600, "intrusionSets": 185, "malwares": 850,
           "coursesOfAction": 1200, "campaigns": 60}
LIBELLE = {"attackPatterns": "techniques (attack-pattern)", "intrusionSets": "groupes (intrusion-set)",
           "malwares": "malwares", "coursesOfAction": "mitigations (course-of-action)",
           "campaigns": "campagnes (campaign)"}


def compte(c, t):
    q = f"query {{ {t}(first: 1) {{ pageInfo {{ globalCount }} }} }}"
    return c.query(q)["data"][t]["pageInfo"]["globalCount"]


def file_restante():
    """Messages encore en file côté RabbitMQ, par connecteur (best effort)."""
    try:
        out = subprocess.run(
            ["docker", "exec", "cti-platform-opencti-rabbitmq-1", "rabbitmqctl", "list_queues", "name", "messages"],
            capture_output=True, text=True, timeout=30).stdout
    except Exception:
        return None
    total = 0
    for line in out.splitlines():
        p = line.split()
        if len(p) == 2 and p[0].startswith("push_") and p[1].isdigit():
            total += int(p[1])
    return total


# Résidu toléré dans la file : quelques messages en cours de rejeu ne doivent
# pas empêcher de conclure.
RESIDU_FILE = 50


def etat(c):
    """(familles présentes ?, lignes d'état).

    Le critère est objectif : chaque famille d'objets doit être PRÉSENTE. La
    complétude réelle se lit sur la file d'ingestion (vide = le connecteur a
    tout livré), pas sur un pourcentage d'une valeur estimée.
    """
    presentes, lignes = True, []
    for t, repere in ATTENDU.items():
        n = compte(c, t)
        pct = min(100, round(100 * n / repere))
        libelle = "présent" if n else "VIDE"
        presentes = presentes and n > 0
        lignes.append(f"  {LIBELLE[t]:32} {n:>6}  (repère ~{repere}, {pct:>3} %)  {libelle}")
    return presentes, lignes


def main():
    args = sys.argv[1:]
    attendre = "--wait" in args
    limite = int(args[args.index("--timeout") + 1]) if "--timeout" in args else 5400
    c = opencti_client()
    print(f"OpenCTI : {OPENCTI_URL}\n")

    t0 = time.time()
    while True:
        presentes, lignes = etat(c)
        reste = file_restante()
        print("\n".join(lignes))
        if reste is not None:
            print(f"\n  file d'ingestion restante : {reste} message(s)")
        # Complet = toutes les familles présentes ET le connecteur a fini de
        # livrer. Si la file n'est pas mesurable, on se rabat sur la présence.
        complet = presentes and (reste is None or reste <= RESIDU_FILE)
        if complet or not attendre:
            break
        if time.time() - t0 > limite:
            raise SystemExit(f"\nsocle ATT&CK toujours incomplet après {limite}s — "
                             "vérifier 'docker logs cti-platform-opencti-connector-mitre-1'")
        print(f"  … {time.time() - t0:.0f}s, on laisse tourner\n", flush=True)
        time.sleep(60)

    print()
    if complet:
        print("→ socle ATT&CK en place (toutes les familles présentes, file vidée).")
    elif not presentes:
        vides = [LIBELLE[t] for t in ATTENDU if compte(c, t) == 0]
        print(f"→ socle CASSÉ : {', '.join(vides)} à zéro. Vérifier qu'aucun CONNECTOR_SCOPE "
              "ne filtre le connecteur MITRE (§3.1.1 du prompt de reconstruction).")
        if attendre:
            raise SystemExit(1)
    else:
        print("→ ingestion en cours : laisser tourner, ne PAS démarrer les flux.")
        if attendre:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
