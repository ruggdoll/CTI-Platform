# Installation & exploitation

## 0. Prérequis

- Docker Engine + plugin `docker compose` v2
- L'utilisateur courant dans le groupe `docker` (`id | grep docker` ; sinon
  `sudo usermod -aG docker $USER` puis **reconnexion**)
- `git`, `python3` (>= 3.10), `make`
- ~4 Go RAM libres, ~10 Go disque

## 1. Récupération

```bash
git clone --recurse-submodules https://github.com/ruggdoll/CTI-Platform
cd CTI-Platform
# si déjà cloné sans --recurse-submodules :
git submodule update --init --recursive
```

## 2. Configuration

```bash
make init HOST=serveurCTI     # FQDN ou IP par lequel les CLIENTS joindront la plateforme
```

`HOST` est **la** valeur à fixer à la création de l'infra : une seule commande
génère les trois fichiers d'environnement et les aligne tous dessus —
`vendor/misp-docker/.env` (`BASE_URL=https://<HOST>`), `opencti/.env`
(`OPENCTI_HOST`, `MISP_REFERENCE_URL`). Sans
argument, `HOST` prend le FQDN de la machine (`hostname -f`), sinon `localhost`.

Se tromper de nom est le piège classique du déploiement distant : MISP et
OpenCTI construisent leurs URL absolues à partir de ces valeurs, donc une infra
déclarée sur `localhost` mais jointe par un FQDN casse les redirections, les
liens des rapports et la vérification CSRF d'OpenCTI.

| Variable | Remarque |
|---|---|
| `HOST` (make) | FQDN ou IP publique de la plateforme, propagé aux trois `.env` |
| `BIND_ADDRESS` | `0.0.0.0` (défaut) pour une machine distante, `127.0.0.1` pour un poste isolé |
| `ADMIN_EMAIL` | identité du compte admin MISP |
| `MISP_ORG` (make) | organisation qui porte la plateforme des deux côtés : org #1 de MISP (`ADMIN_ORG`) **et** valeur lue par les deux ponts (`MISP_IMPORT_CREATOR_ORGS`, `MISP_OWNER_ORG`). Défaut `ruggdoll` ; si les deux divergent, MISP et OpenCTI ne se voient pas |
| `ADMIN_KEY` | clé API admin MISP, tirée au hasard par `make init` puis **propagée** dans `opencti/.env` (`MISP_KEY`) ; un outil d'alimentation la lit là, ou reçoit une clé d'automation dédiée |
| `CORE_HTTP_PORT` / `CORE_HTTPS_PORT` / `OPENCTI_PORT` | changer si les ports sont déjà pris |
| `TZ` | `Europe/Paris` |

Les **comptes utilisateur** des deux interfaces (admin MISP, admin OpenCTI)
valent `MyP@ssword42!` par défaut — surchargeable avec
`make init HOST=… DEFAULT_PASSWORD='…'`, **à changer sur une instance exposée**.
Les secrets des briques d'infrastructure (MariaDB, Redis, MinIO, RabbitMQ) et
les clés cryptographiques (`ENCRYPTION_KEY`, `SALT`, GPG, jetons, identifiants
de connecteurs) restent tirés au hasard : ils ne se saisissent jamais.

Les outils Python ne codent aucune URL ni aucun jeton en dur : ils lisent ces
mêmes `.env` via `provisioning/_config.py`, surchargeable par les variables
d'environnement `OPENCTI_URL`, `OPENCTI_TOKEN`, `MISP_URL`, `MISP_KEY`.

## 3. Démarrage

```bash
make up          # 1er lancement : pull + build, 5-10 min
make logs        # attendre "MISP is ready" / healthcheck OK
make ps
```

Se connecter sur `BASE_URL` (`https://<HOST>`) avec `ADMIN_EMAIL` /
`ADMIN_PASSWORD`, depuis n'importe quelle machine qui joint `HOST`.
Le certificat livré est auto-signé et porte `CN=localhost` : le navigateur
avertit à la fois sur l'autorité et sur le nom. Pour un usage réel, poser un
certificat au nom de `HOST` dans `vendor/misp-docker/ssl/` (`cert.pem`,
`key.pem`) ou terminer le TLS sur un reverse-proxy en amont.

## 4. OpenCTI et le pont entre les deux plateformes

```bash
make venv          # environnement Python (une fois)
make opencti-up    # OpenCTI sur http://<HOST>:8080 (~12 Go RAM, 1er boot 5-10 min)
make bridge-setup  # label export-misp + live stream OpenCTI -> MISP + .env
make opencti-up    # recrée connector-misp-intel avec l'id du stream
```

