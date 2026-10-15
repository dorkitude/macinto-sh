# Macinto.sh build.
#   make app       -> build/Macinto.sh.app (universal, release; includes the Rust CLI)
#   make dmg       -> build/Macinto.sh-<version>.dmg
#   make test      -> cargo test + clippy + swift build
#   make notarize  -> notarize + staple the app, rebuild the DMG around it, notarize + staple the DMG
VERSION    := $(shell cat VERSION)
APP_NAME   := Macinto.sh
EXEC_NAME  := Macinto
BUNDLE_ID  := com.dorkitude.macinto.sh
BUILD      := build
APP        := $(BUILD)/$(APP_NAME).app
# Dev build: separate bundle id, name, socket and log, and never the Developer ID, so it can't
# share the release app's privacy grants.
DEV_NAME   := Macinto.sh (Dev)
DEV_ID     := com.dorkitude.macinto.sh.dev
DEV_APP    := $(BUILD)/debug/$(DEV_NAME).app
DMG        := $(BUILD)/$(APP_NAME)-$(VERSION).dmg
ICONSET    := $(BUILD)/AppIcon.iconset
ICNS       := $(BUILD)/AppIcon.icns

# Signing identity, first match wins:
#   1. a "Developer ID Application: ..." identity in the keychain
#   2. the local self-signed "macinto local signing" cert (see `make cert`)
#   3. ad-hoc ("-")
# Override with SIGN_IDENTITY="...".
LOCAL_IDENTITY := macinto local signing
DEVID_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1)
HAS_LOCAL      := $(shell security find-identity -p codesigning 2>/dev/null | grep -q '"$(LOCAL_IDENTITY)"' && echo yes)
SIGN_IDENTITY  ?= $(or $(DEVID_IDENTITY),$(if $(HAS_LOCAL),$(LOCAL_IDENTITY)),-)
# Secure timestamps are required for notarization; they only make sense for Developer ID.
TIMESTAMP      = $(if $(findstring Developer ID,$(SIGN_IDENTITY)),--timestamp,--timestamp=none)
# bundle() signs with $(BUNDLE_SIGN), which is SIGN_IDENTITY for release and DEV_IDENTITY for dev.
DEV_IDENTITY   := $(if $(HAS_LOCAL),$(LOCAL_IDENTITY),-)
NOTARY_PROFILE ?= macinto-notary

# Release builds are universal (arm64 + x86_64).
ARCH_FLAGS     ?= --arch arm64 --arch x86_64
SOURCES        := $(shell find Sources -name '*.swift') Package.swift

# Rust CLI (cli/). Built with rustup's toolchain so both macOS targets are available:
#   rustup target add aarch64-apple-darwin x86_64-apple-darwin
# Homebrew's own rust can sit earlier on PATH, so name rustup's cargo and rustc explicitly.
RUSTUP_TC      ?= stable
CARGO          ?= RUSTC="$(shell rustup which --toolchain $(RUSTUP_TC) rustc)" "$(shell rustup which --toolchain $(RUSTUP_TC) cargo)"
RUST_TARGETS   := aarch64-apple-darwin x86_64-apple-darwin
CLI_SOURCES    := $(shell find cli/src -name '*.rs') cli/Cargo.toml cli/Cargo.lock cli/build.rs VERSION
CLI_BIN        := $(BUILD)/cli/macinto.sh
export MACOSX_DEPLOYMENT_TARGET := 15.0

.PHONY: all app dev-app cli dmg package sign cert verify notarize test run run-dev clean

all: app

$(ICNS): scripts/make-icon.swift
	@mkdir -p $(BUILD)
	swift scripts/make-icon.swift $(ICONSET)
	iconutil -c icns $(ICONSET) -o $(ICNS)

# Universal CLI binary. Cargo can't name a binary "macinto.sh", so it builds macinto_sh and lipo
# writes the final name.
$(CLI_BIN): $(CLI_SOURCES)
	cd cli && $(CARGO) build --release --locked $(addprefix --target ,$(RUST_TARGETS))
	@mkdir -p $(dir $@)
	lipo -create -output $@ $(foreach t,$(RUST_TARGETS),cli/target/$(t)/release/macinto_sh)
	lipo -info $@

cli: $(CLI_BIN)

