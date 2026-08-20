# Build from source, the primary distribution path.
#
# An app compiled on the user's own machine never receives the
# com.apple.quarantine attribute, so Gatekeeper never blocks it and no Apple
# Developer Program membership is required.

APP     := algobuddy.app
BINARY  := AlgobuddyApp
CONFIG  := release
BUILD   := .build/$(CONFIG)/$(BINARY)
PREFIX  ?= /Applications

# The git tag is the single source of truth for the version: `bundle` stamps it
# into the installed Info.plist, so the number a user sees can never drift from
# what was tagged. On an untagged checkout git describe appends a distance and
# commit hash to the nearest tag, or falls back to the bare hash before the
# first tag exists, which is exactly what a bug report from a development build
# should carry.
VERSION      := $(shell git describe --tags --always --dirty 2>/dev/null | sed 's/^v//')
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)

SWIFT_SOURCES := Sources Tests Tools

.PHONY: all build bundle icon install uninstall purge run test lint format check clean hooks

all: bundle

build:
	swift build -c $(CONFIG)

test:
	swift test

# Apple's swift-format ships with the Swift toolchain, so contributors need
# nothing installed, which keeps the zero-dependency promise in Package.swift.
# Style lives in .swift-format.
lint:
	swift format lint --strict --recursive $(SWIFT_SOURCES)

format:
	swift format --in-place --recursive $(SWIFT_SOURCES)

# What CI runs.
check: lint test

# Points git at the repo's commit-msg hook, which enforces Conventional
# Commits. Opt-in rather than automatic, because it edits the contributor's
# git configuration for this checkout.
hooks:
	git config core.hooksPath .githooks
	chmod +x .githooks/commit-msg
	@echo "Conventional Commits hook enabled"

# Regenerated whenever the generator changes, so the icon tracked in the repo
# stays reproducible from source rather than being an opaque binary nobody can
# regenerate. One run produces both the .icns the bundle needs and the PNG the
# README shows, so the two cannot drift apart.
Resources/algobuddy.icns: Tools/make-icon.swift
	swift Tools/make-icon.swift
	cp build/algobuddy.iconset/icon_256x256.png Resources/icon-256.png

icon: Resources/algobuddy.icns

# Assemble the .app wrapper. The bundle is required, not cosmetic:
# UNUserNotificationCenter needs a bundle identifier, and LSUIElement in
# Info.plist is what keeps the app out of the Dock.
bundle: build Resources/algobuddy.icns
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BUILD) $(APP)/Contents/MacOS/algobuddy
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/algobuddy.icns $(APP)/Contents/Resources/algobuddy.icns
	# Stamped before signing, because the signature seals Info.plist.
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" $(APP)/Contents/Info.plist
	plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" $(APP)/Contents/Info.plist
	# Ad-hoc signature: does not satisfy Gatekeeper, but macOS expects a valid
	# one.
	codesign --force --sign - $(APP)
	@echo "Built $(APP)"

# Quit a running instance and wait for it to actually exit. `pkill` returns on
# signal delivery, not on process death, so without the wait the recipe races
# the dying app: `install` would replace the bundle under a live process, and
# `purge` could delete the preferences domain before the final write lands.
define QUIT_APP
	-pkill -x algobuddy
	-@i=0; while pgrep -x algobuddy >/dev/null && [ $$i -lt 50 ]; do sleep 0.1; i=$$((i+1)); done
endef

install: bundle
	$(QUIT_APP)
	rm -rf "$(PREFIX)/$(APP)"
	cp -R $(APP) "$(PREFIX)/"
	@echo "Installed to $(PREFIX)/$(APP)"

# Quit first: deleting the bundle out from under a running menu bar agent leaves
# the process alive with nothing behind it. `pkill -x` matches the executable
# name exactly, where AppleScript would raise an Automation permission prompt in
# the middle of an uninstall.
#
# Settings survive, so reinstalling picks up where it left off. Deregistering
# the login item is not done here and cannot be: `SMAppService` identifies the
# item by the app's own bundle, so only the app can withdraw it. Untick Open at
# login before uninstalling, or clear the leftover entry in System Settings.
uninstall:
	$(QUIT_APP)
	rm -rf "$(PREFIX)/$(APP)"

# Everything `uninstall` does, plus the stored address and preferences.
purge: uninstall
	-defaults delete dev.algobuddy.app

# Launch the bundled app rather than the bare binary, so notifications work.
run: bundle
	open $(APP)

clean:
	rm -rf .build build $(APP)
