APP := .build/Iridium Live.app
BINARY := $(APP)/Contents/MacOS/Iridium Live
STAMP := .build/.app
SOURCES := $(wildcard Sources/*.swift) $(wildcard Packages/ModelCatalog/Sources/*/*.swift)
ENGINE := live.py segmenter.py asr.py cleanup.py archive.py downloads.py
FONT := fonts/TikTokSans.ttf
BRANDS := $(wildcard Packages/ModelCatalog/Brands/*)
CERT := Iridium Live Dev

MKDIR := Packages/MeetingKit
MKSOURCES := $(wildcard $(MKDIR)/Sources/MeetingKit/*/*.swift) $(MKDIR)/Package.swift
MKLIB := $(MKDIR)/.build/release/libMeetingKit.a
MKFLAGS := -I $(MKDIR)/.build/release/Modules \
  -Xcc -fmodule-map-file=$(MKDIR)/.build/checkouts/FluidAudio/Sources/FastClusterWrapper/include/module.modulemap \
  -Xcc -fmodule-map-file=$(MKDIR)/.build/checkouts/FluidAudio/Sources/MachTaskSelfWrapper/include/module.modulemap \
  -L $(MKDIR)/.build/release -lMeetingKit -lc++

FOUND := $(shell security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)".*/\1/p' | grep -x "$(CERT)" | sed -n 1p)
SIGN := $(if $(FOUND),$(FOUND),-)

app: $(STAMP)

$(STAMP): $(SOURCES) $(MKLIB) Resources/Info.plist Resources/AppIcon.icns $(ENGINE) $(FONT) $(BRANDS)
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	swiftc -O -swift-version 6 $(SOURCES) $(MKFLAGS) -o "$(BINARY)"
	@cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	@printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	@cp Resources/AppIcon.icns $(ENGINE) $(FONT) "$(APP)/Contents/Resources/"
	@rm -rf "$(APP)/Contents/Resources/Brands"
	@cp -R Packages/ModelCatalog/Brands "$(APP)/Contents/Resources/Brands"
	@codesign --force --sign "$(SIGN)" --identifier com.albastov.iridium-live "$(APP)"
	@touch $@

$(MKLIB): $(MKSOURCES)
	swift build -c release --package-path $(MKDIR) --product MeetingKit

.PHONY: app run check install icon cert clean

run: $(STAMP)
	"$(BINARY)" $(if $(WAV),--wav "$(WAV)")

check: $(STAMP)
	@"$(BINARY)" --check

install: $(STAMP)
	rm -rf "/Applications/Iridium Live.app"
	cp -R "$(APP)" /Applications/
	@codesign -dv "/Applications/Iridium Live.app"

icon:
	swiftc -O -swift-version 6 Resources/icon.swift -o .build/icon && .build/icon Resources

cert:
	@openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout /tmp/iridium-cert.key -out /tmp/iridium-cert.pem \
	  -subj "/CN=$(CERT)" -addext "basicConstraints=critical,CA:true" -addext "keyUsage=critical,digitalSignature" \
	  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
	@openssl pkcs12 -export -legacy -name "$(CERT)" -inkey /tmp/iridium-cert.key -in /tmp/iridium-cert.pem \
	  -out /tmp/iridium-cert.p12 -passout pass:iridium
	security import /tmp/iridium-cert.p12 -k "$$HOME/Library/Keychains/login.keychain-db" -P iridium \
	  -T /usr/bin/codesign -A
	security add-trusted-cert -r trustRoot -p codeSign -k "$$HOME/Library/Keychains/login.keychain-db" /tmp/iridium-cert.pem
	-security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "$(CERT)" \
	  "$$HOME/Library/Keychains/login.keychain-db"
	@rm -f /tmp/iridium-cert.key /tmp/iridium-cert.pem /tmp/iridium-cert.p12
	@security find-identity -v -p codesigning
	@echo "Rebuild once (make) so the app carries the new identity; macOS asks for its grants one last time."

clean:
	rm -rf .build

