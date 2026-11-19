SHELL := /bin/bash
.DEFAULT_GOAL := test-unit-sdk
JOBS ?= 4
X := mise exec
SWIFTFORMAT := $(X) swiftformat@0.64.7 -- swiftformat
SWIFTLINT := $(X) swiftlint@0.65.1 -- swiftlint lint --strict --quiet
.PHONY: lint-sdk lint-workflows test-unit-sdk test-integration-sdk test-ui-sdk lint all-tests

lint-workflows:
	$(X) actionlint@1.7.12 -- actionlint

lint-sdk:
	$(SWIFTFORMAT) Sources Tests Demo Package.swift --lint
	$(SWIFTLINT)
	report=$$(mktemp); trap 'rm -f "$$report"' EXIT; \
		$(SWIFTLINT) --config swiftlint/hosts.yml swiftlint/probe/Probe.swift > "$$report" 2>&1 || true; \
		cat "$$report"; test "$$(grep -cE '\((no_direct_networking|no_network_framework_import)\)' "$$report")" = 4
	$(X) ruff@0.17.5 -- ruff format --check Demo/server Tools/satmux/vectors.py Tools/satmux/relay
	$(X) ruff@0.17.5 -- ruff check Demo/server Tools/satmux/vectors.py Tools/satmux/relay
	swift build -j $(JOBS)
	base=$$(git tag -l 'v[0-9]*' --sort=-v:refname | head -1); test -n "$$base"; swift package -j $(JOBS) diagnose-api-breaking-changes "$$base"

test-unit-sdk:
	swift test -j $(JOBS) --filter "DurableNetworkingTests|DurableNetworkingTestingTests"

test-integration-sdk:
	swift test -j $(JOBS) --filter DurableNetworkingIntegrationTests
	python3 -I -m unittest discover -s Tools/satmux/relay -p 'test_*.py'
	set -o pipefail; python3 -I Tools/satmux/vectors.py | diff -u Tests/DurableNetworkingTests/Unit/SatmuxVectors.swift -

PLATFORM ?= ios
SIMULATOR ?=
UI_SCHEME = DurableNetworkingDemo
UI_PLAN = SDK
UI_DESTINATION = $(if $(filter mac,$(PLATFORM)),platform=macOS,id=$(SIMULATOR))
test-ui-sdk:
	xcodebuild test -project Demo/DurableNetworkingDemo.xcodeproj -scheme $(UI_SCHEME) -testPlan $(UI_PLAN) 		-destination '$(UI_DESTINATION)' -derivedDataPath Demo/build/DerivedData 		-resultBundlePath Demo/build/ui-$(PLATFORM).xcresult -parallel-testing-enabled NO 		-retry-tests-on-failure -test-iterations 2 -jobs $(JOBS)

lint: lint-sdk lint-workflows
all-tests: test-unit-sdk test-integration-sdk test-ui-sdk
