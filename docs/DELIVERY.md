# Livraison — ce que reçoit un client, et comment

Le produit est un **flux que le client ingère chez lui** (OpenCTI, MISP ou tout
client TAXII 2.1), jamais un accès à cette instance (4 cœurs, ~400 entités/min,
non mutualisable). Trois livrables, tous produits depuis les mêmes bundles
STIX importés dans OpenCTI par l'outillage d'alimentation (un `Report` par publication, étiqueté `export-misp`).

## 1. Abonnement : collection TAXII 2.1 (OpenCTI)

| Élément | Valeur |
|---|---|
| Serveur TAXII | `<APP__BASE_URL>/taxii2/` (découverte), API root `<APP__BASE_URL>/taxii2/root/` |
| Collection | `ruggdoll — Rapports (export-misp)` — id `1d54afb1-2cbc-4d06-8063-e3c6b36e4712` |
| Objets | `<root>/collections/<id>/objects?limit=500` ; pagination par `next` ; `added_after=<ISO8601>` pour l'incrémental ; `match[type]=indicator` etc. |
| Authentification | `Authorization: Bearer <token OpenCTI>` — un **utilisateur OpenCTI dédié par client**, rôle lecture seule, ajouté aux `authorized_members` de la collection (`taxii_public=false`) |
| Média | `application/stix+json;version=2.1` |

**Filtre de la collection** (Data sharing → TAXII collections) : union de
`entity_type = Report AND objectLabel = export-misp` **et** de
`dynamicRegardingOf(relationship_type = object, Report AND label export-misp)`,
c'est-à-dire les rapports **plus tout ce qu'ils contiennent** (entités,
observables, indicateurs, relations). Sans la seconde branche, OpenCTI ne sert
que les objets `report` avec des `object_refs` pendants — vérifié le
2026-09-07 (collection initiale : 50 reports/page, 0 ref résolue).

Mesure du 2026-09-07 (`make taxii-check`, client `taxii2-client` + validation
`stix2`) : 51 808 objets en 104 pages (~4 min), collecte complète, 0 relation
à extrémité manquante, 1 `object_refs` non servi (une marking-definition,
attendu). Objets rejetés par la validation stricte `stix2` : `location` sans
`country`/`region` (specs à corriger) et relations `stop_time == start_time`
(builder corrigé le 2026-09-07, prise en compte au prochain rebuild).

Côté client OpenCTI : connecteur `opencti/connector-taxii2` pointé sur l'API
root + id de collection + token. Test depuis un OpenCTI vierge : **non fait**
(12 Go RAM nécessaires en plus sur cette machine) — à faire sur une VM avant
la première vente ; le test client standard ci-dessus couvre le protocole et
la cohérence du contenu.

## 2. Feed MISP

Produit par l'outillage d'alimentation, depuis MISP :

- **publie** dans MISP les events créés par le pont OpenCTI → MISP
  (`connector-misp-intel` : org `ruggdoll`, distribution 1, aucun tag
  `cti-platform:source=`), qui sortent non publiés du connecteur ;
- écrit `dist/misp-feed/` au format feed MISP (`manifest.json`, `hashes.csv`,
  un `<uuid>.json` par event, `SOURCES.md`) avec :
  - tous les events **rapports** (≈ 1 030 au 2026-09-07) ;
  - les events importateurs ruggdoll dont l'archétype est « connaissance »
    (`cert-national`, `vendor-research`, `vendor-regional`, `vendor-repo`,
    `blog-*`, `vuln-catalog`, `mobile`) **et** dont la licence autorise la
    redistribution commerciale (`yes` ou `attribution` dans le registre de
    licences de l'outillage d'alimentation).
- Les events restent en **distribution 1 dans MISP** (c'est le signal anti-boucle
  de `MISP_IMPORT_DISTRIBUTION_LEVELS=0,3` côté `connector-misp`) ; le feed est
  écrit **sans champ distribution** : le MISP client applique la distribution
  qu'il configure sur le feed.
- **Hors feed, par construction** : feeds MISP par défaut (CIRCL, CUDESO,
  Botvrij…), blocklists brutes (CERT.pl, MetaMask, polkadot, IPSUM, DROP…),
  abuse.ch (conditions Spamhaus), ransomware.live, OTX, Pulsedive, ORKL, et
  toute source dont la licence ne le permet pas (registre de licences tenu par l'outillage d'alimentation).

Côté client : Sync Actions → Feeds → Add, source format `misp`, URL du dossier
servi en HTTP (ou chemin local), puis *Fetch and store all feed data*. Test dans
un MISP vierge : **à faire** (stack misp-docker secondaire, ~3 Go RAM).

## 3. Accès initial : snapshot

Archive produite par l'outillage d'alimentation :

```
bundles/<SOURCE>/<slug>.json   un bundle STIX 2.1 par rapport
misp-feed/                     le feed MISP ci-dessus
LICENSES.md  DELIVERY.md       conditions de redistribution et mode d'emploi (ce document)
README.md                      inventaire généré (rapports par source, objets par type)
```

Import OpenCTI : Data → Import → chaque bundle (ou dépôt dans le dossier
surveillé du connecteur `import-file-stix`). La recette est versionnée,
l'archive ne l'est pas (`dist/` ignoré).

## 4. Cadence et contrôle

- Nouveaux rapports : quotidien à hebdomadaire, poussés par l'outillage
  d'alimentation.
- Maintenance : le pont MISP réimporte parfois ses propres exports (cause non
  élucidée côté connecteur) et laisse une référence externe interne sur les
  Reports — à retirer par l'API ; feed MISP après chaque lot ; snapshot à
  chaque nouvel abonné.
- Avant vente : relecture humaine par échantillon, test d'ingestion depuis OpenCTI et MISP vierges, résolution
  des sources à licence non établie, registre RGPD (voir `LICENSES.md`).
