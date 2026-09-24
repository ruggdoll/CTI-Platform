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
CISO_PROJECT  := cti-platform-ciso

COMPOSE := CTI_PLATFORM_ROOT=$(CURDIR) docker compose -p $(MISP_PROJECT) --env-file $(ENV_FILE) \
	-f $(DOCKER_DIR)/docker-compose.yml -f compose.tuning.yml

# Le profil `proxy` s'active depuis le .env et non depuis la ligne de commande :
# une fois la façade configurée, TOUTE cible OpenCTI l'embarque — y compris
# lancée seule des mois plus tard, sans avoir à se souvenir d'un argument.
PROFIL_PROXY := $(shell grep -qsE '^MISP_HOSTNAME=.+' $(CURDIR)/opencti/.env && echo '--profile proxy')

OCTI := docker compose -p $(OCTI_PROJECT) --project-directory $(CURDIR)/opencti \
	--env-file $(CURDIR)/opencti/.env $(PROFIL_PROXY) -f $(CURDIR)/opencti/docker-compose.yml

# CISO-Assistant (GRC) : à côté de MISP/OpenCTI, cycle de vie à part — voir
# CISO_HOSTNAME plus bas. Son propre projet compose, jamais dans le périmètre
# de make build/destroy/backup_infra.sh.
CISO := docker compose -p $(CISO_PROJECT) --project-directory $(CURDIR)/ciso-assistant \
	--env-file $(CURDIR)/ciso-assistant/.env -f $(CURDIR)/ciso-assistant/docker-compose.yml

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
# DEUX MODES DE PUBLICATION.
#
#   make build HOST=<fqdn|ip>     une seule façade : chaque pile publie ses
#                                 propres ports (MISP en 443, OpenCTI en 8080).
#   make build DOMAINE=<domaine>  un PROXY INVERSE devant les deux, sous deux
#                                 identités : misp.<domaine> et opencti.<domaine>.
#                                 Les piles n'écoutent plus que sur la boucle
#                                 locale ; le proxy (Traefik) tient 80 et 443,
#                                 termine le TLS avec un certificat mkcert
#                                 (autorité locale posée sur l'hôte) et les
#                                 joint par le réseau Docker.
#
# Le proxy n'existe que pour l'EXTÉRIEUR. Les échanges internes — connecteurs
# vers OpenCTI, OpenCTI vers Elasticsearch, pont MISP — passent par les noms de
# conteneurs et ne le traversent pas.
DOMAINE ?=
ifneq ($(DOMAINE),)
MISP_HOSTNAME    ?= misp.$(DOMAINE)
OPENCTI_HOSTNAME ?= opencti.$(DOMAINE)
# CISO-Assistant (GRC) : à côté de MISP/OpenCTI, aucun échange de données
# avec elles — cycle de vie à part (sa donnée mérite sa propre politique de
# sauvegarde/rétention). Ne partage que la façade, par confort : `make build`
# ne la construit JAMAIS ; `make ciso-up` la démarre seule, volontairement,
# quand on le décide.
CISO_HOSTNAME    ?= ciso.$(DOMAINE)
HOST             := $(MISP_HOSTNAME)
endif

HOST ?= $(shell hostname -f 2>/dev/null || echo localhost)
OCTI_ENV := opencti/.env
CISO_ENV := ciso-assistant/.env

# URL publiques affichées. En mode proxy, OpenCTI n'est plus sur un port mais
# sur sa propre identité en 443 — l'annoncer faux enverrait l'exploitant sur
# une adresse morte. Récursives (=) : HOST et les noms sont définis au-dessus.
ifneq ($(DOMAINE),)
URL_MISP = https://$(MISP_HOSTNAME)
URL_OCTI = https://$(OPENCTI_HOSTNAME)
URL_CISO = https://$(CISO_HOSTNAME)
else
URL_MISP = https://$(HOST)
URL_OCTI = http://$(HOST):8080
endif

