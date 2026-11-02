.DEFAULT_GOAL := build

CARGO ?= cargo
XCODEBUILD ?= xcodebuild
XCRUN ?= xcrun

XCODE_PROJECT := macos/NotificationHelper.xcodeproj
XCODE_SCHEME := NotificationHelper
DERIVED_DATA ?= .build/DerivedData
PROTOCOL_INTEROP_DIR := .build/protocol-interop
SOCKET_INTEROP_DIR := .build/socket-interop

.PHONY: build test rust-build rust-test macos-build macos-test protocol-interop socket-interop

build: rust-build macos-build

test: rust-test macos-test protocol-interop socket-interop

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

socket-interop:
	mkdir -p "$(SOCKET_INTEROP_DIR)/SwiftModuleCache" "$(SOCKET_INTEROP_DIR)/ClangModuleCache"
	$(CARGO) build --quiet -p zed-notify-local-client --example socket-interop
	$(XCRUN) swiftc -parse-as-library -module-cache-path "$(SOCKET_INTEROP_DIR)/SwiftModuleCache" -Xcc -fmodules-cache-path="$(SOCKET_INTEROP_DIR)/ClangModuleCache" -o "$(SOCKET_INTEROP_DIR)/swift-socket-interop" macos/NotificationHelper/IPC/NotificationProtocol.swift macos/NotificationHelper/Bindings/BindingRegistry.swift macos/NotificationHelper/IPC/NotificationRequestHandler.swift macos/NotificationHelper/IPC/LocalSocketServer.swift macos/NotificationHelper/IPC/LocalSocketEndpoint.swift macos/NotificationHelper/IPC/LocalSocketConnection.swift macos/NotificationHelper/IPC/LocalSocketOperations.swift macos/NotificationHelperTests/SocketInterop/main.swift
	@set -eu; \
	tmpdir=$$(mktemp -d "$${TMPDIR:-/tmp}/zed-socket-interop.XXXXXX"); \
	chmod 700 "$$tmpdir"; \
	mkdir "$$tmpdir/live" "$$tmpdir/stale" "$$tmpdir/disconnect"; \
	chmod 700 "$$tmpdir/live" "$$tmpdir/stale" "$$tmpdir/disconnect"; \
	live_socket="$$tmpdir/live/helper.sock"; \
	stale_socket="$$tmpdir/stale/helper.sock"; \
	disconnect_socket="$$tmpdir/disconnect/helper.sock"; \
	server_pid=; \
	cleanup() { \
		if [ -n "$$server_pid" ]; then \
			kill "$$server_pid" 2>/dev/null || true; \
			wait "$$server_pid" 2>/dev/null || true; \
		fi; \
		rm -rf "$$tmpdir"; \
	}; \
	trap cleanup EXIT HUP INT TERM; \
	"$(SOCKET_INTEROP_DIR)/swift-socket-interop" interop "$$live_socket" >"$$tmpdir/live.log" 2>&1 & \
	server_pid=$$!; \
	attempt=0; \
	while [ ! -S "$$live_socket" ]; do \
		if ! kill -0 "$$server_pid" 2>/dev/null; then \
			cat "$$tmpdir/live.log"; \
			exit 1; \
		fi; \
		attempt=$$((attempt + 1)); \
		if [ "$$attempt" -ge 160 ]; then \
			cat "$$tmpdir/live.log"; \
			exit 1; \
		fi; \
		sleep 0.05; \
	done; \
	"$(SOCKET_INTEROP_DIR)/swift-socket-interop" expect-live-lock "$$live_socket"; \
	$(CARGO) run --quiet -p zed-notify-local-client --example socket-interop -- "$$live_socket"; \
	wait "$$server_pid"; \
	server_pid=; \
	cat "$$tmpdir/live.log"; \
	"$(SOCKET_INTEROP_DIR)/swift-socket-interop" leave-stale "$$stale_socket"; \
	test -S "$$stale_socket"; \
	"$(SOCKET_INTEROP_DIR)/swift-socket-interop" recover-stale "$$stale_socket"; \
	test ! -e "$$stale_socket"; \
	"$(SOCKET_INTEROP_DIR)/swift-socket-interop" disconnect-interop "$$disconnect_socket" >"$$tmpdir/disconnect.log" 2>&1 & \
	server_pid=$$!; \
	attempt=0; \
	while [ ! -S "$$disconnect_socket" ]; do \
		if ! kill -0 "$$server_pid" 2>/dev/null; then \
			cat "$$tmpdir/disconnect.log"; \
			exit 1; \
		fi; \
		attempt=$$((attempt + 1)); \
		if [ "$$attempt" -ge 160 ]; then \
			cat "$$tmpdir/disconnect.log"; \
			exit 1; \
		fi; \
		sleep 0.05; \
	done; \
	$(CARGO) run --quiet -p zed-notify-local-client --example socket-interop -- disconnect-then-recover "$$disconnect_socket" || { cat "$$tmpdir/disconnect.log"; exit 1; }; \
	wait "$$server_pid"; \
	server_pid=; \
	cat "$$tmpdir/disconnect.log"; \
	test ! -e "$$disconnect_socket"
