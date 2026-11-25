# Vesper developer tasks. `make help` lists them.
# Vesper ships as the native macOS app (`make mac-app`); `make dev` runs the API and
# headless design worker on the host against a local Postgres for development.
SHELL := /bin/bash

.PHONY: help signin dev-infra dev-infra-stop stop-dev dev api worker worker-deps runner gen gen-check test test-server test-worker lint build reset mac-app mac-test mac-run mac-dmg mac-reinstall mac-release mac-golden

help: ## List targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-13s %s\n", $$1, $$2}'

dev-infra: ## Start a local Postgres 17 (bundled build, data in .dev/pgdata) on :5432
	@scripts/dev-postgres.sh start

dev-infra-stop: ## Stop the local dev Postgres (data is kept)
	@scripts/dev-postgres.sh stop

API_PORT ?= 8000
WEB_PORT ?= 3000
# A key in the environment wins over .env.
SECRETS_KEY ?= $(shell sed -n 's/^SECRETS_KEY=//p' .env 2>/dev/null)
export SECRETS_KEY
# Processes the runner runs at once; delegated runs and resumed turns share these slots.
RUNNER_MAX_CONCURRENT ?= 8
export RUNNER_MAX_CONCURRENT API_PORT

signin: ## Print a one-time link that signs a browser in to Vesper (against the dev database)
	cd server && WEB_URL=$${WEB_URL:-http://localhost:$(WEB_PORT)} go run ./cmd/vesper sign-in-link

stop-dev: ## Kill whatever is listening on the API and web dev ports (left over from an earlier run)
	@for port in $(API_PORT) $(WEB_PORT); do \
	  pids=$$(lsof -nP -tiTCP:$$port -sTCP:LISTEN 2>/dev/null); \
	  [ -z "$$pids" ] && continue; \
	  for pid in $$pids; do echo "stopping existing process on :$$port — $$(ps -o command= -p $$pid)"; done; \
	  kill $$pids 2>/dev/null; \
	  for i in 1 2 3 4 5 6 7 8 9 10; do lsof -nP -tiTCP:$$port -sTCP:LISTEN >/dev/null 2>&1 || break; sleep 0.3; done; \
	  kill -9 $$(lsof -nP -tiTCP:$$port -sTCP:LISTEN 2>/dev/null) 2>/dev/null || true; \
	done

dev: dev-infra stop-dev ## Local Postgres, API (hot reload) + headless design worker on the host (replaces any process already on those ports)
	@trap 'kill 0' EXIT; \
	  $(MAKE) --no-print-directory api & \
	  $(MAKE) --no-print-directory worker & \
	  wait

api: ## Run the API (hot reload if air is installed: go install github.com/air-verse/air@latest)
	cd server && export PUBLIC_URL=$${PUBLIC_URL:-http://localhost:8000} WEB_URL=$${WEB_URL:-http://localhost:$(API_PORT)} \
	  DESIGN_WORKER_TOKEN=$${DESIGN_WORKER_TOKEN:-vesper-local-design-worker} DESIGN_WORKER_URL=$${DESIGN_WORKER_URL:-http://localhost:$(WEB_PORT)/internal/designs}; \
	  if command -v air >/dev/null; then air; else go run ./cmd/vesper serve; fi

runner: ## Run a runner on the host (RUNNER_BACKEND=microvm needs the app's kernel and rootfs; =fake needs RUNNER_CLAUDE_BIN/RUNNER_CODEX_BIN)
	cd server && RUNNER_MCP_URL=$${RUNNER_MCP_URL:-http://localhost:$(API_PORT)/mcp} go run ./cmd/vesper runner

WORKER_DEPS := design-worker/node_modules/.package-lock.json

$(WORKER_DEPS): design-worker/package-lock.json
	cd design-worker && npm ci
	@touch $@

worker-deps: $(WORKER_DEPS) ## Install design-worker dependencies if the lockfile changed

worker: worker-deps ## Run the headless design & PDF worker
	cd design-worker && DESIGN_WORKER_TOKEN=$${DESIGN_WORKER_TOKEN:-vesper-local-design-worker} npm run dev

gen: ## Regenerate API code (Go and the Mac app's Swift) and sqlc queries. Needs sqlc 1.31+ on PATH.
	cd server && go generate ./...
	cd server && sqlc generate
	cd server && go run ./cmd/gen-swift-api -spec ../api/openapi.yaml -out ../macos/Sources/VesperCore/API/Generated

gen-check: gen ## Fail if generated code is out of date
	@git diff --exit-code -- server/internal/api server/internal/store macos/Sources/VesperCore/API/Generated || \
	  (echo "generated code is stale: run 'make gen' and commit" && exit 1)

test: test-server test-worker ## Run backend and design-worker tests

# httpapi and runner take ~17-19 min on a 4-core machine, past go test's 10m default.
test-server: ## Run Go tests (database tests need TEST_DATABASE_URL)
	cd server && go test -timeout 30m ./...

test-worker: worker-deps ## Typecheck the design worker and run its unit tests
	cd design-worker && npm run typecheck
	cd design-worker && npm test

lint: worker-deps ## Vet Go, typecheck design-worker
	cd server && go vet ./... && test -z "$$(gofmt -l cmd internal)"
	cd design-worker && npm run typecheck

build: worker-deps ## Build server and design-worker
	cd server && go build ./...
	cd design-worker && npm run build

reset: ## Stop the dev Postgres and delete all local dev data (.dev/pgdata, blobs)
	-@scripts/dev-postgres.sh stop
	rm -rf .dev/pgdata .dev/postgres.log server/.lazyagents/blobs

# The native macOS app lives in macos/ and has its own Makefile.
mac-app: ## Build the macOS app bundle (macos/Makefile)
	$(MAKE) -C macos app

mac-test: ## Run the macOS app tests (macos/Makefile)
	$(MAKE) -C macos test

mac-run: ## Build and launch the macOS app (macos/Makefile)
	$(MAKE) -C macos run

mac-dmg: ## Build macos/build/Vesper-arm64.dmg (macos/Makefile)
	$(MAKE) -C macos dmg

mac-reinstall: ## Rebuild and replace the installed macOS app (macos/Makefile)
	$(MAKE) -C macos reinstall

mac-release: ## Build and upload a GitHub release locally (usage: make mac-release TAG=v0.3.0 ARGS="--from-run")
	@if [ -z "$(TAG)" ]; then echo "Usage: make mac-release TAG=v0.3.0 [ARGS='--from-run']"; exit 1; fi
	@scripts/mac-release-local.sh "$(TAG)" $(ARGS)

# macOS guest VM golden image for personas' `mac` command (Apple Silicon only).
# Optional overrides: MACOS_GOLDEN_DIR, VESPER_MACOS_SOURCE, VESPER_USER_DATA_DIR.
mac-golden: ## Set up the macOS VM golden image for `mac` (installs tart via Homebrew if missing)
	@set -euo pipefail; \
	if [ "$$(uname -s)/$$(uname -m)" != "Darwin/arm64" ]; then \
	  echo "mac-golden needs an Apple Silicon Mac (Darwin/arm64)." >&2; exit 1; \
	fi; \
	pkgs=""; \
	command -v tart >/dev/null 2>&1 || pkgs="$$pkgs openai/tools/tart"; \
	if [ -n "$$pkgs" ]; then \
	  if ! command -v brew >/dev/null 2>&1; then \
	    echo "Missing prerequisites ($${pkgs# }) and Homebrew is not installed." >&2; exit 1; \
	  fi; \
	  echo "Installing prerequisites via Homebrew:$$pkgs"; \
	  brew install $$pkgs; \
	fi; \
	if [ -n "$(MACOS_GOLDEN_DIR)" ]; then \
	  deploy/microvm/macos-golden.sh "$(MACOS_GOLDEN_DIR)"; \
	else \
	  deploy/microvm/macos-golden.sh; \
	fi