# Adresse que les CONTENEURS doivent viser pour joindre le nom public de la
# plateforme (`extra_hosts` des deux compose). Deux mondes, deux valeurs :
#   - rootful  : `host-gateway` désigne l'hôte depuis un conteneur ;
#   - ROOTLESS : `host-gateway` résout vers le pont docker0 de l'espace de noms
#     de RootlessKit, où RIEN n'écoute — les ports publiés le sont dans l'espace
#     de noms de l'HÔTE. Un conteneur doit alors viser l'adresse réelle de
#     l'hôte, qu'il atteint par sa sortie réseau normale.
# Détectée depuis HOST quand le démon est rootless, sinon `host-gateway`.
# Surchargeable dans tous les cas : make init HOST=<fqdn> HOST_TARGET=<ip de l’hôte>
# `ahostsv4`, pas `hosts` : ce dernier interroge aussi le DNS public pour l'AAAA
# quand /etc/hosts (écrit par prepare_host.sh) ne porte qu'une ligne IPv4 —
# et la renvoie en premier (préférence IPv6 de la résolution système), une
# adresse PUBLIQUE potentiellement injoignable depuis l'intérieur du réseau
# rootless, à la place du LAN local qu'on vient d'y écrire (constaté :
# HOST_TARGET visant l'IPv6 publique du domaine plutôt que le LAN, 2026-09-24).
# Le serveur n'a pas à dépendre du DNS public pour se joindre lui-même — IPv4
# et 'files' d'abord (nsswitch), jamais le DNS pour cet usage interne.
ROOTLESS := $(shell docker info --format '{{range .SecurityOptions}}{{.}}{{end}}' 2>/dev/null | grep -qi rootless && echo 1)
ifeq ($(ROOTLESS),1)
HOST_TARGET ?= $(firstword $(shell getent ahostsv4 $(HOST) 2>/dev/null | awk '{print $$1; exit}') host-gateway)
else
HOST_TARGET ?= host-gateway
endif

# Mot de passe des COMPTES UTILISATEUR (admin MISP, admin OpenCTI) : ceux qu'on
# saisit dans les deux interfaces. Surchargeable : make init DEFAULT_PASSWORD='…'.
# Les secrets des briques d'infrastructure (MariaDB, Redis, MinIO, RabbitMQ) et
# les clés cryptographiques (ENCRYPTION_KEY, SALT, GPG, jetons, identifiants de
# connecteurs) restent tirés au hasard : ils ne se saisissent jamais.
DEFAULT_PASSWORD ?= MyP@ssword42!

# Délai laissé aux deux piles pour se fermer proprement à l'extinction (unité
# posée par `make autostart`). MariaDB doit vider son buffer pool et
# Elasticsearch écrire son translog ; les 15 s par défaut de dockerd les
# tueraient en pleine écriture. Plafonné par le TimeoutStopSec de
# user@<uid>.service, que prepare_host.sh porte à 300 s.
AUTOSTART_TIMEOUT ?= 300

# Délai accordé à CHAQUE conteneur pour s'arrêter de lui-même avant le SIGKILL.
# `docker compose stop` n'en accorde que 10 par défaut : trop peu pour MariaDB,
# qui doit vider son buffer pool, et pour Elasticsearch, qui écrit son translog.
# Le TimeoutStopSec de l'unité systemd ne corrige PAS cela — il plafonne la
# durée TOTALE de l'arrêt, pas le sursis de chaque conteneur. Sans ce -t, le
# journal affiche « Container failed to exit within 10s of signal 15 - using
# the force » et l'unité d'arrêt propre ne sert à rien (constaté au
# redémarrage du 2026-09-15).
STOP_TIMEOUT ?= 120

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

