.PHONY: help discover prereqs install verify operate troubleshoot cleanup clean all session-init session-summary session-compare validate validate-quick validate-cost dry-run test-connectivity cost-simulate cost-scenarios cost-optimization budget-check cache-check cache-prewarm cache-stats cache-cleanup log-analyze deploy-parallel predict predict-setup

SCRIPTS_DIR := scripts
ENVIRONMENT ?= dev
CONFIRM_COST ?= no
DEBUG ?= false

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
	@echo "Pre-execution Validation:"
	@echo "  make validate        → Run comprehensive validation"
	@echo "  make validate-quick  → Run quick validation (dry-run mode)"
	@echo ""
	@echo "Optimization Tools:"
	@echo "  make cache-check     → Check model cache status"
	@echo "  make cache-prewarm   → Pre-warm model cache"
	@echo "  make cache-stats     → Show cache statistics"
	@echo "  make log-analyze     → Run enhanced log analysis"
	@echo ""
	@echo "Advanced Deployment:"
	@echo "  make deploy-parallel → Deploy using parallel pipeline (50% faster)"
	@echo "  make predict         → Run predictive diagnostics"
	@echo "  make predict-setup   → Set up predictive monitoring"
	@echo "  make validate-cost   → Run cost validation with custom params"
	@echo "  make dry-run         → Simulate deployment without costs"
	@echo "  make test-connectivity → Test network and API connectivity"
	@echo ""
	@echo "Cost Analysis:"
	@echo "  make cost-simulate   → Run detailed cost simulation"
	@echo "  make cost-scenarios  → Show cost scenarios table"
	@echo "  make cost-optimization → Show cost optimization tips"
	@echo "  make budget-check    → Validate against budget limits"
	@echo ""
	@echo "Session Tracking:"
	@echo "  make session-init    → Initialize session tracking"
	@echo "  make session-summary → Show current session summary"
	@echo "  make session-compare → Compare with previous sessions"
	@echo ""
	@echo "Environment:"
	@echo "  ENVIRONMENT=$(ENVIRONMENT)"
	@echo "  CONFIRM_COST=$(CONFIRM_COST)"
	@echo "  DEBUG=$(DEBUG)"
	@echo ""
	@echo "Examples:"
	@echo "  make provision CONFIRM_COST=yes"
	@echo "  make discover"
	@echo "  make install CONFIRM_COST=yes"
	@echo "  make troubleshoot DEBUG=true"
	@echo "  make cleanup"
	@echo "  make teardown"

discover:
	@echo "[NIM-OKE] Running discovery..."
	@DEBUG=$(DEBUG) $(SCRIPTS_DIR)/discover.sh

prereqs:
	@echo "[NIM-OKE] Checking prerequisites..."
	@$(SCRIPTS_DIR)/prereqs.sh

install: prereqs
	@echo "[NIM-OKE] Installing NIM..."
	@ENVIRONMENT=$(ENVIRONMENT) CONFIRM_COST=$(CONFIRM_COST) DEBUG=$(DEBUG) $(SCRIPTS_DIR)/deploy.sh

verify:
	@echo "[NIM-OKE] Verifying deployment..."
	@$(SCRIPTS_DIR)/verify.sh

operate:
	@echo "[NIM-OKE] Operational commands..."
	@$(SCRIPTS_DIR)/operate.sh

troubleshoot:
	@echo "[NIM-OKE] Running troubleshooting..."
	@DEBUG=$(DEBUG) $(SCRIPTS_DIR)/troubleshoot.sh

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

# Pre-execution validation targets
validate:
	@echo "[NIM-OKE] Running comprehensive validation..."
	@$(SCRIPTS_DIR)/pre-execution-validation.sh

validate-quick:
	@echo "[NIM-OKE] Running quick validation..."
	@DRY_RUN=true $(SCRIPTS_DIR)/pre-execution-validation.sh

validate-cost:
	@echo "[NIM-OKE] Running cost validation..."
	@$(SCRIPTS_DIR)/pre-execution-validation.sh $(DURATION) $(GPU_COUNT)

dry-run:
	@echo "[NIM-OKE] Running dry-run simulation..."
	@DRY_RUN=true $(SCRIPTS_DIR)/pre-execution-validation.sh
	@echo ""
	@echo "[NIM-OKE] Dry-run complete - no actual deployment performed"

test-connectivity:
	@echo "[NIM-OKE] Testing connectivity..."
	@$(SCRIPTS_DIR)/pre-execution-validation.sh

cost-simulate:
	@echo "[NIM-OKE] Running cost simulation..."
	@$(SCRIPTS_DIR)/cost-simulation.sh

cost-scenarios:
	@echo "[NIM-OKE] Showing cost scenarios..."
	@$(SCRIPTS_DIR)/cost-simulation.sh 0 0 0 scenarios

cost-optimization:
	@echo "[NIM-OKE] Showing cost optimization tips..."
	@$(SCRIPTS_DIR)/cost-simulation.sh 0 0 0 optimization

budget-check:
	@echo "[NIM-OKE] Checking budget..."
	@$(SCRIPTS_DIR)/cost-simulation.sh $(DURATION) $(GPU_COUNT) $(GPU_SHAPE) validate

