# Installation & exploitation

## 0. Prérequis

- Docker Engine + plugin `docker compose` v2
- `git`, `python3` (>= 3.10), `make`
- ~4 Go RAM libres pour MISP seul, **~12 Go de plus** pour la pile OpenCTI
- Disque : ~10 Go pour MISP, nettement plus avec Elasticsearch et MinIO

L'accès au démon n'est plus testé par appartenance au groupe `docker` mais par
capacité — « est-ce que le démon me répond ? ». Les deux modes fonctionnent
donc sans réglage, et le **rootless est le mode recommandé** : il n'exige aucun
groupe root-équivalent.

### Hôte en Docker rootless — une commande

Sur une Debian 13 vierge, tout ce qui exige root tient dans un script, à lancer
**une fois** :

```bash
# une Debian minimale n'a pas git, et un clone en https exige les certificats
sudo apt-get install -y git ca-certificates
git clone --recurse-submodules https://github.com/ruggdoll/CTI-Platform
cd CTI-Platform

sudo provisioning/prepare_host.sh --user cti-platform --host <fqdn> \
     [--ip <adresse>] [--ssh-key <fichier|clé publique>]
```

Il est idempotent et ne fait rien d'autre que ce qui suit — chaque point
correspond à un échec de déploiement réel, silencieux ou illisible :

| Ce qu'il pose | Sans quoi |
|---|---|
| `uidmap`, `dbus-user-session`, `slirp4netns`, outillage | le démon rootless ne démarre pas, message obscur |
| Docker CE + `docker-ce-rootless-extras`, démon **rootful désactivé** | pas de `dockerd-rootless-setuptool.sh` ; un démon root actif en parallèle |
| `cap_net_bind_service` sur `rootlesskit` | un démon rootless ne lie ni 80 ni 443 |
| `vm.max_map_count=1048575` | Elasticsearch refuse de démarrer (contrôle bloquant) |
| le compte, ses plages `subuid`/`subgid` | `newuidmap` ne peut pas construire l'espace de noms |
| `nofile` 65536 et `memlock` illimité | un démon rootless **ne peut pas** relever ces limites lui-même |
| `loginctl enable-linger` | les conteneurs meurent à la déconnexion SSH |
| le FQDN sur l'IP du LAN dans `/etc/hosts` | l'installateur Debian le laisse sur `127.0.1.1`, et MISP comme OpenCTI fabriquent alors toutes leurs URL absolues sur du loopback |
| le démon rootless du compte, démarré et vérifié | — |

Le script refuse d'aller au bout si le nom public résout sur du loopback ou si
aucune adresse globale n'est trouvable : ce sont des erreurs qui ne se voient
qu'une heure plus tard, une fois la plateforme construite.

`provisioning/rootless_setup.sh` est la seconde moitié, sans privilège : elle
s'exécute seule si le démon d'un compte est à (re)poser. À lancer dans une
**vraie session** du compte — connexion SSH, console ou `machinectl shell` —
jamais par `sudo -u`, qui ne fournit ni `XDG_RUNTIME_DIR` ni bus systemd et
laisse le client Docker muet sans explication.

Puis, en tant que ce compte :

```bash
git clone --recurse-submodules https://github.com/ruggdoll/CTI-Platform ~/CTI-Platform
cd ~/CTI-Platform && make build HOST=<fqdn>
```

`provisioning/diag_rootless.sh` contrôle l'hôte à tout moment sans rien
modifier : mode du démon, pilote de stockage, capacité de MinIO à écrire
(volume nommé **et** répertoire lié), liaison effective des ports privilégiés.

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
| `CTI_HOST_TARGET` (make : `HOST_TARGET`) | adresse que les **conteneurs** visent pour joindre l'hôte par son nom public. `host-gateway` en rootful ; en rootless, l'adresse réelle de l'hôte — `make init` la détecte depuis `HOST`. Une valeur en `127.*` est refusée par un avertissement : un conteneur n'y joint pas l'hôte |
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

## 5 bis. Extinction, redémarrage, correctifs de sécurité

À l'extinction, systemd arrête le démon Docker, qui arrête les conteneurs avec
son `--shutdown-timeout` par défaut de **15 secondes**. C'est trop court pour
MariaDB, qui doit vider son buffer pool, et pour Elasticsearch, qui doit
écrire son translog : tués en pleine écriture, ils repartent en récupération.

`make autostart` (posé par `make build`, étape 9/9) installe une unité systemd
utilisateur ordonnée **après** le démon — donc arrêtée **avant** lui — dont
l'`ExecStop` lance `make stop-all` pendant que dockerd répond encore.
Deux délais, à ne pas confondre — les confondre revient à croire le problème
réglé alors qu'il ne l'est pas :

| Réglage | Ce qu'il borne | Défaut |
|---|---|---|
| `STOP_TIMEOUT` | le sursis de **chaque conteneur** avant son SIGKILL, passé à `compose stop -t` | 120 s |
| `AUTOSTART_TIMEOUT` | la durée **totale** de l'arrêt, `TimeoutStopSec` de l'unité | 300 s |
| drop-in `user@<uid>.service` | le plafond du gestionnaire de session, posé par `prepare_host.sh` | 300 s |

Sans `STOP_TIMEOUT`, `compose stop` n'accorde que **10 secondes** par conteneur
et MariaDB est tuée en pleine écriture — quels que soient les deux autres
réglages. Sans le drop-in, le gestionnaire de session serait tué au bout de
2 minutes, emportant l'arrêt en cours.

Le redémarrage automatique n'est pas perdu pour autant : Docker n'ignore la
politique `restart` d'un conteneur arrêté explicitement que **jusqu'au
redémarrage du démon**. Au démarrage de la machine, le linger relance la
session, donc le démon, qui relance tout ce qui est en `restart: always`.

`make autostart-off` retire l'unité. `make stop-all` s'utilise aussi à la main
avant une intervention.

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
