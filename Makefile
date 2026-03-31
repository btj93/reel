.PHONY: run

run:
	-pkill -x ScrollWM
	bash scripts/bundle.sh
	open .build/bundled/ScrollWM.app
