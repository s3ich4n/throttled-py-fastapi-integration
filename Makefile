ALGORITHMS := token_bucket fixed_window sliding_window leaking_bucket gcra
APP_URL    := http://localhost:8000
MODE       ?= sync

.PHONY: up down build \
	run-token-bucket run-fixed-window run-sliding-window run-leaking-bucket run-gcra \
	run-all run-all-sync run-all-async \
	logs logs-collector logs-prometheus logs-grafana

# --- docker compose ---

build:
	docker compose build

up:
	docker compose up -d

down:
	docker compose down -v

# --- scenario (app must be running via `make up`) ---

scenario-%:
	bash scenario.sh $* $(MODE)

# --- run (up + wait + scenario) ---

define wait_ready
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
		curl -s -o /dev/null $(APP_URL)/docs && break; \
		sleep 1; \
	done
endef

run-%: up
	$(wait_ready)
	bash scenario.sh $* $(MODE)

run-all: up
	$(wait_ready)
	$(MAKE) -j5 $(addprefix scenario-,$(ALGORITHMS))

run-all-sync: up
	$(wait_ready)
	$(MAKE) -j5 MODE=sync $(addprefix scenario-,$(ALGORITHMS))

run-all-async: up
	$(wait_ready)
	$(MAKE) -j5 MODE=async $(addprefix scenario-,$(ALGORITHMS))

# --- logs ---

logs:
	docker compose logs -f app

logs-collector:
	docker compose logs -f otel-collector

logs-prometheus:
	docker compose logs -f prometheus

logs-grafana:
	docker compose logs -f grafana
