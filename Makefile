# Build output lives outside OneDrive: File Provider stamps files with xattrs that make codesign fail
# ("resource fork, Finder information, or similar detritus not allowed").
SCRATCH ?= $(HOME)/Library/Caches/ClaudeUsageWidget/build
SWIFT   = swift
FLAGS   = --scratch-path $(SCRATCH)

.PHONY: test build app icon run install advisor advisor-uninstall clean
test:
	$(SWIFT) test $(FLAGS)
	python3 -I -m unittest discover -s scripts -p "test_*.py"
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
# The terminal advisor: builds kaikei-advise, installs it at a path that does not move when the app is rebuilt, and wires it
# into ~/.claude/settings.json as a prompt hook and a status line (backup first; your existing status line keeps running).
ADVISOR_BIN = $(HOME)/.kaikei/bin/kaikei-advise
advisor:
	$(SWIFT) build $(FLAGS) -c release --product kaikei-advise
	mkdir -p "$(dir $(ADVISOR_BIN))" && cp "$$($(SWIFT) build $(FLAGS) -c release --product kaikei-advise --show-bin-path)/kaikei-advise" "$(ADVISOR_BIN)" && codesign --force --sign - "$(ADVISOR_BIN)"
	python3 -I scripts/install_advisor.py --bin "$(ADVISOR_BIN)"
advisor-uninstall:
	python3 -I scripts/install_advisor.py --bin "$(ADVISOR_BIN)" --uninstall
clean:
	rm -rf $(SCRATCH)
