.PHONY: run run-debug smoke smoke-check

run-debug:
	-pkill -x Reel
	bash scripts/bundle.sh
	.build/debug/Reel 2>&1

run:
	-pkill -x Reel
	bash scripts/bundle.sh
	open .build/bundled/Reel.app

# Layer-3 IPC smoke suite. STOPS your live Reel and opens real windows — opt-in:
#     REEL_E2E_CONFIRM=1 make smoke
# The script refuses to run unless REEL_E2E_CONFIRM=1 (inherited from the env).
smoke:
	swift build
	bash Tests/Smoke/smoke.sh

# Lint + build only — never launches anything, never touches a window. Runs
# bash -n on both scripts, shellcheck if installed, a dry-run walk that
# validates every jq filter against embedded fixtures, then a clean build.
smoke-check:
	bash -n Tests/Smoke/lib.sh
	bash -n Tests/Smoke/smoke.sh
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -x Tests/Smoke/smoke.sh Tests/Smoke/lib.sh; \
	else \
		echo "shellcheck not installed — skipping lint (bash -n passed)"; \
	fi
	REEL_E2E_CONFIRM=1 SMOKE_DRY_RUN=1 bash Tests/Smoke/smoke.sh
	swift build
