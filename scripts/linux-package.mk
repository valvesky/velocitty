PREFIX ?= /usr/local
DESTDIR ?=

.PHONY: install uninstall

install:
	install -Dm755 bin/velocitty "$(DESTDIR)$(PREFIX)/bin/velocitty"
	install -Dm644 share/applications/velocitty.desktop "$(DESTDIR)$(PREFIX)/share/applications/velocitty.desktop"
	install -Dm644 share/icons/hicolor/512x512/apps/velocitty.png "$(DESTDIR)$(PREFIX)/share/icons/hicolor/512x512/apps/velocitty.png"
	install -Dm644 share/man/man1/velocitty.1 "$(DESTDIR)$(PREFIX)/share/man/man1/velocitty.1"

uninstall:
	rm -f "$(DESTDIR)$(PREFIX)/bin/velocitty" "$(DESTDIR)$(PREFIX)/share/applications/velocitty.desktop" "$(DESTDIR)$(PREFIX)/share/icons/hicolor/512x512/apps/velocitty.png" "$(DESTDIR)$(PREFIX)/share/man/man1/velocitty.1"