# TRUST_STORES=none devant chaque appel à mkcert, en mode DOMAINE : le SERVEUR
# n'a pas besoin de faire confiance à sa propre autorité (il n'y a pas de
# navigateur ici, seulement l'émission du certificat). VIDE ("TRUST_STORES=")
# ne suffit PAS — mkcert le traite comme absent et installe quand même dans le
# magasin système par défaut, via un sudo update-ca-certificates interactif qui
# bloque un `make init`/`build` sans terminal (constaté le 2026-09-24). Seule
# une valeur explicite ("none", n'appartenant à aucun magasin réel) coupe tout.
.PHONY: init
init: ## Crée les .env des deux piles avec des secrets aléatoires — make init HOST=<fqdn|ip>
	@if [ -z "$(DOMAINE)" ] && [ "$(HOST)" != "localhost" ] && ! echo '$(HOST)' | grep -q '\.'; then \
	  echo "  ATTENTION : HOST=$(HOST) ne contient pas de point — ni FQDN, ni IP, ni 'localhost'."; \
	  echo "    Si c'est un nom de machine local (résolu par /etc/hosts, NetBIOS…), vos clients"; \
	  echo "    ne le résoudront probablement PAS. Il faut le FQDN ou l'IP RÉELS par lesquels ils"; \
	  echo "    joindront la plateforme — ou 'make build DOMAINE=<domaine>' pour une façade HTTPS"; \
	  echo "    à plusieurs identités (misp./opencti./ciso.<domaine>)."; \
	fi
	@echo "Nom public de la plateforme (CTI_HOSTNAME) : $(HOST)"
	@if [ -f "$(ENV_FILE)" ]; then \
	  if [ -n "$(DOMAINE)" ] && ! grep -qsE '^BIND_ADDRESS=127\.0\.0\.1' "$(ENV_FILE)"; then \
	    echo "  ATTENTION : $(ENV_FILE) existe déjà, généré SANS façade (mode HOST)."; \
	    echo "    make init ne modifie jamais un .env existant — passer en mode"; \
	    echo "    DOMAINE=$(DOMAINE) sur une plateforme déjà construite exige de repartir de"; \
	    echo "    zéro (secrets et ports diffèrent) : make opencti-destroy && make destroy &&"; \
	    echo "    rm vendor/misp-docker/.env opencti/.env ciso-assistant/.env && make build DOMAINE=$(DOMAINE)"; \
	  fi; \
	  echo "  $(ENV_FILE) existe déjà — inchangé."; \
	else \
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
	  if [ -n "$(DOMAINE)" ]; then \
	    sed -i "s|^BIND_ADDRESS=.*|BIND_ADDRESS=127.0.0.1|" "$(ENV_FILE)"; \
	    sed -i "s|^CORE_HTTP_PORT=.*|CORE_HTTP_PORT=8081|" "$(ENV_FILE)"; \
	    sed -i "s|^CORE_HTTPS_PORT=.*|CORE_HTTPS_PORT=8444|" "$(ENV_FILE)"; \
	    sed -i "s|^DISABLE_SSL_REDIRECT=.*|DISABLE_SSL_REDIRECT=true|" "$(ENV_FILE)"; \
	  fi; \
	  echo "  $(ENV_FILE) généré (BASE_URL=https://$(HOST), org $(MISP_ORG))"; \
	fi
	@if [ -f "$(OCTI_ENV)" ]; then \
	  if [ -n "$(DOMAINE)" ] && ! grep -qsE '^MISP_HOSTNAME=' "$(OCTI_ENV)"; then \
	    echo "  ATTENTION : $(OCTI_ENV) existe déjà, généré SANS façade (mode HOST)."; \
	    echo "    make init ne modifie jamais un .env existant — passer en mode"; \
	    echo "    DOMAINE=$(DOMAINE) sur une plateforme déjà construite exige de repartir de"; \
	    echo "    zéro (secrets et ports diffèrent) : make opencti-destroy && make destroy &&"; \
	    echo "    rm vendor/misp-docker/.env opencti/.env ciso-assistant/.env && make build DOMAINE=$(DOMAINE)"; \
	  fi; \
	  echo "  $(OCTI_ENV) existe déjà — inchangé."; \
	else \
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
	  if [ -n "$(DOMAINE)" ]; then \
	    sed -i "s|^BIND_ADDRESS=.*|BIND_ADDRESS=127.0.0.1|" "$(OCTI_ENV)"; \
	    sed -i "s|^OPENCTI_HOST=.*|OPENCTI_HOST=$(OPENCTI_HOSTNAME)|" "$(OCTI_ENV)"; \
	    sed -i "s|^OPENCTI_EXTERNAL_SCHEME=.*|OPENCTI_EXTERNAL_SCHEME=https|" "$(OCTI_ENV)"; \
	    sed -i "s|^OPENCTI_BASE_URL=.*|OPENCTI_BASE_URL=https://$(OPENCTI_HOSTNAME)|" "$(OCTI_ENV)"; \
	    printf '\n# Façade HTTPS — renseigné par make init DOMAINE=%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
	      "$(DOMAINE)" "DOMAINE=$(DOMAINE)" "MISP_HOSTNAME=$(MISP_HOSTNAME)" "OPENCTI_HOSTNAME=$(OPENCTI_HOSTNAME)" \
	      "PROXY_BIND=0.0.0.0" "PROXY_HTTP_PORT=80" "PROXY_HTTPS_PORT=443" \
	      "PROXY_TLS_CERT=/certs-mkcert/cert.pem" "PROXY_TLS_KEY=/certs-mkcert/key.pem" \
	      "CISO_HOSTNAME=$(CISO_HOSTNAME)" >> "$(OCTI_ENV)"; \
	    command -v mkcert >/dev/null 2>&1 || { echo "  mkcert introuvable — apt install mkcert (ou relancer prepare_host.sh --domaine)"; exit 1; }; \
	    TRUST_STORES=none mkcert -install >/dev/null; \
	    TRUST_STORES=none mkcert -cert-file proxy/certs/cert.pem -key-file proxy/certs/key.pem "$(DOMAINE)" "*.$(DOMAINE)"; \
	  fi; \
	  echo "  $(OCTI_ENV) généré (OPENCTI_HOST=$(HOST), org $(MISP_ORG), pont MISP en forward-only depuis aujourd'hui)"; \
	fi
	@if [ -n "$(DOMAINE)" ]; then \
	  if [ -f "$(CISO_ENV)" ]; then echo "  $(CISO_ENV) existe déjà — inchangé."; else \
	    printf '%s\n' "CISO_HOSTNAME=$(CISO_HOSTNAME)" > "$(CISO_ENV)"; \
	    echo "  $(CISO_ENV) généré — cycle de vie à part, PAS construite par 'make build' : 'make ciso-up' pour la démarrer"; \
	  fi; \
	fi
	@if [ -n "$(DOMAINE)" ]; then \
	  echo "  Proxy inverse : https://$(MISP_HOSTNAME) et https://$(OPENCTI_HOSTNAME)"; \
	  echo "  Les piles n'écoutent que sur 127.0.0.1 ; la façade tient 80 et 443."; \
	fi
	@echo "  Mémoire ($(MEM_MO) Mo) : buffer pool MariaDB $(INNODB_POOL), heap Elasticsearch $(ELASTIC_MEM)"
	@echo "  Cible extra_hosts des conteneurs (CTI_HOST_TARGET) : $(HOST_TARGET)$(if $(ROOTLESS), — démon rootless détecté,)"
	@case "$(HOST_TARGET)" in 127.*) echo "  ATTENTION : CTI_HOST_TARGET est une adresse de loopback. Un conteneur n'y joindra pas l'hôte."; echo "  Corriger /etc/hosts (le nom public doit pointer sur l'IP du LAN) ou passer HOST_TARGET=<ip> explicitement.";; esac
	@echo "→ MISP    : $(URL_MISP)      (admin@… / $(DEFAULT_PASSWORD))"
	@echo "→ OpenCTI : $(URL_OCTI)  (admin@… / $(DEFAULT_PASSWORD))"
	@echo "  La clé API admin MISP est propagée dans $(OCTI_ENV) (MISP_KEY). Un outil d'alimentation"
	@echo "  y lit MISP_KEY et OPENCTI_ADMIN_TOKEN — ou reçoit une clé d'automation MISP dédiée."
	@echo "  Suite : make up -> make opencti-up -> make bridge-setup"
	@echo "  Pour n'écouter que sur le poste local : BIND_ADDRESS=127.0.0.1 dans les deux .env (défaut 0.0.0.0)."

