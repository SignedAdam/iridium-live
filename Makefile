# Iridium Live.
#   make                     build Iridium Live.app into .build/ (only when something changed)
#   make run                 build if needed, then run the bundled app from this terminal
#   make run WAV=clip.wav    Record plays the file at real time instead, through the same path
#   make check               print the paths the app resolves (engine, uv, font) and exit
#   make install             put the app in /Applications
#   make icon                redraw Resources/AppIcon.icns
#   make cert                create the stable signing certificate (see "Signing" below)
#   make clean               remove the build
# The app asks for Microphone and Accessibility access itself, on its first launch. `make run` instead borrows the
# terminal's access, which is handy while developing. Ctrl-C quits (notes and history are saved first).
#
# Signing. Without a certificate the app is signed ad-hoc, and an ad-hoc signature changes with every build, so macOS
# treats each build as a new app and forgets the Microphone and Accessibility grants. `make cert` creates a
# self-signed code-signing certificate in the login keychain once; every build then carries the same identity and the
# grants stick. It is a one-off and it asks for a password: macOS will not let a certificate be trusted without it.

APP := .build/Iridium Live.app
BINARY := $(APP)/Contents/MacOS/Iridium Live
STAMP := .build/.app
SOURCES := $(wildcard Sources/*.swift)
ENGINE := live.py segmenter.py asr.py cleanup.py archive.py downloads.py
FONT := fonts/TikTokSans.ttf
CERT := Iridium Live Dev

# The stable certificate when it is there, an ad-hoc signature ("-") until then.
FOUND := $(shell security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)".*/\1/p' | grep -x "$(CERT)" | sed -n 1p)
SIGN := $(if $(FOUND),$(FOUND),-)

$(STAMP): $(SOURCES) Resources/Info.plist Resources/AppIcon.icns $(ENGINE) $(FONT)
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	swiftc -O -swift-version 6 $(SOURCES) -o "$(BINARY)"
	@cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	@printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	@cp Resources/AppIcon.icns $(ENGINE) $(FONT) "$(APP)/Contents/Resources/"
	@codesign --force --sign "$(SIGN)" --identifier com.albastov.iridium-live "$(APP)"
	@touch $@

.PHONY: run check install icon cert clean

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

# One off. Asks for the login password (trusting a certificate needs it) and leaves "Iridium Live Dev" in the login
# keychain; remove it in Keychain Access, or with
#   security delete-certificate -c "Iridium Live Dev" -t ~/Library/Keychains/login.keychain-db
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
