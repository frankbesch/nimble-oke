.PHONY: help discover prereqs install verify operate troubleshoot cleanup clean all session-init session-summary session-compare

SCRIPTS_DIR := scripts
ENVIRONMENT ?= dev
CONFIRM_COST ?= no

help:
	@echo "Nimble OKE - Rapid Smoke Testing Platform"
	@echo ""
	@echo "Cluster Lifecycle:"
	@echo "  make provision       → Provision OKE cluster with GPU nodes"
	@echo "  make teardown        → Teardown entire OKE cluster"
	@echo ""
	@echo "Runbook Flow:"
	@echo "  make discover        → Discover current OKE cluster state"
	@echo "  make prereqs         → Check prerequisites"
	@echo "  make install         → Deploy NIM to OKE"
	@echo "  make verify          → Verify deployment health"
	@echo "  make operate         → Show operational commands"
	@echo "  make troubleshoot    → Run troubleshooting checks"
	@echo "  make cleanup         → Cleanup NIM deployment"
	@echo ""
	@echo "Shortcuts:"
	@echo "  make all             → Run complete workflow (discover→install→verify)"
	@echo "  make clean           → Alias for cleanup"
	@echo ""
	@echo "Session Tracking:"
	@echo "  make session-init    → Initialize session tracking"
	@echo "  make session-summary → Show current session summary"
	@echo "  make session-compare → Compare with previous sessions"
	@echo ""
	@echo "Environment:"
	@echo "  ENVIRONMENT=$(ENVIRONMENT)"
	@echo "  CONFIRM_COST=$(CONFIRM_COST)"
	@echo ""
	@echo "Examples:"
	@echo "  make provision CONFIRM_COST=yes"
	@echo "  make discover"
	@echo "  make install CONFIRM_COST=yes"
	@echo "  make cleanup"
	@echo "  make teardown"

discover:
	@echo "[NIM-OKE] Running discovery..."
	@$(SCRIPTS_DIR)/discover.sh

prereqs:
	@echo "[NIM-OKE] Checking prerequisites..."
	@$(SCRIPTS_DIR)/prereqs.sh

install: prereqs
	@echo "[NIM-OKE] Installing NIM..."
	@ENVIRONMENT=$(ENVIRONMENT) CONFIRM_COST=$(CONFIRM_COST) $(SCRIPTS_DIR)/deploy.sh

verify:
	@echo "[NIM-OKE] Verifying deployment..."
	@$(SCRIPTS_DIR)/verify.sh

operate:
	@echo "[NIM-OKE] Operational commands..."
	@$(SCRIPTS_DIR)/operate.sh

troubleshoot:
	@echo "[NIM-OKE] Running troubleshooting..."
	@$(SCRIPTS_DIR)/troubleshoot.sh

cleanup:
	@echo "[NIM-OKE] Cleaning up NIM deployment..."
	@$(SCRIPTS_DIR)/cleanup-nim.sh

clean: cleanup

provision:
	@echo "[NIM-OKE] Provisioning OKE cluster..."
	@ENVIRONMENT=$(ENVIRONMENT) CONFIRM_COST=$(CONFIRM_COST) $(SCRIPTS_DIR)/provision-cluster.sh

teardown:
	@echo "[NIM-OKE] Tearing down OKE cluster..."
	@FORCE=$(FORCE) $(SCRIPTS_DIR)/teardown-cluster.sh

cleanup-cluster: teardown

all: discover install verify
	@echo "[NIM-OKE] Complete workflow finished"

# Session tracking targets
session-init:
	@echo "[NIM-OKE] Initializing session tracking..."
	@$(SCRIPTS_DIR)/session-tracker.sh init "session-$(shell date +%Y%m%d-%H%M%S)" "manual"

session-summary:
	@echo "[NIM-OKE] Current session summary:"
	@$(SCRIPTS_DIR)/session-tracker.sh summary

session-compare:
	@echo "[NIM-OKE] Comparing sessions:"
	@$(SCRIPTS_DIR)/session-tracker.sh compare $(HOME)/.nimble-oke/sessions/current.json

test-inference:
	@echo "[NIM-OKE] Testing inference API..."
	@$(SCRIPTS_DIR)/verify.sh
	@echo ""
	@echo "Run API tests manually or check 'make operate' for commands"

validate: prereqs verify
	@echo "[NIM-OKE] Validation complete"

status:
	@echo "[NIM-OKE] Current deployment status..."
	@kubectl get all -l app.kubernetes.io/name=nvidia-nim --all-namespaces 2>/dev/null || echo "No NIM resources found"

logs:
	@echo "[NIM-OKE] Fetching logs..."
	@kubectl logs -l app.kubernetes.io/name=nvidia-nim --tail=100 -n default 2>/dev/null || echo "No logs available"

