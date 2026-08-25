.PHONY: internal-testflight release-device-test

internal-testflight:
	@bash scripts/internal_testflight.sh

release-device-test:
	@bash scripts/prepare_release_device_test.sh
