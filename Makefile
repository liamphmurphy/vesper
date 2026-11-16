# Vesper developer tasks. `make help` lists them.
SHELL := /bin/bash
COMPOSE_DEV := docker compose -f docker-compose.dev.yml

.PHONY: help up down start setup signin login claude-login codex-login github-login stop-dev dev dev-infra api web web-deps runner stop-host-runners gen gen-check test lint build reset desktop-deps desktop-dev desktop-test desktop-dmg desktop-dmg-universal

help: ## List targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-13s %s\n", $$1, $$2}'

up: ## Full stack in Docker → http://localhost:8080
	docker compose build --no-cache api web
	docker compose up --build --force-recreate

down: ## Stop the full stack
	docker compose down

dev-infra: ## Start postgres + seaweedfs only
	$(COMPOSE_DEV) up -d --wait

API_PORT ?= 8000
WEB_PORT ?= 3000
# Host-folder workspaces (docs/guide.md, "Open a run's code"): set in the environment or .env.
VESPER_WORKSPACES_DIR ?= $(shell sed -n 's/^VESPER_WORKSPACES_DIR=//p' .env 2>/dev/null)
export VESPER_WORKSPACES_DIR
# The hardened runner is a dev compose service (docker-compose.dev.yml).
RUNNER_COMPOSE := $(COMPOSE_DEV) $(if $(VESPER_WORKSPACES_DIR),-f docker-compose.workspaces.yml) --profile runner
# A key in the environment wins over .env (`make setup` creates that one).
SECRETS_KEY ?= $(shell sed -n 's/^SECRETS_KEY=//p' .env 2>/dev/null)
export SECRETS_KEY
# Processes the runner runs at once; delegated runs and resumed turns share these slots.
RUNNER_MAX_CONCURRENT ?= 8
export RUNNER_MAX_CONCURRENT API_PORT

start: ## One command for everything: set up, sign in if needed, run the app and hardened runner → http://localhost:3000
	@API_PORT=$(API_PORT) scripts/vesper-setup.sh start

setup: ## Create .env with a SECRETS_KEY and build the agent image
	@scripts/vesper-setup.sh setup

