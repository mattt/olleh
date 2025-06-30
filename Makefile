SHELL := /bin/bash

DESTDIR ?=
PREFIX = /usr/local
BINDIR = $(PREFIX)/bin

INSTALL := install -m 0755
INSTALL_PROGRAM := $(INSTALL)

SWIFT := swift

VHS := vhs

default: all

.PHONY: all
all: olleh

olleh: Sources/**/*.swift Package.swift
	$(SWIFT) build -c release --disable-sandbox
	cp .build/release/olleh $@

demo.gif: olleh demo.tape
	PATH=$(PWD):$(PATH) $(VHS) demo.tape

.PHONY: install
install: olleh
	$(INSTALL_PROGRAM) -d $(DESTDIR)$(BINDIR)
	$(INSTALL_PROGRAM) olleh $(DESTDIR)$(BINDIR)/olleh

.PHONY: uninstall
uninstall:
	rm -f $(DESTDIR)$(BINDIR)/olleh

.PHONY: clean
clean:
	$(SWIFT) package clean
	rm -f olleh
	rm -rf .build

.PHONY: run
run: olleh
	./olleh

.PHONY: serve
serve: olleh
	./olleh serve