# bundle(dir, swift binary, bundle id, name, identity)
# Nested code is signed first (the CLI in Contents/Helpers), then the app itself. No --deep.
# Hardened runtime always; secure timestamp only with a Developer ID. No entitlements.
define bundle
	rm -rf "$(1)"
	mkdir -p "$(1)/Contents/MacOS" "$(1)/Contents/Helpers" "$(1)/Contents/Resources"
	cp "$(2)" "$(1)/Contents/MacOS/$(EXEC_NAME)"
	cp "$(CLI_BIN)" "$(1)/Contents/Helpers/macinto.sh"
	sed -e 's/__VERSION__/$(VERSION)/g' -e 's/__BUNDLE_ID__/$(3)/g' -e 's/__NAME__/$(4)/g' \
		Resources/Info.plist > "$(1)/Contents/Info.plist"
	printf 'APPL????' > "$(1)/Contents/PkgInfo"
	cp $(ICNS) "$(1)/Contents/Resources/AppIcon.icns"
	plutil -lint "$(1)/Contents/Info.plist" >/dev/null
	@echo "signing $(1) with identity: $(5)"
	codesign --force --options runtime $(if $(findstring Developer ID,$(5)),--timestamp,--timestamp=none) \
		--identifier $(3).cli --sign "$(5)" "$(1)/Contents/Helpers/macinto.sh"
	codesign --force --options runtime $(if $(findstring Developer ID,$(5)),--timestamp,--timestamp=none) \
		--identifier $(3) --sign "$(5)" "$(1)"
	codesign --verify --strict --deep --verbose=1 "$(1)"
endef

app: $(ICNS) $(SOURCES) $(CLI_BIN) Resources/Info.plist VERSION
	swift build -c release $(ARCH_FLAGS)
	$(call bundle,$(APP),$(shell swift build -c release $(ARCH_FLAGS) --show-bin-path)/$(EXEC_NAME),$(BUNDLE_ID),$(APP_NAME),$(SIGN_IDENTITY))
	@echo "built $(APP) ($(VERSION))"

# Debug build: includes the dev-only --enable-for-testing launch argument. Never ship this.
dev-app: $(ICNS) $(SOURCES) $(CLI_BIN) Resources/Info.plist VERSION
	swift build -c debug
	$(call bundle,$(DEV_APP),$(shell swift build -c debug --show-bin-path)/$(EXEC_NAME),$(DEV_ID),$(DEV_NAME),$(DEV_IDENTITY))
	@echo "built $(DEV_APP) (DEBUG)"

DMG_BG := $(BUILD)/dmg-background.tiff

$(DMG_BG): scripts/make-dmg-background.swift
	@mkdir -p $(BUILD)/dmg-bg
	swift scripts/make-dmg-background.swift $(BUILD)/dmg-bg
	tiffutil -cathidpicheck $(BUILD)/dmg-bg/background.png $(BUILD)/dmg-bg/background@2x.png -out $(DMG_BG)

dmg: app
	$(MAKE) package

# Package the existing $(APP) into a styled DMG (background arrow, big icons) via dmgbuild; needs uv.
package: $(DMG_BG) scripts/dmg-settings.py
	rm -f "$(DMG)"
	uvx --quiet dmgbuild -s scripts/dmg-settings.py -D app="$(APP)" -D background="$(DMG_BG)" \
		-D icon="$(ICNS)" "$(APP_NAME) $(VERSION)" "$(DMG)"
	@if [ "$(SIGN_IDENTITY)" != "-" ]; then codesign --force $(TIMESTAMP) --sign "$(SIGN_IDENTITY)" "$(DMG)"; fi
	@echo "built $(DMG)"

# Create the local self-signed signing certificate in the login keychain.
cert:
	scripts/make-signing-cert.sh "$(LOCAL_IDENTITY)"

verify:
	codesign --verify --strict --deep --verbose=2 "$(APP)"
	codesign -dvv "$(APP)/Contents/Helpers/macinto.sh"
	codesign -dvv "$(APP)"
	codesign --display -r- "$(APP)"

test:
	cd cli && $(CARGO) test --locked
	cd cli && PATH="$(dir $(shell rustup which --toolchain $(RUSTUP_TC) cargo)):$$PATH" $(CARGO) clippy --locked --all-targets -- -D warnings
	swift build

# Needs a Developer ID identity and a notarytool profile:
#   xcrun notarytool store-credentials macinto-notary ...
# The app is notarized and stapled first so it passes Gatekeeper offline after it is copied out
# of the DMG; then the DMG is rebuilt around the stapled app, signed, notarized and stapled.
notarize:
	@case "$(SIGN_IDENTITY)" in *"Developer ID"*) ;; *) echo "notarize needs a Developer ID identity (have: $(SIGN_IDENTITY))"; exit 1;; esac
	$(MAKE) app
	rm -f "$(BUILD)/$(APP_NAME)-$(VERSION).zip"
	ditto -c -k --keepParent "$(APP)" "$(BUILD)/$(APP_NAME)-$(VERSION).zip"
	xcrun notarytool submit "$(BUILD)/$(APP_NAME)-$(VERSION).zip" --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple "$(APP)"
	xcrun stapler validate "$(APP)"
	rm -f "$(BUILD)/$(APP_NAME)-$(VERSION).zip"
	$(MAKE) package
	xcrun notarytool submit "$(DMG)" --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple "$(DMG)"
	xcrun stapler validate "$(DMG)"

run: app
	open "$(APP)"

run-dev: dev-app
	open "$(DEV_APP)"

clean:
	rm -rf $(BUILD) .build cli/target