signin: ## Print a one-time link that signs a browser in to Vesper (the full stack's API if it's up, else the dev database)
	@if [ -n "$$(docker compose ps -q api 2>/dev/null)" ]; then docker compose exec -T api vesper sign-in-link; \
	else cd server && WEB_URL=$${WEB_URL:-http://localhost:$(WEB_PORT)} go run ./cmd/vesper sign-in-link; fi

login: claude-login codex-login github-login ## Sign Vesper in to Claude, Codex and GitHub (needs the API running)

claude-login: ## Store a Claude plan login for agent containers (needs the API running)
	@API_PORT=$(API_PORT) scripts/vesper-setup.sh login-claude

codex-login: ## Store a Codex plan login; CODEX_AUTH_FILE=~/.codex/auth.json copies an existing one (needs the API running)
	@API_PORT=$(API_PORT) scripts/vesper-setup.sh login-codex

github-login: ## Store your GitHub CLI token as git:pat so agents can push and open PRs (needs the API running)
	@API_PORT=$(API_PORT) scripts/vesper-setup.sh login-github

stop-dev: ## Kill whatever is listening on the API and web dev ports (left over from an earlier run)
	@for port in $(API_PORT) $(WEB_PORT); do \
	  pids=$$(lsof -nP -tiTCP:$$port -sTCP:LISTEN 2>/dev/null); \
	  [ -z "$$pids" ] && continue; \
	  for pid in $$pids; do echo "stopping existing process on :$$port — $$(ps -o command= -p $$pid)"; done; \
	  kill $$pids 2>/dev/null; \
	  for i in 1 2 3 4 5 6 7 8 9 10; do lsof -nP -tiTCP:$$port -sTCP:LISTEN >/dev/null 2>&1 || break; sleep 0.3; done; \
	  kill -9 $$(lsof -nP -tiTCP:$$port -sTCP:LISTEN 2>/dev/null) 2>/dev/null || true; \
	done

dev: dev-infra stop-dev ## Infra in Docker, API (hot reload) + Next dev on the host → http://localhost:3000 (replaces any API/web already on those ports)
	@trap 'kill 0' EXIT; \
	  $(MAKE) --no-print-directory api & \
	  $(MAKE) --no-print-directory web & \
	  wait

api: ## Run the API (hot reload if air is installed: go install github.com/air-verse/air@latest)
	cd server && export PUBLIC_URL=$${PUBLIC_URL:-http://localhost:8000} WEB_URL=$${WEB_URL:-http://localhost:$(WEB_PORT)} \
	  DESIGN_WORKER_TOKEN=$${DESIGN_WORKER_TOKEN:-vesper-local-design-worker} DESIGN_WORKER_URL=$${DESIGN_WORKER_URL:-http://localhost:$(WEB_PORT)/internal/designs}; \
	  if command -v air >/dev/null; then air; else go run ./cmd/vesper serve; fi

runner: stop-host-runners ## Run dispatched tickets in hardened containers; replaces any runner already running
	$(RUNNER_COMPOSE) up -d --force-recreate runner
	@trap '$(RUNNER_COMPOSE) stop runner >/dev/null 2>&1' EXIT; $(RUNNER_COMPOSE) logs -f --no-log-prefix runner

stop-host-runners: ## Stop runners an older `make start` left on the host: they claim runs with stale code
	@for pid in $$(pgrep -f 'vesper runner$$' 2>/dev/null); do \
	  echo "stopping host runner $$pid — $$(ps -o command= -p $$pid)"; \
	  kill $$pid 2>/dev/null; \
	done; true

WEB_DEPS := web/node_modules/.package-lock.json

$(WEB_DEPS): web/package-lock.json
	cd web && npm ci
	@touch $@

web-deps: $(WEB_DEPS) ## Install web dependencies if the lockfile changed

web: web-deps ## Run Next dev server
	cd web && DESIGN_WORKER_TOKEN=$${DESIGN_WORKER_TOKEN:-vesper-local-design-worker} npm run dev

gen: web-deps ## Regenerate API code (Go + TS) and sqlc queries. Needs sqlc 1.31+ on PATH.
	cd server && go generate ./...
	cd server && sqlc generate
	cd web && npm run gen

gen-check: gen ## Fail if generated code is out of date
	@git diff --exit-code -- server/internal/api server/internal/store web/lib/api || \
	  (echo "generated code is stale: run 'make gen' and commit" && exit 1)

test: web-deps ## Run Go and web tests
	cd server && go test ./...
	cd web && npm run typecheck

lint: web-deps ## Vet Go, lint web
	cd server && go vet ./... && test -z "$$(gofmt -l .)"
	cd web && npm run lint

build: web-deps ## Build both apps
	cd server && go build ./...
	cd web && npm run build

reset: ## Delete dev volumes (all local data)
	$(RUNNER_COMPOSE) down -v
	docker compose down -v

DESKTOP_DEPS := desktop/node_modules/.package-lock.json

$(DESKTOP_DEPS): desktop/package-lock.json
	cd desktop && npm ci
	@touch $@

desktop-deps: $(DESKTOP_DEPS) ## Install desktop Electron dependencies if the lockfile changed

desktop-dev: desktop-deps ## Build and launch the Electron desktop client
	cd desktop && npm run start

desktop-test: desktop-deps ## Typecheck and run desktop unit tests
	cd desktop && npm run typecheck && npm test

desktop-dmg: desktop-deps ## Package macOS Apple Silicon Vesper.dmg (run on macOS)
	cd desktop && npm run dmg

desktop-dmg-universal: desktop-deps ## Package macOS universal Vesper.dmg (run on macOS)
	cd desktop && npm run dmg:universal