`make bridge-setup` (`provisioning/bridge_setup.py`, idempotent) est l'étape qui
rend le couple réellement bidirectionnel : elle crée le label `export-misp` que
porte chaque rapport, le **live stream** « `entity_type = Report` ET
`objectLabel = export-misp` » que consomme `connector-misp-intel`, et écrit son
identifiant dans `opencti/.env`. Sans elle, les rapports OpenCTI ne
redescendent jamais dans MISP.

Les deux sens, une fois câblés :

| Sens | Connecteur | Ce qui passe |
|---|---|---|
| OpenCTI → MISP | `connector-misp-intel` | chaque `Report` étiqueté `export-misp` et son contenu → event MISP (distribution 1, non publié) |
| MISP → OpenCTI | `connector-misp` | les events de l'org `MISP_ORG` → Indicators/Observables (jamais de `Report`) |

Anti-boucle : les events créés par le pont retour sortent en distribution 1 et
`connector-misp` n'importe que les distributions 0 et 3.

### Rotation de la clé API MISP

```bash
make misp-setup    # régénère la clé admin, la repose dans les deux .env, réaligne l'org
make opencti-up    # recrée les connecteurs avec la nouvelle clé
```

`make admin-key` se contente d'afficher une clé fraîche. Les outils Python
lisent les `.env` via `provisioning/_config.py` — rien à exporter dans le
shell ; pour une exécution ponctuelle avec d'autres identifiants, les variables
d'environnement l'emportent :

```bash
export MISP_URL=https://serveurCTI
export MISP_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
export MISP_VERIFY_SSL=0        # cert auto-signé
```

## 5. Alimenter la plateforme

La plateforme n'analyse rien et ne moissonne rien. Elle expose les interfaces
standard des deux produits ; c'est à un outillage d'alimentation, tenu à part,
de les utiliser.

| Vers | Interface | Adressage |
|---|---|---|
| OpenCTI | bundle STIX 2.1 : connecteur `import-file-stix` (dossier surveillé) ou `stix2.import_bundle_from_file` (pycti). Un `Report` par publication, étiqueté `export-misp` pour être repris par le pont retour et par la collection TAXII | `opencti/.env` : `OPENCTI_EXTERNAL_SCHEME`, `OPENCTI_HOST`, `OPENCTI_PORT`, `OPENCTI_ADMIN_TOKEN` |
| MISP | feed MISP natif enregistré par l'API, ou event construit par l'API (PyMISP) | `vendor/misp-docker/.env` : `BASE_URL` ; clé : `MISP_KEY` de `opencti/.env`, ou de préférence une **clé d'automation dédiée** (Administration > Auth Keys > Add) pour qu'une rotation de la clé admin ne casse pas les traitements |

Deux contraintes de la plateforme : les events du pont retour restent en
distribution 1 (signal anti-boucle, ne jamais les passer en 3), et un
observable qu'un rapport porte déjà dans OpenCTI ne se réimporte pas dans MISP
— il y arrive par le pont.

## 6. Mise à jour de MISP

```bash
cd vendor/misp-docker && git pull && cd ../..
git add vendor/misp-docker && git commit -m "bump misp-docker"
# ajuster CORE_TAG / MODULES_TAG dans vendor/misp-docker/.env si besoin
make down && make up
```

## Serveur : ingérer les mises à jour de rapports

Le serveur **n'analyse rien**. Il reçoit les bundles STIX déjà construits par
l'outillage d'alimentation, par le connecteur `import-file-stix` ou par
l'API. Un import à identifiants déterministes (uuid5 sur les propriétés clés)
met les objets à jour **en place** ; des identifiants aléatoires créent des
doublons à chaque renvoi.

### Ce qui ne passe pas par les bundles

Une chose n'est pas portée par les bundles et se rejoue côté serveur après un
import :

- **`first_seen` / `last_seen` des entités** — sans eux, OpenCTI laisse des
  valeurs sentinelles (1970 et 5138) et tout classement par récence est faux.
  À poser par l'API depuis les dates des rapports qui citent chaque entité.

### Mettre à jour un rapport sans créer de doublon

Si l'identifiant d'un `Report` dérive de son **titre** et de sa **date de
publication**, republier un bundle corrigé met le rapport à jour en place tant
que ces deux champs ne bougent pas ; s'ils bougent, l'import crée un second
rapport à côté de l'ancien, sans que rien ne le signale. Contrôler l'identité
des rapports avant toute republication massive.

### Suppressions

Une suppression **ne se propage pas** : retirer un bundle de l'outillage
d'alimentation ne supprime pas le rapport côté serveur. Les suppressions
restent des gestes manuels, à faire dans l'interface ou par l'API, et à
consigner.
