SHELL = /bin/sh

FENNEL_PROJECT ?= ../../scripts/fennel-project
FENNEL_PROJECT_MODE ?=
PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
FENNEL_SOURCE := \
	src/sk/fixture/macros.fnl \
	src/sk/fixture/math.fnl \
	src/sk/fixture/main.fnl
FENNEL_TEST := test/sk/fixture/main-test.fnl
FENNEL_ALL := $(FENNEL_SOURCE) $(FENNEL_TEST)
FENNEL_LINT := $(FENNEL_ALL) flsproject.fnl
FENNEL_COMPILE := \
	src/sk/fixture/math.fnl \
	src/sk/fixture/main.fnl \
	$(FENNEL_TEST)

.PHONY: check compile eval format-check lint lsp macro repl test

check: format-check lint compile test

compile:
	@$(FENNEL_PROJECT) $(FENNEL_PROJECT_MODE) --project "$(PROJECT_ROOT)" compile \
		$(FENNEL_COMPILE) >/dev/null

format-check:
	# Keep flsproject's documented "lua5.3" string spelling.  fnlfmt rewrites
	# that string to equivalent colon syntax, so only source/test code is format-owned.
	@$(FENNEL_PROJECT) $(FENNEL_PROJECT_MODE) --project "$(PROJECT_ROOT)" format-check \
		$(FENNEL_ALL)

lint:
	@$(FENNEL_PROJECT) $(FENNEL_PROJECT_MODE) --project "$(PROJECT_ROOT)" lint \
		$(FENNEL_LINT)

test:
	@$(FENNEL_PROJECT) $(FENNEL_PROJECT_MODE) --project "$(PROJECT_ROOT)" test \
		$(FENNEL_TEST)

eval:
	@$(FENNEL_PROJECT) $(FENNEL_PROJECT_MODE) --project "$(PROJECT_ROOT)" eval \
		'(let [main (require :sk.fixture.main)] (main.fixture-answer))'

macro:
	@$(FENNEL_PROJECT) $(FENNEL_PROJECT_MODE) --project "$(PROJECT_ROOT)" eval \
		'(do (import-macros {: twice} :sk.fixture.macros) (twice 21))'

lsp:
	@$(FENNEL_PROJECT) $(FENNEL_PROJECT_MODE) --project "$(PROJECT_ROOT)" lsp

repl:
	@$(FENNEL_PROJECT) $(FENNEL_PROJECT_MODE) --project "$(PROJECT_ROOT)" repl