.PHONY: up
up: $(ENV_FILE) ## Démarre la stack MISP (build/pull au 1er lancement)
	$(RUN) '$(COMPOSE) up -d'
	@echo "MISP démarre… suivre avec 'make logs'. Prêt quand le healthcheck misp-core passe."

.PHONY: stop
stop: ## ARRÊT PROPRE de la pile MISP : conteneurs stoppés mais CONSERVÉS (repartent au boot)
	$(RUN) '$(COMPOSE) stop -t $(STOP_TIMEOUT)'

.PHONY: down
down: ## Arrête la stack (conserve les volumes)
	@# Le réseau cti-platform-misp_default est REJOINT depuis l'extérieur par les
	@# deux connecteurs OpenCTI et par la façade (profil proxy) — externes à ce
	@# projet compose. Docker refuse de le retirer tant qu'un conteneur y est
	@# encore attaché ("Resource is still in use"), quel que soit son projet :
	@# contrôlé AVANT que 'down' échoue à mi-chemin, avec un message qui dit quoi
	@# faire plutôt que l'erreur brute de Docker.
	@attaches=$$($(RUN) 'docker network inspect cti-platform-misp_default --format "{{range .Containers}}{{.Name}} {{end}}"' 2>/dev/null); \
	if [ -n "$$attaches" ]; then \
	  echo "  ATTENTION : encore attachés au réseau cti-platform-misp_default : $$attaches"; \
	  echo "    (connecteurs OpenCTI ou façade, probablement) — Docker refusera de le"; \
	  echo "    retirer tant qu'ils y sont. Arrêter/détruire OpenCTI D'ABORD :"; \
	  echo "    make opencti-down (ou opencti-destroy), puis relancer cette cible."; \
	  exit 1; \
	fi
	$(RUN) '$(COMPOSE) down'

