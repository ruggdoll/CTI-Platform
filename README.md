# CTI-Platform

Une plateforme de renseignement sur les menaces (CTI) auto-hébergée, faite de
deux piles Docker — **MISP** et **OpenCTI** — reliées par deux ponts, et de
quoi la **construire en une commande, l'exploiter et la détruire**. Rien
d'autre : ce dépôt ne contient aucune
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

Ce dépôt héberge aussi [CISO-Assistant](#ciso-assistant-grc) (GRC : risques,
conformité, audits), à côté — même hôte, cycle de vie séparé de `make
build-cti`/`make destroy-cti` (aucune donnée échangée avec MISP/OpenCTI,
démarrage volontaire par `make up-ciso`).

## Démarrage rapide

```bash
# Debian minimale : git n'y est pas, et un clone en https exige les certificats
sudo apt-get install -y git ca-certificates

git clone --recurse-submodules https://github.com/ruggdoll/CTI-Platform
cd CTI-Platform

# Hôte neuf (Debian 13, Docker rootless) : tout ce qui exige root, une fois.
sudo provisioning/prepare_host.sh --user cti-platform --host <fqdn|ip>
#   ... ou, pour deux identités derrière une façade HTTPS :
#   sudo provisioning/prepare_host.sh --user cti-platform --domaine <domaine>

# Puis, connecté en tant que ce compte :
make build-cti HOST=<fqdn|ip>  # construit TOUTE la plateforme, dans le bon ordre
#   ... ou : make build-cti DOMAINE=<domaine>  -> misp.<domaine> et opencti.<domaine>
#           derrière un proxy inverse, TLS par autorité locale (make proxy-ca)
make bridge-test               # contrôle de bout en bout
```

Le rootless est le mode visé : aucun groupe root-équivalent, le socket Docker
appartient au compte qui porte la plateforme. `make build-cti` détecte le mode
et dimensionne les deux piles sur la RAM réelle de la machine. Le mode
rootful reste utilisable sans réglage particulier.

`HOST` — ou `DOMAINE` en mode façade — est **le** paramètre du déploiement :
par quoi les clients joindront la plateforme. `make build-cti` enchaîne ses
étapes et **attend** entre elles — API MISP disponible, plateforme OpenCTI en
ligne, socle ATT&CK complet — parce que l'ordre n'est pas interchangeable et
qu'il ne doit pas reposer sur la mémoire de celui qui déploie :

```
1. make init          les .env, alignés sur HOST
2. démarre MISP        -> https://<HOST>
   make proxy-up          façade HTTPS, en mode DOMAINE uniquement
3. make venv          environnement Python
4. make socle-misp    SOCLE MISP : galaxies, taxonomies, warninglists
5. démarre OpenCTI + MITRE -> http://<HOST>:8080
   make attack-status ARGS=--wait   attend que l'ATT&CK soit chargée, sans concurrence
6. make bridge-setup  label export-misp + live stream, puis recrée le connecteur
7. make socle-opencti SOCLE OpenCTI : rapports STIX publics VIGINUM
8. make opencti-feeds connecteurs de flux OpenCTI
9. make autostart     arrêt propre des piles à l'extinction (unité systemd)
```

