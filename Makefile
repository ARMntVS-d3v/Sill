# Build outside the repo: ~/Documents is synced by iCloud, its file provider sets the
# com.apple.FinderInfo xattr on .app, and codesign fails with "detritus not allowed".
BUILD_DIR=$(HOME)/Library/Caches/sill-build
APP=$(BUILD_DIR)/Build/Products/Debug/Sill.app

.PHONY: build run clean

# Signing. If the keychain has the self-signed "Sill Dev" identity, sign with it, so the
# signature stays the same across builds: TCC permissions (Calendar) don't get reset
# and Keychain doesn't ask for a password after every rebuild. No certificate — fall
# back to ad-hoc as before; see docs/sill.md for how to create one
HAS_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -c 'Sill Dev')
SIGN := $(if $(filter-out 0,$(HAS_IDENTITY)),CODE_SIGN_IDENTITY="Sill Dev" CODE_SIGN_STYLE=Manual,)

build:
	xcodegen
	xcodebuild -project Sill.xcodeproj -scheme Sill -configuration Debug -derivedDataPath $(BUILD_DIR) $(SIGN) build

# Launch only via open, never the binary directly. A process launched from the terminal
# inherits the terminal as its "responsible" process, and all TCC permission requests
# go to it: System Settings shows the terminal instead of Sill, and the permission
# prompt never appears at all (tccd logs "requires entitlement ... missing for
# responsible=<terminal>"). Through open, LaunchServices starts the process and Sill
# is responsible for itself.
run: build
	open -a $(APP)

# Logs go to the unified log when launched via open, not to the terminal:
logs:
	log stream --predicate 'process == "Sill"' --style compact

clean:
	rm -rf $(BUILD_DIR) Sill.xcodeproj