.PHONY: destroy
destroy: ## Arrête, supprime les volumes ET l'état monté en bind (perte totale)
	@# Même contrôle que 'down' — voir son commentaire : la 'perte totale' promise
	@# ici ne doit pas s'arrêter à mi-chemin (configs déjà vidées, volumes non
	@# supprimés) sur un réseau encore accroché par OpenCTI ou la façade.
	@attaches=$$($(RUN) 'docker network inspect cti-platform-misp_default --format "{{range .Containers}}{{.Name}} {{end}}"' 2>/dev/null); \
	if [ -n "$$attaches" ]; then \
	  echo "  ATTENTION : encore attachés au réseau cti-platform-misp_default : $$attaches"; \
	  echo "    (connecteurs OpenCTI ou façade, probablement) — Docker refusera de le"; \
	  echo "    retirer tant qu'ils y sont. Arrêter/détruire OpenCTI D'ABORD :"; \
	  echo "    make opencti-down (ou opencti-destroy), puis relancer cette cible."; \
	  exit 1; \
	fi
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

# Adresse de contact du compte Let's Encrypt (avis d'expiration). Obligatoire
# pour `make cert-manuel`.
CERT_EMAIL ?=

.PHONY: cert-manuel
cert-manuel: ## CERTIFICAT public par DNS-01 MANUEL — make cert-manuel DOMAINE=<domaine> CERT_EMAIL=<courriel>
	@test -n "$(DOMAINE)"    || { echo "  DOMAINE=<domaine> manquant"; exit 1; }
	@test -n "$(CERT_EMAIL)" || { echo "  CERT_EMAIL=<courriel> manquant (avis d'expiration Let's Encrypt)"; exit 1; }
	@echo "  Un certificat JOKER *.$(DOMAINE) : un seul enregistrement TXT couvre"
	@echo "  misp.$(DOMAINE), opencti.$(DOMAINE) et tous ceux que vous ajouterez."
	@echo "  certbot va afficher le TXT à créer chez votre hébergeur DNS, puis attendre."
	@echo "  Laissez-lui le temps de se propager AVANT de valider (dig TXT _acme-challenge.$(DOMAINE))."
	@echo
	$(RUN) 'docker run -it --rm -v proxy_certificats:/etc/letsencrypt \
	  certbot/certbot certonly --manual --preferred-challenges dns \
	  -d "*.$(DOMAINE)" --agree-tos --no-eff-email -m "$(CERT_EMAIL)"'
	@echo
	@echo "  Certificat obtenu. Renseigner dans $(OCTI_ENV) :"
	@echo "    PROXY_TLS_CERT=/certs/live/$(DOMAINE)/fullchain.pem"
	@echo "    PROXY_TLS_KEY=/certs/live/$(DOMAINE)/privkey.pem"
	@echo "  puis : make opencti-up   (recrée la façade avec le nouveau certificat)"
	@echo
	@echo "  RENOUVELLEMENT : Let's Encrypt délivre pour 90 jours et le DNS-01 manuel"
	@echo "  n'est pas automatisable. Relancer cette même commande avant l'échéance ;"
	@echo "  un TXT à reposer, quel que soit le nombre de noms."

.PHONY: cert-etat
cert-etat: ## Échéance du certificat public servi par la façade
	@$(RUN) 'docker run --rm -v proxy_certificats:/etc/letsencrypt certbot/certbot certificates' 2>/dev/null \
	  | grep -E "Certificate Name|Domains|Expiry Date" || echo "  aucun certificat public (autorité locale mkcert)"

