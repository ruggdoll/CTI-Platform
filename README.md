# CTI-Platform

Une plateforme de renseignement sur les menaces (CTI) auto-hébergée, faite de
deux piles Docker — **MISP** et **OpenCTI** — reliées par deux ponts, et de
quoi la **construire en une commande, l'exploiter, la sauvegarder, la
détruire et la mettre à jour**. Rien d'autre : ce dépôt ne contient aucune
donnée de renseignement et aucun outil de collecte. Le contenu vient de vos
propres outils d'alimentation, par les interfaces standard des deux produits
(bundles STIX 2.1 côté OpenCTI, API et feeds côté MISP).

```
    ┌────────────────┐   connector-misp-intel   ┌──────────────┐
    │    OpenCTI     │ ───── Reports ─────────▶ │     MISP     │
    │  graphe CTI    │                          │  observables │
    │  + Reports     │ ◀──── Indicators ─────── │              │
    └───────┬────────┘   connector-misp         └──────────────┘
            │
            └─▶ TAXII 2.1 ─▶ abonnés
```

- **OpenCTI** est le cœur : graphe de connaissance (Intrusion-Set, Malware,
  Campaign, Identity, Location, Attack-Pattern…), relations STIX, objets
  `Report` qui portent l'analyse. C'est là qu'arrivent les rapports.
- **MISP** est alimenté par deux chemins, jamais à la main : le pont
  OpenCTI → MISP qui republie chaque `Report` en event, et l'ingestion directe
  (feeds MISP natifs, API) pour les observables publiés sans rapport.
- Le pont MISP → OpenCTI remonte ces observables comme Indicators et
  Observables — **jamais** comme faux Reports.

## Démarrage rapide

```bash
# Debian minimale : git n'y est pas, et un clone en https exige les certificats
sudo apt-get install -y git ca-certificates

git clone --recurse-submodules https://github.com/ruggdoll/CTI-Platform
cd CTI-Platform

# Hôte neuf (Debian 13, Docker rootless) : tout ce qui exige root, une fois.
sudo provisioning/prepare_host.sh --user cti-platform --host <fqdn|ip>

# Puis, connecté en tant que ce compte :
make build HOST=<fqdn|ip>      # construit TOUTE la plateforme, dans le bon ordre
make bridge-test               # contrôle de bout en bout
```

Le rootless est le mode visé : aucun groupe root-équivalent, le socket Docker
appartient au compte qui porte la plateforme. `make build` détecte le mode et
dimensionne les deux piles sur la RAM réelle de la machine. Le mode rootful
reste utilisable sans réglage particulier.

`HOST` est **le** paramètre du déploiement : le nom (FQDN) ou l'IP par lequel
les clients joindront la plateforme. `make build` enchaîne les neuf étapes et
**attend** entre elles — API MISP disponible, plateforme OpenCTI en ligne,
socle ATT&CK complet — parce que l'ordre n'est pas interchangeable et qu'il ne
doit pas reposer sur la mémoire de celui qui déploie :

```
1. make init          les .env, alignés sur HOST
2. make up            pile MISP            -> https://<HOST>
3. make venv          environnement Python
4. make socle-misp    SOCLE MISP : galaxies, taxonomies, warninglists
5. make opencti-up    pile OpenCTI + MITRE -> http://<HOST>:8080
   attack-status --wait   attend que l'ATT&CK soit chargée, sans concurrence
6. make bridge-setup  label export-misp + live stream, puis recrée le connecteur
7. socle-opencti      SOCLE OpenCTI : rapports STIX publics VIGINUM
8. make opencti-feeds connecteurs de flux OpenCTI
9. make autostart     arrêt propre des piles à l'extinction (unité systemd)
```

La cible est **idempotente** : relançable sur une plateforme à moitié
construite. Chaque étape reste utilisable seule (`make socle-misp`,
`make socle-opencti`, `make attack-status`, `make bridge-setup`…) pour
reprendre au milieu — ou groupée : `make socle-all` pose les deux socles
(MISP puis OpenCTI) l'un après l'autre, une fois les deux piles up et
l'ATT&CK chargé.

`make init` génère les `.env` des deux piles et les aligne sur `HOST`. Comptes
par défaut : `admin@cti-lab.local` / `MyP@ssword42!` des deux côtés
(surchargeables, **à changer sur une instance exposée**). Les secrets
d'infrastructure et les clés cryptographiques sont tirés au hasard. Détail
dans [`docs/SETUP.md`](docs/SETUP.md) ; `make help` liste les cibles.

## Le socle — à poser avant tout flux

