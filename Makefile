SHELL := /bin/bash
DOCKER_DIR := vendor/misp-docker
ENV_FILE := $(DOCKER_DIR)/.env
PY := python3

# Accès au démon Docker. Le test porte sur une CAPACITÉ, pas sur une
# appartenance : sur un hôte ROOTLESS il n'existe pas de groupe `docker` — le
# socket appartient à l'utilisateur et `DOCKER_HOST` le désigne. Un test
# d'appartenance y est toujours faux et fait tomber les 15 cibles sur
# `sg docker -c`, qui réclame alors le mot de passe DU GROUPE et échoue sans
# terminal (« sg: getline() failed »). On demande donc au démon s'il répond.
# `sg docker -c` ne sert plus qu'au cas pour lequel il a été écrit : un
# `usermod -aG docker` sans reconnexion, où le groupe existe déjà dans
# /etc/group mais pas encore dans la session.
DOCKER_DIRECT := $(shell docker info >/dev/null 2>&1 && echo 1)
ifeq ($(DOCKER_DIRECT),1)
RUN := bash -c
else
RUN := sg docker -c
endif

# Deux projets compose, une seule plateforme. Les noms servent de préfixe aux
# conteneurs et aux réseaux ; les volumes, eux, portent un nom explicite fixé
# dans les compose (misp_bdd, opencti_bdd…), donc lisible dans `docker volume ls`.
# Changer ces noms sur une infra existante rend ses conteneurs orphelins : ne le
# faire qu'après un `make destroy` + `make opencti-destroy`.
# Sans --project-directory côté MISP : le dossier projet = celui du 1er -f
# (vendor/misp-docker), donc ses chemins relatifs (./configs, ./logs…) restent bons.
MISP_PROJECT  := cti-platform-misp
OCTI_PROJECT  := cti-platform-opencti

COMPOSE := CTI_PLATFORM_ROOT=$(CURDIR) docker compose -p $(MISP_PROJECT) --env-file $(ENV_FILE) \
	-f $(DOCKER_DIR)/docker-compose.yml -f compose.tuning.yml

OCTI := docker compose -p $(OCTI_PROJECT) --project-directory $(CURDIR)/opencti \
	--env-file $(CURDIR)/opencti/.env -f $(CURDIR)/opencti/docker-compose.yml

.DEFAULT_GOAL := help

.PHONY: help
help: ## Affiche cette aide
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

$(ENV_FILE):
	@$(MAKE) init

# Nom (FQDN) ou IP par lequel les CLIENTS joindront la plateforme. C'est LA
# valeur à fixer à la création de l'infra : elle aligne MISP (BASE_URL), OpenCTI
# (APP__BASE_URL) et l'URL publique affichée dans les rapports. Par défaut, le
# FQDN de la machine, sinon localhost.
HOST ?= $(shell hostname -f 2>/dev/null || echo localhost)
OCTI_ENV := opencti/.env

# Adresse que les CONTENEURS doivent viser pour joindre le nom public de la
# plateforme (`extra_hosts` des deux compose). Deux mondes, deux valeurs :
#   - rootful  : `host-gateway` désigne l'hôte depuis un conteneur ;
#   - ROOTLESS : `host-gateway` résout vers le pont docker0 de l'espace de noms
#     de RootlessKit, où RIEN n'écoute — les ports publiés le sont dans l'espace
#     de noms de l'HÔTE. Un conteneur doit alors viser l'adresse réelle de
#     l'hôte, qu'il atteint par sa sortie réseau normale.
# Détectée depuis HOST quand le démon est rootless, sinon `host-gateway`.
# Surchargeable dans tous les cas : make init HOST=… HOST_TARGET=192.168.0.40
ROOTLESS := $(shell docker info --format '{{range .SecurityOptions}}{{.}}{{end}}' 2>/dev/null | grep -qi rootless && echo 1)
ifeq ($(ROOTLESS),1)
HOST_TARGET ?= $(firstword $(shell getent hosts $(HOST) 2>/dev/null | awk '{print $$1; exit}') host-gateway)
else
HOST_TARGET ?= host-gateway
endif

# Mot de passe des COMPTES UTILISATEUR (admin MISP, admin OpenCTI) : ceux qu'on
# saisit dans les deux interfaces. Surchargeable : make init DEFAULT_PASSWORD='…'.
# Les secrets des briques d'infrastructure (MariaDB, Redis, MinIO, RabbitMQ) et
# les clés cryptographiques (ENCRYPTION_KEY, SALT, GPG, jetons, identifiants de
# connecteurs) restent tirés au hasard : ils ne se saisissent jamais.
DEFAULT_PASSWORD ?= MyP@ssword42!