.PHONY: proxy-up
proxy-up: ## DÉMARRE la façade HTTPS seule (crée les réseaux OpenCTI/CISO au passage)
	@grep -qsE '^MISP_HOSTNAME=.+' "$(OCTI_ENV)" || { echo "  pas de façade configurée (make init DOMAINE=<domaine>)"; exit 0; }
	@grep -qsE '^CISO_HOSTNAME=.+' "$(CISO_ENV)" 2>/dev/null && $(RUN) 'docker network create cti-platform-ciso_default' >/dev/null 2>&1; true
	$(RUN) '$(OCTI) up -d proxy'

.PHONY: proxy-cert
proxy-cert: ## RÉGÉNÈRE le certificat mkcert de la façade (autorité locale) — joker *.DOMAINE, expiration
	@domaine=$$(grep -E '^DOMAINE=' "$(OCTI_ENV)" 2>/dev/null | cut -d= -f2); \
	 if [ -z "$$domaine" ]; then \
	   misp=$$(grep -E '^MISP_HOSTNAME=' "$(OCTI_ENV)" 2>/dev/null | cut -d= -f2); \
	   domaine="$${misp#misp.}"; \
	 fi; \
	 test -n "$$domaine" || { echo "  pas de façade configurée (make init DOMAINE=<domaine>)"; exit 1; }; \
	 command -v mkcert >/dev/null 2>&1 || { echo "  mkcert introuvable — apt install mkcert"; exit 1; }; \
	 TRUST_STORES=none mkcert -install >/dev/null; \
	 TRUST_STORES=none mkcert -cert-file proxy/certs/cert.pem -key-file proxy/certs/key.pem "$$domaine" "*.$$domaine"; \
	 echo "  certificat régénéré pour $$domaine et *.$$domaine (proxy/certs/) — couvre toute future identité, sans y repenser"; \
	 echo "  puis : make opencti-up   (recrée la façade avec le nouveau certificat)"

.PHONY: proxy-ca
proxy-ca: ## EXPORTE la racine mkcert de l'autorité locale, à installer une fois sur chaque client
	@command -v mkcert >/dev/null 2>&1 || { echo "  mkcert introuvable — apt install mkcert"; exit 1; }
	@mkdir -p dist
	@cp "$$(mkcert -CAROOT)/rootCA.pem" ./dist/ac-locale.crt
	@echo "  racine exportée : dist/ac-locale.crt"
	@echo "  Debian/Ubuntu : sudo cp dist/ac-locale.crt /usr/local/share/ca-certificates/cti-platform.crt && sudo update-ca-certificates"
	@echo "  Firefox tient son propre magasin : Paramètres > Vie privée > Certificats > Autorités > Importer."

.PHONY: proxy-logs
proxy-logs: ## Suit les journaux de la façade HTTPS
	$(RUN) '$(OCTI) logs -f proxy'

.PHONY: adressage
adressage: ## ÉMET l'adressage qu'un outil d'alimentation doit connaître (ARGS=--secrets pour le fragment .env réel)
	@$(PY) provisioning/adressage.py $(ARGS)

.PHONY: cle-automation
cle-automation: ## CRÉE une clé d'automation MISP dédiée, qui survit à misp-setup (ARGS=--lister | --env | --commentaire '…')
	@$(PY) provisioning/misp_cle_automation.py $(ARGS)

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
opencti-stop: ## ARRÊT PROPRE de la pile OpenCTI : conteneurs stoppés mais CONSERVÉS
	$(RUN) '$(OCTI) --profile feeds stop -t $(STOP_TIMEOUT)'

