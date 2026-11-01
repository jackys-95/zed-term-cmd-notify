.DEFAULT_GOAL := build

CARGO ?= cargo
XCODEBUILD ?= xcodebuild
XCRUN ?= xcrun

XCODE_PROJECT := macos/NotificationHelper.xcodeproj
XCODE_SCHEME := NotificationHelper
DERIVED_DATA ?= .build/DerivedData
PROTOCOL_INTEROP_DIR := .build/protocol-interop

.PHONY: build test rust-build rust-test macos-build macos-test protocol-interop

build: rust-build macos-build

test: rust-test macos-test protocol-interop

rust-build:
	$(CARGO) build --workspace

rust-test:
	$(CARGO) test --workspace

macos-build:
	$(XCODEBUILD) -project "$(XCODE_PROJECT)" -scheme "$(XCODE_SCHEME)" -destination 'platform=macOS' -derivedDataPath "$(DERIVED_DATA)" build CODE_SIGNING_ALLOWED=NO

macos-test:
	$(XCODEBUILD) -project "$(XCODE_PROJECT)" -scheme "$(XCODE_SCHEME)" -destination 'platform=macOS' -derivedDataPath "$(DERIVED_DATA)" test CODE_SIGNING_ALLOWED=NO

protocol-interop:
	mkdir -p "$(PROTOCOL_INTEROP_DIR)"
	$(CARGO) run --quiet -p zed-notify-local-client --example protocol-interop -- emit-requests "$(PROTOCOL_INTEROP_DIR)"
	mkdir -p "$(PROTOCOL_INTEROP_DIR)/SwiftModuleCache" "$(PROTOCOL_INTEROP_DIR)/ClangModuleCache"
	$(XCRUN) swiftc -parse-as-library -module-cache-path "$(PROTOCOL_INTEROP_DIR)/SwiftModuleCache" -Xcc -fmodules-cache-path="$(PROTOCOL_INTEROP_DIR)/ClangModuleCache" -o "$(PROTOCOL_INTEROP_DIR)/swift-protocol-interop" macos/NotificationHelper/IPC/NotificationProtocol.swift macos/NotificationHelperTests/Interop/main.swift
	"$(PROTOCOL_INTEROP_DIR)/swift-protocol-interop" "$(PROTOCOL_INTEROP_DIR)"
	$(CARGO) run --quiet -p zed-notify-local-client --example protocol-interop -- verify-responses "$(PROTOCOL_INTEROP_DIR)"