# Dimensionnement mémoire, calculé à la création des .env. Les valeurs des
# .env.example visaient une machine de 31 Go dédiée à MISP ; ici les DEUX piles
# cohabitent (MariaDB + Elasticsearch + OpenCTI + workers + connecteurs), donc
# les 40 % de RAM d'un serveur MISP seul ne tiennent pas. Sur une machine plus
# petite, les valeurs d'origine font swapper puis tuer des conteneurs, sans que
# la cause soit lisible dans les journaux.
#   MariaDB : 20 % de la RAM, borné à [1 Go, 12 Go]
#   Elasticsearch (heap) : 25 %, borné à [2 Go, 8 Go]
# Surchargeables : make init HOST=... INNODB_POOL=4096M ELASTIC_MEM=3G
MEM_MO := $(shell awk '/^MemTotal:/{printf "%d", $$2/1024}' /proc/meminfo 2>/dev/null || echo 16384)
INNODB_POOL ?= $(shell m=$$(( $(MEM_MO) * 20 / 100 )); [ $$m -lt 1024 ] && m=1024; [ $$m -gt 12288 ] && m=12288; echo $${m}M)
ELASTIC_MEM ?= $(shell m=$$(( $(MEM_MO) / 4 / 1024 )); [ $$m -lt 2 ] && m=2; [ $$m -gt 8 ] && m=8; echo $${m}G)

# Organisation qui porte la plateforme, des DEUX côtés : org #1 de MISP
# (ADMIN_ORG) et valeur lue par les deux ponts (MISP_IMPORT_CREATOR_ORGS pour
# l'import, MISP_OWNER_ORG pour l'export). Si les deux divergent, MISP et
# OpenCTI ne se voient pas.
MISP_ORG ?= ruggdoll

# app:encryption_key d'OpenCTI (OPENCTI_ENCRYPTION_KEY) exige au moins 32
# OCTETS décodés depuis du base64 : une chaîne alphanumérique de 40 caractères
# n'en fait que 30 et la plateforme refuse de s'initialiser (CONFIGURATION_ERROR,
# conteneur qui redémarre en boucle en sortant avec le code 0, healthcheck qui
# ne passe jamais). D'où le 'openssl rand -base64 32' ci-dessous, à part de la
# boucle de secrets alphanumériques.

.PHONY: build
build: ## CONSTRUIT TOUTE LA PLATEFORME dans le bon ordre — make build HOST=<fqdn|ip>
	@HOST='$(HOST)' provisioning/build_platform.sh

