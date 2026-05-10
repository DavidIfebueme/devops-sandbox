.PHONY: up down create destroy logs health simulate clean help daemon api poller build-app monitoring

SHELL := /bin/bash
PROJECT_DIR := $(shell pwd)

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

build-app: ## Build the sandbox app Docker image
	docker build -t sandbox-app:latest ./app

up: ## Start Nginx + daemon + API + health poller
	@echo "Starting DevOps Sandbox Platform..."
	docker compose up -d
	@mkdir -p $(PROJECT_DIR)/logs $(PROJECT_DIR)/envs
	@bash $(PROJECT_DIR)/platform/cleanup_daemon.sh &> /tmp/sandbox-daemon.log & echo $$! > /tmp/sandbox-daemon.pid && echo "  ✓ Daemon started (PID: $$(cat /tmp/sandbox-daemon.pid))"
	@source /opt/sandbox-venv/bin/activate && python3 $(PROJECT_DIR)/monitor/health_poller.py &> /tmp/sandbox-poller.log & echo $$! > /tmp/sandbox-poller.pid && echo "  ✓ Health poller started (PID: $$(cat /tmp/sandbox-poller.pid))"
	@source /opt/sandbox-venv/bin/activate && uvicorn api.api:app --host 0.0.0.0 --port 8080 --app-dir $(PROJECT_DIR) &> /tmp/sandbox-api.log & echo $$! > /tmp/sandbox-api.pid && echo "  ✓ API started (PID: $$(cat /tmp/sandbox-api.pid))"
	@sleep 1 && curl -s http://localhost:8080/health > /dev/null && echo "  ✓ API health check passed" || echo "  ⚠ API not responding yet"
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  Sandbox Platform is UP"
	@echo "  API:      http://localhost:8080/docs"
	@echo "  Nginx:    http://localhost"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

down: ## Stop everything and destroy all environments
	@echo "Stopping DevOps Sandbox Platform..."
	@for f in $(PROJECT_DIR)/envs/*.json; do \
		[ -f "$$f" ] && bash $(PROJECT_DIR)/platform/destroy_env.sh $$(basename $$f .json) 2>/dev/null || true; \
	done
	@pkill -f "uvicorn api.api:app" 2>/dev/null && echo "  ✓ API stopped" || true
	@pkill -f "health_poller.py" 2>/dev/null && echo "  ✓ Poller stopped" || true
	@pkill -f "cleanup_daemon.sh" 2>/dev/null && echo "  ✓ Daemon stopped" || true
	@rm -f /tmp/sandbox-daemon.pid /tmp/sandbox-api.pid /tmp/sandbox-poller.pid /tmp/sandbox-daemon.log /tmp/sandbox-api.log /tmp/sandbox-poller.log
	docker compose down
	@echo "Platform stopped."

create: ## Create a new environment (prompts for name + TTL)
	@read -p "Environment name: " name; \
	read -p "TTL in minutes [30]: " ttl; \
	ttl=$${ttl:-30}; \
	bash $(PROJECT_DIR)/platform/create_env.sh "$$name" "$$ttl"

destroy: ## Destroy a specific environment (ENV=env-abc123)
	@if [ -z "$(ENV)" ]; then echo "Usage: make destroy ENV=env-abc123"; exit 1; fi
	bash $(PROJECT_DIR)/platform/destroy_env.sh "$(ENV)"

logs: ## Tail logs for an environment (ENV=env-abc123)
	@if [ -z "$(ENV)" ]; then echo "Usage: make logs ENV=env-abc123"; exit 1; fi
	@tail -f $(PROJECT_DIR)/logs/$(ENV)/app.log

health: ## Show health status of all environments
	@echo "Environment Health Status:"
	@echo "───────────────────────────────────────────"
	@for f in $(PROJECT_DIR)/envs/*.json; do \
		[ -f "$$f" ] || continue; \
		id=$$(jq -r '.id' $$f); \
		name=$$(jq -r '.name' $$f); \
		status=$$(jq -r '.status' $$f); \
		remaining=$$(( $$(jq -r '.created_at + .ttl' $$f) - $$(date +%s) )); \
		if [ $$remaining -lt 0 ]; then remaining="EXPIRED"; else remaining="$$remaining seconds"; fi; \
		printf "  %-15s %-20s %-10s %s\n" "$$id" "$$name" "$$status" "TTL: $$remaining"; \
	done
	@echo "───────────────────────────────────────────"

simulate: ## Run outage simulation (ENV=env-abc123 MODE=crash|pause|network|recover|stress)
	@if [ -z "$(ENV)" ] || [ -z "$(MODE)" ]; then echo "Usage: make simulate ENV=env-abc123 MODE=crash"; exit 1; fi
	bash $(PROJECT_DIR)/platform/simulate_outage.sh --env "$(ENV)" --mode "$(MODE)"

clean: ## Wipe all state, logs, and archives
	@echo "Cleaning all state and logs..."
	@for f in $(PROJECT_DIR)/envs/*.json; do \
		[ -f "$$f" ] && bash $(PROJECT_DIR)/platform/destroy_env.sh $$(basename $$f .json) 2>/dev/null || true; \
	done
	rm -rf $(PROJECT_DIR)/envs/* $(PROJECT_DIR)/logs/* $(PROJECT_DIR)/nginx/conf.d/*.conf
	mkdir -p $(PROJECT_DIR)/logs/archived $(PROJECT_DIR)/envs
	@pkill -f "uvicorn api.api:app" 2>/dev/null || true
	@pkill -f "health_poller.py" 2>/dev/null || true
	@pkill -f "cleanup_daemon.sh" 2>/dev/null || true
	@rm -f /tmp/sandbox-daemon.pid /tmp/sandbox-api.pid /tmp/sandbox-poller.pid /tmp/sandbox-daemon.log /tmp/sandbox-api.log /tmp/sandbox-poller.log
	docker compose down -v 2>/dev/null || true
	@echo "Clean complete."

monitoring: ## Start Prometheus + Grafana (optional extra)
	docker compose --profile monitoring up -d
	@echo "Prometheus: http://localhost:9090"
	@echo "Grafana:    http://localhost:3000 (admin/admin)"