Les deux plateformes ont besoin de leurs **référentiels** avant de recevoir la
moindre donnée. Sans eux, les tags ne sont pas validés, les acteurs ne sont pas
reconnus, rien ne filtre les faux positifs, et les techniques citées dans un
rapport créent des souches vides à fusionner plus tard.

| Côté | Commande | Ce qui est posé |
|---|---|---|
| **MISP** | `make socle-misp` | galaxies (table canonique des acteurs et de leurs alias), taxonomies utilisées (`tlp`, `PAP`, `admiralty-scale`, `osint`, `misp`, `estimative-language`), **toutes** les warninglists, modèles d'objets, noticelists |
| **OpenCTI** | `make opencti-up` puis `make attack-status` | MITRE ATT&CK par `connector-mitre` : ~1 600 techniques, ~190 groupes, ~850 malwares, ~1 200 mitigations, ~65 campagnes. C'est le référentiel sur lequel se raccrochent tous les rapports par `external_id` T1xxx |
| **OpenCTI** | `make socle-opencti ARGS=--yes` | rapports STIX publics de VIGINUM (RRN, Portal Kombat, Matriochka, BIG) : source gouvernementale, TLP:CLEAR |

Les deux socles côte à côte, une fois les piles up et l'ATT&CK chargé :
`make socle-all`.

Sur une instance MISP neuve, **tout est livré désactivé** : les warninglists et
les taxonomies sont présentes en base, aucune n'est active. `make socle-misp`
corrige ça — il active **toutes** les warninglists et les six taxonomies
utilisées. Leur nombre suit les versions amont de MISP (125 warninglists et
180 taxonomies livrées au 2026-09-15) : c'est la couverture qui compte, pas le
compte.

**L'ordre compte.** Au premier démarrage, quatre connecteurs de masse lancés
ensemble saturent une machine à 4 cœurs et l'ATT&CK arrive au compte-gouttes.
`make opencti-up` ne démarre donc que le cœur, MITRE et les ponts ; les flux
externes attendent `make opencti-feeds`. `make attack-status` dit où en est le
socle et refuse de vous laisser croire qu'il est prêt quand il ne l'est pas.

Les bundles VIGINUM sont **épinglés par SHA de commit** et téléchargés en
dry-run par défaut : le script contrôle la structure (objets sans id, relations
orphelines, marquages, types) et s'arrête ; `--yes` importe. Ils utilisent des
types propres à OpenCTI (`media-content`, `channel`, `narrative`) — du STIX
étendu, pas du STIX invalide, mais une validation en mode strict les rejette.

## Alimenter la plateforme

La plateforme ne moissonne rien et n'analyse rien. Ce qu'un outil
d'alimentation doit savoir :

L'adressage, c'est la plateforme qui l'émet — `make adressage` en donne
l'aperçu, `make adressage ARGS=--secrets` le fragment `.env` à rediriger dans
l'outil, et `make cle-automation ARGS=--env` le même fragment avec une clé MISP
**dédiée**, qui survit à une rotation de la clé admin. Aller lire `opencti/.env` à la main ne vaut que si l'outil tourne sur
la même machine ; dès que la plateforme est ailleurs, c'est cette commande qui
fait foi.

| Vers | Interface | Où trouver l'adressage |
|---|---|---|
| OpenCTI | bundle STIX 2.1 par le connecteur `import-file-stix` ou `stix2.import_bundle_from_file` (pycti) ; un `Report` par publication, étiqueté **`export-misp`** pour être repris par le pont retour et par la collection TAXII | `make adressage` → `OPENCTI_URL`, `OPENCTI_TOKEN` |
| MISP | feed MISP natif enregistré par l'API, ou event créé par l'API (PyMISP) avec une **clé d'automation dédiée** | `make adressage` → `MISP_URL`, `MISP_KEY`, `MISP_ORG`, `MISP_VERIFY_SSL` |

Deux règles que la plateforme impose par construction : les events créés par
le pont retour sortent en distribution 1 et y restent (c'est le signal
anti-boucle), et un observable qu'un rapport porte déjà dans OpenCTI ne
s'importe pas une seconde fois dans MISP — il y arrive par le pont.

Ce qui ne voyage pas dans un bundle et se rejoue après un import :
`first_seen` / `last_seen` des entités (sinon OpenCTI laisse des valeurs
sentinelles, 1970 et 5138).

## Les deux piles

### OpenCTI — le graphe et les rapports

`make opencti-up` (`opencti/docker-compose.yml`) : plateforme, workers, et les
connecteurs MITRE ATT&CK, CISA KEV, import-document, import-file-stix, plus
les deux ponts MISP.

### MISP — les observables