# Enhanced dry-run and simulation targets
provision-dry-run:
	@echo "[NIM-OKE] Running cluster provisioning dry-run..."
	@$(SCRIPTS_DIR)/provision-dry-run.sh

check-gpu-quota:
	@echo "[NIM-OKE] Checking GPU quota availability..."
	@$(SCRIPTS_DIR)/check-gpu-quota.sh $(GPU_SHAPE) $(OCI_REGION)

simulate-image-cache:
	@echo "[NIM-OKE] Simulating image caching strategies..."
	@$(SCRIPTS_DIR)/simulate-image-cache.sh

# Comprehensive pre-deployment testing
pre-deploy-test:
	@echo "[NIM-OKE] Running comprehensive pre-deployment tests..."
	@$(SCRIPTS_DIR)/pre-execution-validation.sh
	@echo ""
	@$(SCRIPTS_DIR)/provision-dry-run.sh
	@echo ""
	@$(SCRIPTS_DIR)/check-gpu-quota.sh $(GPU_SHAPE) $(OCI_REGION)
	@echo ""
	@$(SCRIPTS_DIR)/simulate-image-cache.sh
	@echo ""
	@$(SCRIPTS_DIR)/cost-simulation.sh $(DURATION) $(GPU_COUNT) $(GPU_SHAPE)

# Quick smoke test validation
smoke-test-validate:
	@echo "[NIM-OKE] Validating smoke test readiness..."
	@DRY_RUN=true $(SCRIPTS_DIR)/pre-execution-validation.sh 5 1
	@$(SCRIPTS_DIR)/check-gpu-quota.sh VM.GPU.A10.1 $(OCI_REGION)
	@$(SCRIPTS_DIR)/cost-simulation.sh 5 1 VM.GPU.A10.1 validate

# NIM-specific testing and optimization
simulate-nim-deployment:
	@echo "[NIM-OKE] Simulating NIM deployment process..."
	@$(SCRIPTS_DIR)/simulate-nim-deployment.sh

detect-nim-failures:
	@echo "[NIM-OKE] Detecting NIM-specific failure patterns..."
	@$(SCRIPTS_DIR)/detect-nim-failures.sh

optimize-rapid-iteration:
	@echo "[NIM-OKE] Analyzing rapid iteration optimization..."
	@$(SCRIPTS_DIR)/optimize-rapid-iteration.sh

# Model cache management
cache-check:
	@echo "[NIM-OKE] Checking model cache status..."
	@$(SCRIPTS_DIR)/model-cache-manager.sh check

cache-prewarm:
	@echo "[NIM-OKE] Pre-warming model cache..."
	@PREWARM_CACHE=yes $(SCRIPTS_DIR)/model-cache-manager.sh prewarm

cache-stats:
	@echo "[NIM-OKE] Model cache statistics..."
	@$(SCRIPTS_DIR)/model-cache-manager.sh stats

cache-cleanup:
	@echo "[NIM-OKE] Cleaning up expired model cache..."
	@$(SCRIPTS_DIR)/model-cache-manager.sh cleanup

# Enhanced log analysis
log-analyze:
	@echo "[NIM-OKE] Running enhanced log analysis..."
	@$(SCRIPTS_DIR)/log-analyzer.sh $(NAMESPACE)

# Parallel deployment pipeline
deploy-parallel:
	@echo "[NIM-OKE] Starting parallel deployment pipeline..."
	@$(SCRIPTS_DIR)/deploy-parallel.sh

# Predictive diagnostics
predict:
	@echo "[NIM-OKE] Running predictive diagnostics..."
	@$(SCRIPTS_DIR)/predictive-diagnostics.sh

predict-setup:
	@echo "[NIM-OKE] Setting up predictive monitoring..."
	@$(SCRIPTS_DIR)/predictive-diagnostics.sh && kubectl apply -f /tmp/nim-monitoring-config.yaml || true

# Comprehensive NIM smoke testing
nim-smoke-test:
	@echo "[NIM-OKE] Running comprehensive NIM smoke test validation..."
	@$(SCRIPTS_DIR)/pre-execution-validation.sh 5 1
	@echo ""
	@$(SCRIPTS_DIR)/simulate-nim-deployment.sh 100 $(OCI_REGION) true
	@echo ""
	@$(SCRIPTS_DIR)/optimize-rapid-iteration.sh
	@echo ""
	@$(SCRIPTS_DIR)/cost-simulation.sh 5 1 VM.GPU.A10.1 validate

test-inference:
	@echo "[NIM-OKE] Testing inference API..."
	@$(SCRIPTS_DIR)/verify.sh
	@echo ""
	@echo "Run API tests manually or check 'make operate' for commands"

validate-deployment: prereqs verify
	@echo "[NIM-OKE] Deployment validation complete"

status:
	@echo "[NIM-OKE] Current deployment status..."
	@kubectl get all -l app.kubernetes.io/name=nvidia-nim --all-namespaces 2>/dev/null || echo "No NIM resources found"

logs:
	@echo "[NIM-OKE] Fetching logs..."
	@kubectl logs -l app.kubernetes.io/name=nvidia-nim --tail=100 -n default 2>/dev/null || echo "No logs available"

