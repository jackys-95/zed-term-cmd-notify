.DEFAULT_GOAL := build

CARGO ?= cargo
XCODEBUILD ?= xcodebuild

XCODE_PROJECT := macos/NotificationHelper.xcodeproj
XCODE_SCHEME := NotificationHelper
DERIVED_DATA ?= .build/DerivedData

.PHONY: build test rust-build rust-test macos-build macos-test

build: rust-build macos-build

test: rust-test macos-test

rust-build:
	$(CARGO) build --workspace

rust-test:
	$(CARGO) test --workspace

macos-build:
	$(XCODEBUILD) -project "$(XCODE_PROJECT)" -scheme "$(XCODE_SCHEME)" -destination 'platform=macOS' -derivedDataPath "$(DERIVED_DATA)" build CODE_SIGNING_ALLOWED=NO

macos-test:
	$(XCODEBUILD) -project "$(XCODE_PROJECT)" -scheme "$(XCODE_SCHEME)" -destination 'platform=macOS' -derivedDataPath "$(DERIVED_DATA)" test CODE_SIGNING_ALLOWED=NO
