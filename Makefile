CONFIGURATION ?= debug
SIMULATOR_UDID ?=

.PHONY: help build run test ios ios-run ipa release
help:
	@echo 'make build/run       Build or launch the Mac app (CONFIGURATION=debug|release)'
	@echo 'make test            Run core workflow tests'
	@echo 'make ios/ios-run     Build or launch the iPhone 17 Pro Simulator (SIMULATOR_UDID=...)'
	@echo 'make ipa             Build an unsigned iOS Release IPA'
	@echo 'make release         Build versioned Mac ZIP, iOS IPA and checksums'

build:
	Scripts/build-app.sh $(CONFIGURATION)
run:
	Scripts/compile_and_run.sh $(CONFIGURATION)
test:
	swift test --no-parallel --filter 'VoxlineCoreTests|VoxlineTranslationTests|VoxlineWorkflowTests|VoxlineAppTests'
ios:
	Scripts/build-ios.sh simulator $(CONFIGURATION)
ios-run:
	Scripts/compile_and_run_ios.sh "$(SIMULATOR_UDID)" $(CONFIGURATION)
ipa:
	Scripts/build-ios-ipa.sh release
release:
	Scripts/build-release.sh all