`make up` (`vendor/misp-docker`, sous-module officiel, surcharges dans
`compose.tuning.yml` et `docker/`) : cœur, modules, MariaDB réglée pour le
volume (buffer pool dimensionné par `make init`), Redis. Le socle
(`make socle-misp`) fournit les
référentiels qui rendent les tags valides.

### Le pont entre les deux

| Sens | Connecteur | Ce qui passe |
|---|---|---|
| OpenCTI → MISP | `connector-misp-intel` | chaque `Report` étiqueté `export-misp` et son contenu → event MISP (distribution 1, non publié) |
| MISP → OpenCTI | `connector-misp` | events de l'organisation de la plateforme → Indicators/Observables, **jamais** de `Report` |

Anti-boucle : les events créés par le pont retour sortent en distribution 1 et
`connector-misp` n'importe que les distributions 0 et 3.

`make bridge-setup` crée le label `export-misp` et le **live stream** OpenCTI
(`entity_type = Report` ET `objectLabel = export-misp`) que consomme le pont,
puis écrit son identifiant dans `opencti/.env`. Sans lui, rien ne redescend
dans MISP — et rien ne le signale.

`make bridge-test` le prouve : il crée un rapport de contrôle **dans OpenCTI**
par l'API et attend de retrouver son observable **dans MISP** (domaine en
`.invalid`, jamais confondable avec un IOC réel). Le contrôle ne laisse rien
derrière lui : les objets créés des deux côtés sont supprimés à la fin, y
compris quand il échoue — `--keep` les conserve pour le débogage.

## Livraison

Voir [`docs/DELIVERY.md`](docs/DELIVERY.md). La plateforme sert une
**collection TAXII 2.1** (Reports `export-misp` **et** tout ce qu'ils
contiennent — filtre `dynamicRegardingOf`), contrôlée par `make taxii-check`
avec un client tiers. Feed MISP client et snapshot initial sont produits par
l'outillage d'alimentation, depuis les mêmes bundles.

## Exploiter

| Besoin | Commande |
|---|---|
| état et journaux | `make ps`, `make logs`, `make opencti-ps`, `make opencti-logs` |
| état du socle ATT&CK et de la file d'ingestion | `make attack-status` |
| rotation de la clé API MISP, réalignement de l'organisation | `make misp-setup` |
| contrôle bout en bout | `make bridge-test` |
| sauvegarde complète | `provisioning/backup_infra.sh` — volumes, montages liés, `.env`, dépôts ; conteneurs arrêtés |
| arrêt propre, conteneurs conservés | `make stop-all` — ils repartent au démarrage suivant du démon |
| arrêt, remise à zéro | `make down` / `make opencti-down` ; `make destroy` / `make opencti-destroy` (**perte totale**) |

## Arborescence

| Chemin | Rôle |
|---|---|
| `Makefile` | toutes les commandes de la plateforme (`make help`) |
| `vendor/misp-docker/` | sous-module — stack Docker officielle MISP, non modifiée |
| `compose.tuning.yml`, `docker/` | overrides de la pile MISP (MariaDB, ports, noms de volumes) |
| `opencti/` | pile OpenCTI + connecteurs, dont les deux ponts MISP |
| `provisioning/_config.py` | adressage unique (URL et jetons lus dans les `.env`, surchargés par l'environnement) |
| `provisioning/build_platform.sh` | construction complète dans le bon ordre (`make build`) |
| `provisioning/misp_socle.py`, `opencti_socle.py`, `attack_status.py` | socle des deux plateformes : référentiels MISP, ATT&CK, rapports STIX VIGINUM |
| `provisioning/bridge_setup.py`, `bridge_test.py`, `selftest/` | câblage et contrôle bout en bout du pont |
| `provisioning/taxii_check.py` | contrôle de la collection TAXII 2.1 livrée |
| `provisioning/misp_org.py`, `backup_infra.sh` | alignement de l'organisation MISP, sauvegarde complète |
| `docs/SETUP.md`, `docs/DELIVERY.md` | installation ; ce qui est livré et comment |

## Sécurité

- `.env` et tout ce qui contient un secret est ignoré par git.
- Ne jamais committer de clé API, de mot de passe ni de jeton. Les outils
  Python ne codent aucune URL ni aucun jeton en dur : tout passe par
  `provisioning/_config.py`.
- Le certificat livré par la pile MISP est auto-signé et porte `CN=localhost` :
  poser un certificat au nom de `HOST` avant tout usage réel.
- Le dépôt ne contient aucune donnée de renseignement : seuls les référentiels
  publics (galaxies, taxonomies et warninglists MISP, MITRE ATT&CK, annexes
  STIX de VIGINUM) sont posés à la construction.