.PHONY: init
init: ## Crée les .env des deux piles avec des secrets aléatoires — make init HOST=<fqdn|ip>
	@echo "Nom public de la plateforme (CTI_HOSTNAME) : $(HOST)"
	@if [ -f "$(ENV_FILE)" ]; then echo "  $(ENV_FILE) existe déjà — inchangé."; else \
	  cp .env.example "$(ENV_FILE)"; \
	  sed -i "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=$(DEFAULT_PASSWORD)|" "$(ENV_FILE)"; \
	  for key in GPG_PASSPHRASE ENCRYPTION_KEY SALT MYSQL_PASSWORD MYSQL_ROOT_PASSWORD REDIS_PASSWORD; do \
	    val=$$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40); \
	    sed -i "s|^$$key=.*|$$key=$$val|" "$(ENV_FILE)"; \
	  done; \
	  sed -i "s|^BASE_URL=.*|BASE_URL=https://$(HOST)|" "$(ENV_FILE)"; \
	  sed -i "s|^CTI_HOSTNAME=.*|CTI_HOSTNAME=$(HOST)|" "$(ENV_FILE)"; \
	  sed -i "s|^CTI_HOST_TARGET=.*|CTI_HOST_TARGET=$(HOST_TARGET)|" "$(ENV_FILE)"; \
	  sed -i "s|^INNODB_BUFFER_POOL_SIZE=.*|INNODB_BUFFER_POOL_SIZE=$(INNODB_POOL)   # dimensionné par make init sur $(MEM_MO) Mo de RAM|" "$(ENV_FILE)"; \
	  sed -i "s|^ADMIN_ORG=.*|ADMIN_ORG=$(MISP_ORG)|" "$(ENV_FILE)"; \
	  sed -i "s|^ADMIN_KEY=.*|ADMIN_KEY=$$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40)|" "$(ENV_FILE)"; \
	  echo "  $(ENV_FILE) généré (BASE_URL=https://$(HOST), org $(MISP_ORG))"; \
	fi
	@if [ -f "$(OCTI_ENV)" ]; then echo "  $(OCTI_ENV) existe déjà — inchangé."; else \
	  cp opencti/.env.example "$(OCTI_ENV)"; \
	  sed -i "s|^OPENCTI_ADMIN_PASSWORD=.*|OPENCTI_ADMIN_PASSWORD=$(DEFAULT_PASSWORD)|" "$(OCTI_ENV)"; \
	  for key in MINIO_ROOT_PASSWORD RABBITMQ_DEFAULT_PASS OPENCTI_HEALTHCHECK_ACCESS_KEY; do \
	    val=$$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40); \
	    sed -i "s|^$$key=.*|$$key=$$val|" "$(OCTI_ENV)"; \
	  done; \
	  sed -i "s|^OPENCTI_ENCRYPTION_KEY=.*|OPENCTI_ENCRYPTION_KEY=$$(openssl rand -base64 32)|" "$(OCTI_ENV)"; \
	  for key in OPENCTI_ADMIN_TOKEN $$(grep -oE '^CONNECTOR_[A-Z_]+_ID' opencti/.env.example | grep -v '_STREAM_ID$$'); do \
	    sed -i "s|^$$key=.*|$$key=$$($(PY) -c 'import uuid;print(uuid.uuid4())')|" "$(OCTI_ENV)"; \
	  done; \
	  sed -i "s|^OPENCTI_HOST=.*|OPENCTI_HOST=$(HOST)|" "$(OCTI_ENV)"; \
	  sed -i "s|^MISP_REFERENCE_URL=.*|MISP_REFERENCE_URL=https://$(HOST)|" "$(OCTI_ENV)"; \
	  sed -i "s|^CTI_HOST_TARGET=.*|CTI_HOST_TARGET=$(HOST_TARGET)|" "$(OCTI_ENV)"; \
	  sed -i "s|^ELASTIC_MEMORY_SIZE=.*|ELASTIC_MEMORY_SIZE=$(ELASTIC_MEM)|" "$(OCTI_ENV)"; \
	  sed -i "s|^MISP_IMPORT_FROM_DATE=.*|MISP_IMPORT_FROM_DATE=$$(date +%F)|" "$(OCTI_ENV)"; \
	  sed -i "s|^MISP_ORG=.*|MISP_ORG=$(MISP_ORG)|" "$(OCTI_ENV)"; \
	  sed -i "s|^MISP_KEY=.*|MISP_KEY=$$(grep -E '^ADMIN_KEY=' "$(ENV_FILE)" | cut -d= -f2)|" "$(OCTI_ENV)"; \
	  echo "  $(OCTI_ENV) généré (OPENCTI_HOST=$(HOST), org $(MISP_ORG), pont MISP en forward-only depuis aujourd'hui)"; \
	fi
	@echo "  Mémoire ($(MEM_MO) Mo) : buffer pool MariaDB $(INNODB_POOL), heap Elasticsearch $(ELASTIC_MEM)"
	@echo "  Cible extra_hosts des conteneurs (CTI_HOST_TARGET) : $(HOST_TARGET)$(if $(ROOTLESS), — démon rootless détecté,)"
	@case "$(HOST_TARGET)" in 127.*) echo "  ATTENTION : CTI_HOST_TARGET est une adresse de loopback. Un conteneur n'y joindra pas l'hôte."; echo "  Corriger /etc/hosts (le nom public doit pointer sur l'IP du LAN) ou passer HOST_TARGET=<ip> explicitement.";; esac
	@echo "→ MISP    : https://$(HOST)      (admin@… / $(DEFAULT_PASSWORD))"
	@echo "→ OpenCTI : http://$(HOST):8080  (admin@… / $(DEFAULT_PASSWORD))"
	@echo "  La clé API admin MISP est propagée dans $(OCTI_ENV) (MISP_KEY). Un outil d'alimentation"
	@echo "  y lit MISP_KEY et OPENCTI_ADMIN_TOKEN — ou reçoit une clé d'automation MISP dédiée."
	@echo "  Suite : make up -> make opencti-up -> make bridge-setup"
	@echo "  Pour n'écouter que sur le poste local : BIND_ADDRESS=127.0.0.1 dans les deux .env (défaut 0.0.0.0)."

