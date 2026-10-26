# Build output lives outside OneDrive: File Provider stamps files with xattrs that make codesign fail
# ("resource fork, Finder information, or similar detritus not allowed").
SCRATCH ?= $(HOME)/Library/Caches/ClaudeUsageWidget/build
SWIFT   = swift
FLAGS   = --scratch-path $(SCRATCH)

.PHONY: test build app icon run install clean
test:
	$(SWIFT) test $(FLAGS)
build:
	$(SWIFT) build $(FLAGS) -c release
app:
	SCRATCH=$(SCRATCH) scripts/build_app.sh
# Resources/AppIcon.icns is committed; run this only after replacing Resources/AppIcon-source.png.
icon:
	scripts/make_icon.sh
run: app
	open "$(dir $(SCRATCH))KAIkei.app"
install: app
	mkdir -p "$(HOME)/Applications" && rm -rf "$(HOME)/Applications/KAIkei.app" && cp -R "$(dir $(SCRATCH))KAIkei.app" "$(HOME)/Applications/"
clean:
	rm -rf $(SCRATCH)
