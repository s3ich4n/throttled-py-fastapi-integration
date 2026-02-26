.PHONY: up down logs-collector logs-prometheus logs-grafana \
	app-token-bucket app-fixed-window app-sliding-window app-leaking-bucket app-gcra \
	scenario-token-bucket scenario-fixed-window scenario-sliding-window scenario-leaking-bucket scenario-gcra \
	run-token-bucket run-fixed-window run-sliding-window run-leaking-bucket run-gcra run-all

up:
	docker compose up -d

down:
	docker compose down -v

# --- app (foreground) ---

app-token-bucket:
	uv run uvicorn metric_check_token_bucket:app --port 8000

app-fixed-window:
	uv run uvicorn metric_check_fixed_window:app --port 8001

app-sliding-window:
	uv run uvicorn metric_check_sliding_window:app --port 8002

app-leaking-bucket:
	uv run uvicorn metric_check_leaking_bucket:app --port 8003

app-gcra:
	uv run uvicorn metric_check_gcra:app --port 8004

# --- scenario only ---

scenario-token-bucket:
	bash scenario_token_bucket.sh

scenario-fixed-window:
	bash scenario_fixed_window.sh

scenario-sliding-window:
	bash scenario_sliding_window.sh

scenario-leaking-bucket:
	bash scenario_leaking_bucket.sh

scenario-gcra:
	bash scenario_gcra.sh

# --- run (app + scenario + cleanup) ---

define run_recipe
	@uv run uvicorn $(1):app --port $(2) & \
	APP_PID=$$!; \
	trap "kill $$APP_PID 2>/dev/null" EXIT; \
	for i in 1 2 3 4 5; do \
		curl -s -o /dev/null http://localhost:$(2)/docs && break; \
		sleep 1; \
	done; \
	bash $(3); \
	kill $$APP_PID 2>/dev/null
endef

run-token-bucket:
	$(call run_recipe,metric_check_token_bucket,8000,scenario_token_bucket.sh)

run-fixed-window:
	$(call run_recipe,metric_check_fixed_window,8001,scenario_fixed_window.sh)

run-sliding-window:
	$(call run_recipe,metric_check_sliding_window,8002,scenario_sliding_window.sh)

run-leaking-bucket:
	$(call run_recipe,metric_check_leaking_bucket,8003,scenario_leaking_bucket.sh)

run-gcra:
	$(call run_recipe,metric_check_gcra,8004,scenario_gcra.sh)

run-all:
	$(MAKE) -j5 run-token-bucket run-fixed-window run-sliding-window run-leaking-bucket run-gcra

# --- logs ---

logs-collector:
	docker compose logs -f otel-collector

logs-prometheus:
	docker compose logs -f prometheus

logs-grafana:
	docker compose logs -f grafana