.PHONY: up
up: $(ENV_FILE) ## Démarre la stack MISP (build/pull au 1er lancement)
	$(RUN) '$(COMPOSE) up -d'
	@echo "MISP démarre… suivre avec 'make logs'. Prêt quand le healthcheck misp-core passe."

.PHONY: down
down: ## Arrête la stack (conserve les volumes)
	$(RUN) '$(COMPOSE) down'

.PHONY: destroy
destroy: ## Arrête, supprime les volumes ET l'état monté en bind (perte totale)
	@# vendor/misp-docker/{configs,logs,files,ssl,gnupg} sont des montages bind
	@# gitignorés : ils SURVIVENT à 'down -v'. Or configs/database.php garde le
	@# mot de passe MySQL du déploiement précédent — un 'make init' + 'make up'
	@# suivant repart alors sur une base neuve avec l'ancien secret et misp-core
	@# ne peut plus se connecter ("Access denied for user 'misp'"). On les vide
	@# dans un conteneur root (ces dossiers appartiennent à www-data), AVANT le
	@# 'down -v' : lancer un conteneur après recréerait les volumes supprimés.
	@$(RUN) '$(COMPOSE) run --rm --no-deps --user root --entrypoint sh misp-core -c \
	  "rm -rf /var/www/MISP/app/Config/* /var/www/MISP/app/tmp/logs/* /var/www/MISP/app/files/* \
	          /etc/nginx/certs/* /var/www/MISP/.gnupg/* || true"' >/dev/null 2>&1 || true
	$(RUN) '$(COMPOSE) down -v --remove-orphans'
	@echo "état MISP purgé (volumes + configs/logs/files/ssl/gnupg)"

.PHONY: logs
logs: ## Suit les logs de misp-core
	$(RUN) '$(COMPOSE) logs -f misp-core'

.PHONY: ps
ps: ## État des conteneurs
	$(RUN) '$(COMPOSE) ps'

.PHONY: shell
shell: ## Shell dans le conteneur misp-core
	$(RUN) '$(COMPOSE) exec misp-core bash'

.PHONY: socle-misp
socle-misp: ## SOCLE MISP : galaxies, taxonomies, warninglists, modèles d'objets (avant tout flux)
	./.venv/bin/python provisioning/misp_socle.py $(ARGS)

.PHONY: admin-key
admin-key: ## Affiche la clé API du compte admin
	@$(RUN) '$(COMPOSE) exec -T misp-core sudo -u www-data /var/www/MISP/app/Console/cake user change_authkey $(shell grep -E "^ADMIN_EMAIL=" $(ENV_FILE) 2>/dev/null | cut -d= -f2)' | tail -1

.PHONY: misp-setup
misp-setup: ## ROTATION : régénère la clé API admin, la repose dans les .env, réaligne l'org
	@key=$$($(RUN) '$(COMPOSE) exec -T misp-core sudo -u www-data /var/www/MISP/app/Console/cake user change_authkey $(shell grep -E "^ADMIN_EMAIL=" $(ENV_FILE) 2>/dev/null | cut -d= -f2)' | grep -oE '[a-zA-Z0-9]{40}' | tail -1); \
	  test -n "$$key" || { echo "clé introuvable — MISP est-il prêt ? (make logs)"; exit 1; }; \
	  sed -i "s|^MISP_KEY=.*|MISP_KEY=$$key|" $(OCTI_ENV); \
	  echo "  MISP_KEY posée dans $(OCTI_ENV) — à reporter dans la configuration des outils d'alimentation"
	./.venv/bin/python provisioning/misp_org.py
	@echo "→ ensuite : make opencti-up puis make bridge-setup"

.PHONY: venv
venv: ## Crée l'environnement Python (.venv) des outils de la plateforme
	$(PY) -m venv .venv
	./.venv/bin/pip install -q -U pip -r provisioning/requirements.txt
	@echo "→ activer avec: source .venv/bin/activate"


.PHONY: diag-rootless
diag-rootless: ## DIAGNOSTIQUE l'hôte (rootless, pilote de stockage, MinIO, ports privilégiés) — ne modifie rien
	bash provisioning/diag_rootless.sh

