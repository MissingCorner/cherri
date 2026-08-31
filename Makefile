# Cherri — live meeting interpreter for macOS
#
# Targets:
#   make            build driver + app
#   make driver     build the virtual audio driver (.driver bundle)
#   make app        build the SwiftUI app (.app bundle)
#   make install-driver   copy driver to /Library/Audio/Plug-Ins/HAL (needs sudo)
#   make uninstall-driver remove the driver (needs sudo)
#   make run        build and launch the app
#   make clean

VERSION    := 1.0.0
BUILD      := build
ARCH       := $(shell uname -m)
# Prefer a real signing identity (stable across builds, so keychain access
# sticks after one "Always Allow"); fall back to ad-hoc. Create one with
# scripts/make-signing-cert.sh.
SIGN_ID    := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"[^"]*"' | tr -d '"')
ifeq ($(SIGN_ID),)
SIGN_ID    := -
endif
TARGET     := $(ARCH)-apple-macosx26.0
SDK        := $(shell xcrun --show-sdk-path)

DRIVER_NAME    := MIAgentAudio
DRIVER_BUNDLE  := $(BUILD)/$(DRIVER_NAME).driver
DRIVER_BIN     := $(DRIVER_BUNDLE)/Contents/MacOS/$(DRIVER_NAME)
DRIVER_SRC     := Driver/MIAgentAudio.c
HAL_DIR        := /Library/Audio/Plug-Ins/HAL

APP_NAME       := Cherri
APP_BUNDLE     := $(BUILD)/$(APP_NAME).app
APP_BIN        := $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
APP_SRCS       := $(wildcard App/Sources/*.swift)

.PHONY: all driver app run clean install-driver uninstall-driver package notarize

all: driver app

# ------------------------------------------------------------------ driver ---

driver: $(DRIVER_BIN)

$(DRIVER_BIN): $(DRIVER_SRC) Driver/Info.plist
	mkdir -p $(DRIVER_BUNDLE)/Contents/MacOS
	cp Driver/Info.plist $(DRIVER_BUNDLE)/Contents/Info.plist
	clang -bundle -O2 -Wall -Wextra \
		-target $(TARGET) -isysroot $(SDK) \
		-framework CoreAudio -framework CoreFoundation \
		-o $(DRIVER_BIN) $(DRIVER_SRC)
	codesign --force --sign "$(SIGN_ID)" $(DRIVER_BUNDLE)
	@echo "Built $(DRIVER_BUNDLE)"

install-driver: driver
	sudo rm -rf $(HAL_DIR)/$(DRIVER_NAME).driver
	sudo cp -R $(DRIVER_BUNDLE) $(HAL_DIR)/
	sudo killall -9 coreaudiod || true
	@echo ""
	@echo "Driver installed. Core Audio restarted."
	@echo "You should now see 'Interpreter Line Output' and 'Interpreter Line Input'"
	@echo "in System Settings > Sound."

uninstall-driver:
	sudo rm -rf $(HAL_DIR)/$(DRIVER_NAME).driver
	sudo killall -9 coreaudiod || true
	@echo "Driver removed."

# --------------------------------------------------------------------- app ---

app: $(APP_BIN)

$(APP_BIN): $(APP_SRCS) App/Resources/Info.plist
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	cp App/Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp App/Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	printf 'APPL????' > $(APP_BUNDLE)/Contents/PkgInfo
	swiftc -O -parse-as-library \
		-target $(TARGET) -sdk $(SDK) \
		-framework SwiftUI -framework CoreAudio -framework AudioToolbox -framework Security \
		-o $(APP_BIN) $(APP_SRCS)
	codesign --force --sign "$(SIGN_ID)" $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

run: app
	open $(APP_BUNDLE)

# ----------------------------------------------------------------- release ---

# Signed installer pkg (app -> /Applications, driver -> HAL + coreaudiod
# restart). Uses Developer ID identities when available, else the best local
# identity with a warning.
package: all
	VERSION=$(VERSION) ./scripts/package.sh

# Notarize + staple the pkg. Needs a Developer ID-signed package and:
#   APPLE_ID=you@example.com TEAM_ID=XXXXXXXXXX APP_PASSWORD=app-specific-pw
notarize:
	@test -n "$(APPLE_ID)" -a -n "$(TEAM_ID)" -a -n "$(APP_PASSWORD)" || 		{ echo "Set APPLE_ID, TEAM_ID and APP_PASSWORD (app-specific password from appleid.apple.com)."; exit 1; }
	xcrun notarytool submit $(BUILD)/Cherri-$(VERSION).pkg 		--apple-id "$(APPLE_ID)" --team-id "$(TEAM_ID)" --password "$(APP_PASSWORD)" --wait
	xcrun stapler staple $(BUILD)/Cherri-$(VERSION).pkg
	@echo "Notarized and stapled: $(BUILD)/Cherri-$(VERSION).pkg"

clean:
	rm -rf $(BUILD)