.PHONY: stop-all
stop-all: ## ARRÊT PROPRE des piles, OpenCTI d'abord (il consomme MISP), CISO-Assistant en plus si présente
	@# CHEMIN D'ARRÊT : il doit aboutir même si une pile bronche. Un conteneur
	@# qui s'est déjà arrêté seul fait sortir `compose stop` en erreur
	@# (« cannot stop container: … is not running ») ; quand les deux piles
	@# étaient des PRÉREQUIS make, cette erreur interrompait la cible et la
	@# pile MISP n'était jamais arrêtée du tout. Les `-` sont donc délibérés :
	@# on veut arrêter chaque pile même si une autre a protesté, et rendre la
	@# main en succès pour que systemd ne compte pas l'unité en échec.
	-$(RUN) '$(OCTI) --profile feeds stop -t $(STOP_TIMEOUT)'
	-$(RUN) '$(COMPOSE) stop -t $(STOP_TIMEOUT)'
	-[ -f "$(CISO_ENV)" ] && $(RUN) '$(CISO) stop -t $(STOP_TIMEOUT)'
	@echo "  les piles sont arrêtées ; les conteneurs existent toujours et"
	@echo "  repartiront au prochain démarrage du démon (restart: always)."

.PHONY: autostart
autostart: ## Installe l'unité systemd qui arrête PROPREMENT les piles à l'extinction
	@mkdir -p "$(HOME)/.config/systemd/user"
	@sed -e 's|@REPO@|$(CURDIR)|g' -e 's|@UID@|$(shell id -u)|g' \
	     -e 's|@TIMEOUT@|$(AUTOSTART_TIMEOUT)|g' \
	     provisioning/systemd/cti-platform.service.in \
	     > "$(HOME)/.config/systemd/user/cti-platform.service"
	systemctl --user daemon-reload
	systemctl --user enable --now cti-platform.service
	@echo "  unité posée : arrêt propre des deux piles avant l'extinction du démon."
	@plafond=$$(systemctl show user@$(shell id -u).service -p TimeoutStopUSec --value 2>/dev/null); \
	 echo "  plafond du gestionnaire de session (user@$(shell id -u).service) : $$plafond"; \
	 echo "  au-delà, systemd tue la session : prepare_host.sh pose un drop-in à 300 s."

.PHONY: autostart-off
autostart-off: ## Retire l'unité d'arrêt propre
	-systemctl --user disable --now cti-platform.service
	rm -f "$(HOME)/.config/systemd/user/cti-platform.service"
	systemctl --user daemon-reload

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

.PHONY: ciso-up
ciso-up: ## DÉMARRE CISO-Assistant (GRC) — à côté de MISP/OpenCTI, aucun échange de données
	@grep -qsE '^CISO_HOSTNAME=.+' "$(CISO_ENV)" 2>/dev/null || { echo "  pas de façade configurée pour CISO-Assistant (make init DOMAINE=<domaine>)"; exit 1; }
	@$(RUN) 'docker network create cti-platform-ciso_default' >/dev/null 2>&1; true
	@# L'image tourne en UID 1001 non-root ; un volume Docker NEUF appartient à
	@# root tant que rien ne l'a peuplé. `docker run` root, une fois, idempotent.
	$(RUN) 'docker run --rm -v ciso_bdd:/code/db --user root --entrypoint /bin/sh \
	  ghcr.io/intuitem/ciso-assistant-community/backend:v4.0.6 -c "chown -R 1001:1001 /code/db"'
	$(RUN) '$(CISO) up -d'
	@echo "  → https://$$(grep -E '^CISO_HOSTNAME=' "$(CISO_ENV)" | cut -d= -f2) — premier accès : make ciso-superuser"
	@echo "  premier démarrage LENT (migrations) : make ciso-logs pour suivre"

.PHONY: ciso-superuser
ciso-superuser: ## CRÉE le premier compte admin CISO-Assistant (interactif, une fois)
	$(RUN) '$(CISO) exec backend python manage.py createsuperuser'

.PHONY: ciso-destroy
ciso-destroy: ## Arrête CISO-Assistant ET supprime ses volumes (base, Qdrant)
	$(RUN) '$(CISO) down -v'

.PHONY: ciso-logs
ciso-logs: ## suit les logs CISO-Assistant
	$(RUN) '$(CISO) logs -f --tail=100'

.PHONY: ciso-ps
ciso-ps: ## état des conteneurs CISO-Assistant
	$(RUN) '$(CISO) ps'

.PHONY: opencti-ps
opencti-ps: ## état des conteneurs OpenCTI
	$(RUN) '$(OCTI) ps'


.PHONY: taxii-check
taxii-check: ## teste la collection TAXII 2.1 avec un client standard (pagination, validité STIX, intégrité des refs)
	./.venv/bin/python provisioning/taxii_check.py $(ARGS)
