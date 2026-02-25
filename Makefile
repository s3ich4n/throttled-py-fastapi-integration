.PHONY: up down app scenario logs-collector logs-prometheus logs-grafana

up:
	docker compose up -d

down:
	docker compose down -v

app:
	uv run uvicorn metric_check:app --reload

scenario:
	bash scenario.sh

logs-collector:
	docker compose logs -f otel-collector

logs-prometheus:
	docker compose logs -f prometheus

logs-grafana:
	docker compose logs -f grafana
