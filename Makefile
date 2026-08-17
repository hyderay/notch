.PHONY: build release app install uninstall run test lint clean check-resources

SHELL := /bin/bash
APP := .build/Notch.app
PREFIX ?= $(HOME)/.local/bin

build:
	swift build

release:
	swift build -c release

app: release
	./scripts/build-app.sh

install: app
	@rm -rf /Applications/Notch.app
	cp -R $(APP) /Applications/Notch.app
	@mkdir -p $(PREFIX)
	@ln -sf /Applications/Notch.app/Contents/MacOS/notchctl $(PREFIX)/notchctl
	@echo "Installed /Applications/Notch.app and $(PREFIX)/notchctl"
	@echo "Launch with: open -a Notch"

uninstall:
	-pkill -x Notch || true
	rm -rf /Applications/Notch.app
	rm -f $(PREFIX)/notchctl
	rm -f $(HOME)/.notch/notch.sock

# Foreground run with logging, for development.
run: build
	NOTCH_DEBUG=1 swift run NotchApp

# `swift build --build-tests` does not put the swift-testing macro plugin on the
# compiler's plugin path under Command Line Tools, so point at it explicitly.
DEVELOPER_DIR := $(shell xcode-select -p)
TESTING_MACROS := $(DEVELOPER_DIR)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
TEST_FLAGS := $(if $(wildcard $(TESTING_MACROS)),-Xswiftc -load-plugin-library -Xswiftc $(TESTING_MACROS),)

test:
	swift build --build-tests $(TEST_FLAGS)
	./scripts/prepare-testing.sh Debug
	swift test $(TEST_FLAGS)

# Idle CPU, RSS stability, and `leaks` against the running app.
check-resources:
	./scripts/check-resources.sh

clean:
	swift package clean
	rm -rf $(APP)
