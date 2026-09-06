APP_NAME := VoiceInput
APP_BUNDLE := $(APP_NAME).app
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DMG := $(APP_NAME)-$(VERSION).dmg
SWIFT_FLAGS ?=
# Local certificate pin; intentionally excluded from version control.
-include .signing.local.mk
SIGNING_IDENTITY ?=
ALLOW_ADHOC ?= 0
ALLOW_RUNNING_UPDATE ?= 0
export SIGNING_IDENTITY ALLOW_ADHOC ALLOW_RUNNING_UPDATE

.PHONY: build dev-build test test-signing run install clean dmg

build:
	swift build -c release $(SWIFT_FLAGS)
	$(eval BUILD_DIR := $(shell swift build -c release $(SWIFT_FLAGS) --show-bin-path))
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp -R $(BUILD_DIR)/VoiceInput_VoiceInput.bundle $(APP_BUNDLE)/Contents/Resources/
	cp Assets/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/
	cp Info.plist $(APP_BUNDLE)/Contents/
	bash scripts/sign-app.sh "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

dev-build:
	$(MAKE) build SIGNING_IDENTITY=- ALLOW_ADHOC=1

test-signing:
	bash scripts/tests/signing.test.sh

test:
	swift test --disable-xctest $(SWIFT_FLAGS)

run: build
	open $(APP_BUNDLE)

install: build
	bash scripts/install-app.sh "$(APP_BUNDLE)"

clean:
	swift package clean
	rm -rf $(APP_BUNDLE) $(APP_NAME)-*.dmg

# Distributable disk image: app + /Applications symlink, compressed.
dmg: build
	rm -f $(DMG)
	rm -rf .dmg-staging
	mkdir .dmg-staging
	cp -r $(APP_BUNDLE) .dmg-staging/
	ln -s /Applications .dmg-staging/Applications
	hdiutil create -volname "$(APP_NAME) $(VERSION)" -srcfolder .dmg-staging \
		-ov -format UDZO $(DMG)
	rm -rf .dmg-staging
	@echo "Built $(DMG)"
