.PHONY: run, run-debug

run-debug:
	-pkill -x Reel
	bash scripts/bundle.sh
	.build/debug/Reel 2>&1

run:
	-pkill -x Reel
	bash scripts/bundle.sh
	open .build/bundled/Reel.app