.PHONY: minio-droits
minio-droits: ## RÉPARE les droits du volume de fichiers MinIO quand il refuse d'écrire (ARGS=<uid>:<gid>)
	@# Un volume Docker neuf appartient à root:root. Si le processus MinIO de
	@# l'image tourne sous un autre compte — image récente, démon en mode
	@# rootless, ou remappage d'espace de noms utilisateur — il ne peut rien y
	@# écrire et rend « file access denied, drive may be faulty ». La reprise en
	@# main se fait par un conteneur root jetable : elle ne demande AUCUN droit
	@# root sur l'hôte, l'appartenance au groupe docker suffit.
	@vol=$$(docker volume ls -q --filter name=opencti_fichiers | head -1); \
	test -n "$$vol" || { echo "volume opencti_fichiers absent — rien à réparer"; exit 1; }; \
	cible=$${ARGS:-$$(docker image inspect $$(docker compose -p cti-platform-opencti --project-directory $(PWD)/opencti --env-file $(PWD)/opencti/.env -f $(PWD)/opencti/docker-compose.yml config --images 2>/dev/null | grep -i minio | head -1) --format '{{.Config.User}}' 2>/dev/null)}; \
	cible=$${cible:-0:0}; \
	echo "appropriation de $$vol par $$cible"; \
	docker run --rm -v $$vol:/data alpine:3 sh -c "chown -R $$cible /data && ls -ld /data"

.PHONY: opencti-up
opencti-up: ## démarre le stack OpenCTI (Phase 4) — ~12 Go RAM
	@test -f opencti/.env || { echo "opencti/.env absent — lancer 'make init HOST=<fqdn|ip>'"; exit 1; }
	$(RUN) '$(OCTI) up -d'
	@echo "→ $$(grep -E '^OPENCTI_EXTERNAL_SCHEME=' opencti/.env | cut -d= -f2)://$$(grep -E '^OPENCTI_HOST=' opencti/.env | cut -d= -f2):$$(grep -E '^OPENCTI_PORT=' opencti/.env | cut -d= -f2) (admin : voir opencti/.env). Premier boot ~5-10 min."

.PHONY: opencti-feeds
opencti-feeds: ## démarre les connecteurs de flux (profil `feeds`) — APRÈS que l'ATT&CK soit en base
	$(RUN) '$(OCTI) --profile feeds up -d'
	@echo "→ flux démarrés. Suivre l'ingestion : make attack-status"

.PHONY: attack-status
attack-status: ## état du socle ATT&CK en base + file d'ingestion restante
	@./.venv/bin/python provisioning/attack_status.py

.PHONY: socle-opencti
socle-opencti: ## SOCLE OpenCTI : rapports STIX publics VIGINUM (après l'ATT&CK) — --yes pour pousser
	./.venv/bin/python provisioning/opencti_socle.py $(ARGS)

.PHONY: socle-all
socle-all: ## SOCLE MISP puis SOCLE OpenCTI, l'un après l'autre — pré-requis : les deux piles up, ATT&CK chargé (make attack-status)
	$(MAKE) --no-print-directory socle-misp
	$(MAKE) --no-print-directory socle-opencti ARGS=--yes

.PHONY: bridge-setup
bridge-setup: ## câble le pont OpenCTI -> MISP (label export-misp + live stream + .env)
	./.venv/bin/python provisioning/bridge_setup.py $(ARGS)

.PHONY: bridge-test
bridge-test: ## contrôle bout en bout : crée un rapport DANS OpenCTI, le cherche dans MISP, puis nettoie (ARGS=--keep pour conserver)
	./.venv/bin/python provisioning/bridge_test.py $(ARGS)

.PHONY: opencti-down
opencti-down: ## arrête le stack OpenCTI (volumes conservés)
	@# --profile feeds : sans lui, les connecteurs de flux survivent à l'arrêt
	$(RUN) '$(OCTI) --profile feeds down'

.PHONY: opencti-destroy
opencti-destroy: ## Arrête OpenCTI ET supprime ses volumes (ES, MinIO, RabbitMQ, Redis)
	@# --profile feeds : sans lui, les connecteurs de flux survivent à l'arrêt
	$(RUN) '$(OCTI) --profile feeds down -v'

.PHONY: opencti-logs
opencti-logs: ## suit les logs OpenCTI
	$(RUN) '$(OCTI) logs -f --tail=100'

.PHONY: opencti-ps
opencti-ps: ## état des conteneurs OpenCTI
	$(RUN) '$(OCTI) ps'


.PHONY: taxii-check
taxii-check: ## teste la collection TAXII 2.1 avec un client standard (pagination, validité STIX, intégrité des refs)
	./.venv/bin/python provisioning/taxii_check.py $(ARGS)