Les étapes 2 et 5 (démarrage de MISP, d'OpenCTI) sont internes à
`build-cti` — pas des cibles séparées à retenir ; côté commandes, seuls
`up-cti`/`down-cti`/`destroy-cti` existent pour agir dessus après coup.
CISO-Assistant n'apparaît pas dans cette liste : `make build-cti` ne la
construit jamais — [démarrage volontaire, à part](#ciso-assistant-grc).

La cible est **idempotente** : relançable sur une plateforme à moitié
construite. Certaines étapes internes restent utilisables seules
(`make socle-misp`, `make socle-opencti`, `make attack-status`, `make
bridge-setup`…) pour reprendre au milieu si besoin — ou groupée : `make
socle-all` pose les deux socles (MISP puis OpenCTI) l'un après l'autre, une
fois les deux piles up et l'ATT&CK chargé.

`make init` génère les `.env` des deux piles et les aligne sur `HOST`. Comptes
par défaut : `admin@cti-lab.local` / `MyP@ssword42!` des deux côtés
(surchargeables, **à changer sur une instance exposée**). Les secrets
d'infrastructure et les clés cryptographiques sont tirés au hasard. Détail
dans [`docs/SETUP.md`](docs/SETUP.md) ; `make help` liste les cibles.

## Deux identités derrière une façade HTTPS

`make build-cti DOMAINE=<domaine>` met un proxy inverse devant les deux piles et
leur donne un nom chacune, au lieu d'une seule façade où OpenCTI vivait sur un
port :

| | |
|---|---|
| `https://misp.<domaine>` | l'interface MISP |
| `https://opencti.<domaine>` | l'interface OpenCTI |

Les deux piles n'écoutent alors que sur `127.0.0.1` ; la façade tient 80 et 443
et les joint par le réseau Docker. Elle n'existe **que pour l'extérieur** : les
connecteurs, les workers et le pont MISP passent par les noms de conteneurs et
ne la traversent jamais.

Le TLS est assuré par un certificat **mkcert** (autorité locale posée sur
l'hôte, packagée dans Debian/Ubuntu) : `make init`/`make build-cti DOMAINE=…` le
génère en **joker** (`<domaine>` et `*.<domaine>`), pas nom par nom — toute
identité sous ce domaine y entre sans qu'il faille y repenser, y compris
`ciso.<domaine>` si vous démarrez [CISO-Assistant](#ciso-assistant-grc) à côté. Contrairement à un `openssl` maison, l'autorité n'a besoin d'être
approuvée qu'**une fois** par poste client — les régénérations ultérieures du
certificat (`make proxy-cert`) restent approuvées sans nouveau geste, tant que
la racine mkcert de l'hôte ne change pas.

### Ce que chaque poste client doit faire — une fois

**1. Résoudre les deux noms.** Ils n'ont pas à exister dans un DNS public ;
une entrée dans le fichier `hosts` suffit (`ciso.<domaine>` en plus si
CISO-Assistant est démarrée séparément) :

```bash
echo '<ip de la plateforme>   misp.<domaine> opencti.<domaine>' | sudo tee -a /etc/hosts
```

**2. Faire confiance à l'autorité locale**, sans quoi le navigateur signale une
autorité inconnue. Sur la plateforme :

```bash
make proxy-ca          # écrit dist/ac-locale.crt
```

Puis sur le poste client, après avoir récupéré ce fichier :

```bash
sudo cp ac-locale.crt /usr/local/share/ca-certificates/cti-platform.crt
sudo update-ca-certificates
```

**Firefox ne suit pas le magasin du système** : Paramètres → Vie privée et
sécurité → Certificats → Afficher les certificats → onglet **Autorités** →
Importer, puis cocher « Confirmer cette AC pour identifier des sites web ».
Chrome et Chromium utilisent le magasin système, eux.

La racine vaut dix ans : c'est un geste unique par poste. Une fois posée, les
outils d'alimentation peuvent repasser `MISP_VERIFY_SSL=1` — la vérification
TLS redevient possible, alors qu'elle était désactivée à cause du certificat
auto-signé `CN=localhost` livré par la pile MISP.

### Un domaine public plutôt qu'une autorité locale

Avec un domaine enregistré dont les noms n'ont pas à exister sur Internet,
Let's Encrypt reste utilisable : **HTTP-01 est impossible** — il faut que le
nom soit joignable publiquement sur le port 80 — mais **DNS-01 fonctionne**, il
ne demande qu'un enregistrement TXT dans la zone.

```bash
make cert-manuel DOMAINE=<domaine> CERT_EMAIL=<courriel>   # certbot affiche le TXT et attend
```

Le challenge est fait à la main : la procédure ne dépend d'aucun hébergeur DNS
particulier, et aucun jeton d'API n'est confié à la plateforme. Le certificat
est un joker `*.<domaine>`, donc **un seul TXT** couvre les deux noms — et
`ciso.<domaine>` avec, si CISO-Assistant tourne à côté.

La contrepartie est assumée : 90 jours de validité et pas d'automatisation
possible, donc un renouvellement manuel trimestriel. Le choix se fait entre un
geste par poste client une fois (autorité locale) et un geste sur le serveur
tous les trois mois (certificat public). Détails dans
[`docs/SETUP.md`](docs/SETUP.md) : l'architecture est identique dans les deux
cas, seule la fabrique des certificats change.

## CISO-Assistant (GRC)

Ce dépôt héberge aussi le compose de
[CISO-Assistant](https://github.com/intuitem/ciso-assistant-community) (GRC :
risques, conformité, audits), un troisième outil à côté de MISP/OpenCTI —
même hôte, même façade HTTPS par commodité, mais un cycle de vie propre.

**Pourquoi un cycle de vie à part** : MISP et OpenCTI échangent des données
par deux ponts et partagent un socle de référentiels à poser avant tout flux
— une paire réelle. CISO-Assistant n'a aucun de ces deux liens (zéro pont,
zéro socle, zéro adressage partagé avec les deux autres). D'où : `make
build-cti` et `make destroy-cti` ne la touchent jamais — `make up-ciso`/
`make down-ciso`/`make destroy-ciso` la pilotent, à part, quand vous le
décidez.

**Elle n'existe qu'en mode façade** (`DOMAINE=…`) : sa pile amont ne publie
aucun port, elle n'est joignable que par nom derrière Traefik — une
contrainte de l'image, pas un choix de ce dépôt. `make init` prépare
`CISO_HOSTNAME` dans `ciso-assistant/.env` dès que `DOMAINE` est fourni, mais
rien ne la démarre toute seule :

```bash
make up-ciso   # premier démarrage LENT : ~200 migrations Django,
               #   10-15 min constatées, en arrière-plan
```

| Besoin | Commande |
|---|---|
| démarrer | `make up-ciso` |
| premier compte admin | `make ciso-superuser` |
| état des conteneurs | `make ciso-ps` |
| journaux | `make ciso-logs` |
| arrêt, conteneurs conservés (avant reboot) | `make down-ciso` |
| arrêt, volumes détruits (base, Qdrant) | `make destroy-ciso` (**perte totale**) |

## Le socle — à poser avant tout flux

MISP et OpenCTI ont besoin de leurs **référentiels** avant de recevoir la
moindre donnée. Sans eux, les tags ne sont pas validés, les acteurs ne sont pas
reconnus, rien ne filtre les faux positifs, et les techniques citées dans un
rapport créent des souches vides à fusionner plus tard.

| Côté | Commande | Ce qui est posé |
|---|---|---|
| **MISP** | `make socle-misp` | galaxies (table canonique des acteurs et de leurs alias), taxonomies utilisées (`tlp`, `PAP`, `admiralty-scale`, `osint`, `misp`, `estimative-language`), **toutes** les warninglists, modèles d'objets, noticelists |
| **OpenCTI** | `make up-cti` puis `make attack-status` | MITRE ATT&CK par `connector-mitre` : ~1 600 techniques, ~190 groupes, ~850 malwares, ~1 200 mitigations, ~65 campagnes. C'est le référentiel sur lequel se raccrochent tous les rapports par `external_id` T1xxx |
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
ensemble saturent une machine modeste — deux cœurs physiques suffisent à peine
à porter les deux piles — et l'ATT&CK arrive au compte-gouttes.
`make up-cti` ne démarre donc que le cœur, MITRE et les ponts ; les flux
externes attendent `make opencti-feeds`. `make attack-status` dit où en est le
socle et refuse de vous laisser croire qu'il est prêt quand il ne l'est pas.

Les bundles VIGINUM sont **épinglés par SHA de commit** et téléchargés en
dry-run par défaut : le script contrôle la structure (objets sans id, relations
orphelines, marquages, types) et s'arrête ; `--yes` importe. Ils utilisent des
types propres à OpenCTI (`media-content`, `channel`, `narrative`) — du STIX
étendu, pas du STIX invalide, mais une validation en mode strict les rejette.

## Alimenter la plateforme

La plateforme ne moissonne rien et n'analyse rien. L'adressage se lit
directement dans les `.env` :

| Vers | Interface | Où trouver l'adressage |
|---|---|---|
| OpenCTI | bundle STIX 2.1 par le connecteur `import-file-stix` ou `stix2.import_bundle_from_file` (pycti) ; un `Report` par publication, étiqueté **`export-misp`** pour être repris par le pont retour et par la collection TAXII | `opencti/.env` → `OPENCTI_URL`, `OPENCTI_ADMIN_TOKEN` |
| MISP | feed MISP natif enregistré par l'API, ou event créé par l'API (PyMISP) | `opencti/.env` → `MISP_URL`, `MISP_KEY`, `MISP_ORG`, `MISP_VERIFY_SSL` |

Deux règles que la plateforme impose par construction : les events créés par
le pont retour sortent en distribution 1 et y restent (c'est le signal
anti-boucle), et un observable qu'un rapport porte déjà dans OpenCTI ne
s'importe pas une seconde fois dans MISP — il y arrive par le pont.

Ce qui ne voyage pas dans un bundle et se rejoue après un import :
`first_seen` / `last_seen` des entités (sinon OpenCTI laisse des valeurs
sentinelles, 1970 et 5138).

## Les deux piles

### OpenCTI — le graphe et les rapports

Démarrée par `make up-cti` (`opencti/docker-compose.yml`) : plateforme,
workers, et les connecteurs MITRE ATT&CK, CISA KEV, import-document,
import-file-stix, plus les deux ponts MISP.

### MISP — les observables

Démarrée par `make up-cti` (`vendor/misp-docker`, sous-module officiel, surcharges dans
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
contiennent — filtre `dynamicRegardingOf`). Feed MISP client et snapshot
initial sont produits par l'outillage d'alimentation, depuis les mêmes
bundles.

## Exploiter

| Besoin | Commande |
|---|---|
| construire toute la plateforme, dans l'ordre | `make build-cti HOST=<fqdn\|ip>` / `make build-cti DOMAINE=<domaine>` |
| démarrer | `make up-cti` (MISP+OpenCTI), `make up-ciso` |
| arrêter, avant extinction/reboot — conteneurs conservés | `make down-cti`, `make down-ciso` |
| détruire, volumes compris | `make destroy-cti`, `make destroy-ciso` (**perte totale**) |

`make help` n'affiche que ces cibles. Le reste (socle, pont, façade, diagnostics…)
tourne à l'intérieur de `make build-cti` et dans les cibles internes qu'il appelle —
détaillées dans les sections ci-dessus, lisibles dans le `Makefile` si besoin
de les rejouer une par une.

## Arborescence

| Chemin | Rôle |
|---|---|
| `Makefile` | toutes les commandes de la plateforme (`make help`) |
| `vendor/misp-docker/` | sous-module — stack Docker officielle MISP, non modifiée |
| `compose.tuning.yml`, `docker/` | overrides de la pile MISP (MariaDB, ports, noms de volumes) |
| `opencti/` | pile OpenCTI + connecteurs, dont les deux ponts MISP |
| `provisioning/_config.py` | adressage unique (URL et jetons lus dans les `.env`, surchargés par l'environnement) |
| `provisioning/build_platform.sh` | construction complète dans le bon ordre (`make build-cti`) |
| `provisioning/misp_socle.py`, `opencti_socle.py`, `attack_status.py` | socle des deux plateformes : référentiels MISP, ATT&CK, rapports STIX VIGINUM |
| `provisioning/bridge_setup.py`, `bridge_test.py`, `selftest/` | câblage et contrôle bout en bout du pont |
| `provisioning/prepare_host.sh`, `rootless_setup.sh` | préparation d'un hôte neuf : tout ce qui exige root, puis le démon rootless du compte |
| `provisioning/systemd/` | unité d'arrêt propre des piles à l'extinction (`make autostart`) |
| `proxy/traefik.yml`, `proxy/dynamic/dynamic.yml` | façade HTTPS à deux ou trois identités (`make build-cti DOMAINE=…`) |
| `ciso-assistant/docker-compose.yml` | CISO-Assistant (GRC), cycle de vie à part — `make up-ciso`, jamais `make build-cti` |
| `docs/SETUP.md`, `docs/DELIVERY.md` | installation ; ce qui est livré et comment |

## Sécurité

- `.env` et tout ce qui contient un secret est ignoré par git.
- Ne jamais committer de clé API, de mot de passe ni de jeton. Les outils
  Python ne codent aucune URL ni aucun jeton en dur : tout passe par
  `provisioning/_config.py`.
- Le certificat livré par la pile MISP est auto-signé et porte `CN=localhost`.
  Derrière la façade (`make build-cti DOMAINE=…`), c'est elle qui porte le TLS —
  autorité locale par défaut, certificat public par `make cert-manuel`. Sans
  façade, poser un certificat au nom de `HOST` avant tout usage réel.
- Le déploiement vise un démon Docker **rootless** : pas de groupe
  root-équivalent, et le socket appartient au seul compte qui porte la
  plateforme.
- Le dépôt ne contient aucune donnée de renseignement : seuls les référentiels
  publics (galaxies, taxonomies et warninglists MISP, MITRE ATT&CK, annexes
  STIX de VIGINUM) sont posés à la construction.
