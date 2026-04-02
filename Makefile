.PHONY: run, run-debug

run-debug:
	-pkill -x ScrollWM
	bash scripts/bundle.sh
	.build/debug/ScrollWM 2>&1

run:
	-pkill -x ScrollWM
	bash scripts/bundle.sh
	open .build/bundled/ScrollWM.app
