# Macinto build. `make app` -> build/Macinto.app, `make dmg` -> build/Macinto-<version>.dmg
VERSION    := $(shell cat VERSION)
APP_NAME   := Macinto
BUNDLE_ID  := sh.macinto.app
BUILD      := build
APP        := $(BUILD)/$(APP_NAME).app
DEV_APP    := $(BUILD)/debug/$(APP_NAME).app
DMG        := $(BUILD)/$(APP_NAME)-$(VERSION).dmg
ICONSET    := $(BUILD)/AppIcon.iconset
ICNS       := $(BUILD)/AppIcon.icns

# Signing identity: a real "Developer ID Application: ..." can be passed in. Default is the local
# self-signed cert (see `make cert`) if present, else ad-hoc ("-").
LOCAL_IDENTITY := macinto local signing
SIGN_IDENTITY  ?= $(shell security find-identity -p codesigning 2>/dev/null | grep -q '"$(LOCAL_IDENTITY)"' && echo "$(LOCAL_IDENTITY)" || echo "-")
# Secure timestamps only make sense for Developer ID signing.
TIMESTAMP      = $(if $(findstring Developer ID,$(SIGN_IDENTITY)),--timestamp,--timestamp=none)

# Release builds are universal (arm64 + x86_64).
ARCH_FLAGS     ?= --arch arm64 --arch x86_64
SOURCES        := $(shell find Sources -name '*.swift') Package.swift

.PHONY: all app dev-app dmg sign cert verify notarize run run-dev clean

all: app

$(ICNS): scripts/make-icon.swift
	@mkdir -p $(BUILD)
	swift scripts/make-icon.swift $(ICONSET)
	iconutil -c icns $(ICONSET) -o $(ICNS)

# bundle(dir, binary)
define bundle
	rm -rf "$(1)"
	mkdir -p "$(1)/Contents/MacOS" "$(1)/Contents/Resources"
	cp "$(2)" "$(1)/Contents/MacOS/$(APP_NAME)"
	sed 's/__VERSION__/$(VERSION)/g' Resources/Info.plist > "$(1)/Contents/Info.plist"
	printf 'APPL????' > "$(1)/Contents/PkgInfo"
	cp macinto.sh "$(1)/Contents/Resources/macinto.sh"
	chmod 755 "$(1)/Contents/Resources/macinto.sh"
	cp $(ICNS) "$(1)/Contents/Resources/AppIcon.icns"
	plutil -lint "$(1)/Contents/Info.plist" >/dev/null
	@echo "signing $(1) with identity: $(SIGN_IDENTITY)"
	codesign --force --deep --options runtime $(TIMESTAMP) --identifier $(BUNDLE_ID) --sign "$(SIGN_IDENTITY)" "$(1)"
	codesign --verify --strict --verbose=1 "$(1)"
endef

app: $(ICNS) $(SOURCES) macinto.sh Resources/Info.plist VERSION
	swift build -c release $(ARCH_FLAGS)
	$(call bundle,$(APP),$(shell swift build -c release $(ARCH_FLAGS) --show-bin-path)/$(APP_NAME))
	@echo "built $(APP) ($(VERSION))"

# Debug build: includes the dev-only --enable-for-testing launch argument. Never ship this.
dev-app: $(ICNS) $(SOURCES) macinto.sh Resources/Info.plist VERSION
	swift build -c debug
	$(call bundle,$(DEV_APP),$(shell swift build -c debug --show-bin-path)/$(APP_NAME))
	@echo "built $(DEV_APP) (DEBUG)"

DMG_BG := $(BUILD)/dmg-background.tiff

$(DMG_BG): scripts/make-dmg-background.swift
	@mkdir -p $(BUILD)/dmg-bg
	swift scripts/make-dmg-background.swift $(BUILD)/dmg-bg
	tiffutil -cathidpicheck $(BUILD)/dmg-bg/background.png $(BUILD)/dmg-bg/background@2x.png -out $(DMG_BG)

# Styled installer window (background arrow, big icons) via dmgbuild; needs uv.
dmg: app $(DMG_BG) scripts/dmg-settings.py
	rm -f "$(DMG)"
	uvx --quiet dmgbuild -s scripts/dmg-settings.py -D app="$(APP)" -D background="$(DMG_BG)" \
		-D icon="$(ICNS)" "$(APP_NAME) $(VERSION)" "$(DMG)"
	@if [ "$(SIGN_IDENTITY)" != "-" ]; then codesign --force $(TIMESTAMP) --sign "$(SIGN_IDENTITY)" "$(DMG)"; fi
	@echo "built $(DMG)"

# Create the local self-signed signing certificate in the login keychain.
cert:
	scripts/make-signing-cert.sh "$(LOCAL_IDENTITY)"

verify:
	codesign --display --verbose=2 "$(APP)"
	codesign --display -r- "$(APP)"

# Requires a Developer ID identity and a stored notary profile:
#   xcrun notarytool store-credentials macinto-notary --apple-id ... --team-id ...
#   make dmg SIGN_IDENTITY="Developer ID Application: Kyle Wild (TEAMID)" && make notarize
notarize:
	@case "$(SIGN_IDENTITY)" in *"Developer ID"*) ;; *) echo "notarize needs SIGN_IDENTITY=\"Developer ID Application: ...\""; exit 1;; esac
	xcrun notarytool submit "$(DMG)" --keychain-profile macinto-notary --wait
	xcrun stapler staple "$(DMG)"
	xcrun stapler validate "$(DMG)"

run: app
	open "$(APP)"

run-dev: dev-app
	open "$(DEV_APP)"

clean:
	rm -rf $(BUILD) .build
