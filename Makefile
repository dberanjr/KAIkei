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
# The signed app is built outside OneDrive, then copied (without xattrs) to ./KAIkei/ so it is easy to find.
# Launch the copy in ~/Library/Caches (the one `make run` opens) if OneDrive ever invalidates the copy's signature.
app:
	SCRATCH=$(SCRATCH) scripts/build_app.sh
	mkdir -p KAIkei && rm -rf KAIkei/KAIkei.app && ditto --norsrc --noextattr "$(dir $(SCRATCH))KAIkei.app" KAIkei/KAIkei.app
# Resources/AppIcon.icns is committed; run this only after replacing Resources/AppIcon-source.png.
icon:
	scripts/make_icon.sh
run: app
	open "$(dir $(SCRATCH))KAIkei.app"
install: app
	mkdir -p "$(HOME)/Applications" && rm -rf "$(HOME)/Applications/KAIkei.app" && cp -R "$(dir $(SCRATCH))KAIkei.app" "$(HOME)/Applications/"
clean:
	rm -rf $(SCRATCH)
