# Pont MISP → OpenCTI : périmètre

Le connecteur `connector-misp` (compose `opencti/docker-compose.yml`) ne déverse
**pas** tout MISP dans OpenCTI. OpenCTI est le graphe de connaissance
(acteurs, campagnes, TTP, rapports contextualisés) ; MISP reste le système de
référence des IOC et alimente la détection.

## État : forward-only (2026-09-03)

`MISP_IMPORT_FROM_DATE=2026-09-03`, `MISP_CREATE_TAGS_AS_LABELS=false`,
`MISP_GUESS_THREATS_FROM_TAGS=false`.

Le backfill historique complet (tous les events antérieurs) **n'est pas en
place** : sur la machine actuelle (4 cœurs, ES 4 Go), l'ingestion des gros
events s'effondre. Chaque event importé crée un Report dont les `object_refs`
génèrent des milliers de méta-relations ; le connecteur pré-découpe le bundle en
messages unitaires et le churn create/delete de ces object_refs sature ES
(index `stix_meta_relationships`) — le débit tombe à ~2 entités/s et la file
RabbitMQ diverge. Constaté le 2026-09-03 : file montée à 170 k messages, comptes
figés, ~580 k tombstones dans `stix_meta_relationships`.

Pistes pour le backfill (à trancher) :
- export STIX ciblé depuis MISP par event, import fichier dans OpenCTI hors connecteur ;
- job batch lent (1 worker, 1 event / N minutes) hors heures de prod ;
- plus de RAM/cœurs pour ES + `ELASTIC_MEMORY_SIZE` à 8 Go.

## Filtres actifs (`MISP_IMPORT_TAGS_NOT`)

| Tag exclu | Raison |
|---|---|
| `osint:source-type="block-or-filter-list"` | blocklists / warninglists — volume élevé, valeur analytique nulle dans le graphe |
| `source:Infoblox` | feed DNS massif (~120 k attributs) |
| `cti-platform:opencti-bridge="skip"` | events > 4000 attributs : dumps d'IOC bruts (dépôts GitHub éditeurs, trackers C2) |

Autres bornes : `MISP_IMPORT_CREATOR_ORGS=ruggdoll`,
`MISP_IMPORT_DISTRIBUTION_LEVELS=1,2,3`, `MISP_GUESS_THREATS_FROM_TAGS=false`
(la corrélation attribut×galaxie explose en O(n²) sur les gros events).

## Events tagués `opencti-bridge="skip"` (2026-09-03)

Talos, Unit 42 (Article Information + timely), SophosLabs, RedDrip7/QiAnXin,
Neo23x0 signature-base, CyberCrime Tracker, PRODAFT, Fox-IT Cobalt Strike,
AlienVault OTX, WithSecure, Netskope, Sekoia, Infoblox.

Ces IOC restent consultables dans MISP. Pour en pousser un précis dans OpenCTI :
retirer le tag de l'event puis `resetStateConnector`, ou export STIX ciblé.

## Rejouer le pont à neuf

```sh
docker compose -p cti-platform-opencti stop connector-misp
docker exec cti-platform-opencti-rabbitmq-1 rabbitmqctl purge_queue push_<CONNECTOR_MISP_ID>
# mutation resetStateConnector(id: "<CONNECTOR_MISP_ID>") via GraphQL
docker compose -p cti-platform-opencti up -d connector-misp
```
