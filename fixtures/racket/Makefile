SHELL = /bin/sh

RACKET_PROJECT ?= ../../scripts/racket-project
PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RACKET_SOURCE := src/sk/fixture/main.rkt
RACKET_TEST := test/sk/fixture/main-test.rkt
RACKET_DOC := scribblings/sk-fixture.scrbl

.PHONY: check docs eval expand lint make repl test

check: make lint test docs

make:
	@$(RACKET_PROJECT) --project "$(PROJECT_ROOT)" make \
		$(RACKET_SOURCE) $(RACKET_TEST)

lint:
	@$(RACKET_PROJECT) --project "$(PROJECT_ROOT)" lint \
		$(RACKET_SOURCE) $(RACKET_TEST)

test:
	@$(RACKET_PROJECT) --project "$(PROJECT_ROOT)" test $(RACKET_TEST)

docs:
	@$(RACKET_PROJECT) --project "$(PROJECT_ROOT)" docs $(RACKET_DOC)

expand:
	@$(RACKET_PROJECT) --project "$(PROJECT_ROOT)" expand $(RACKET_SOURCE)

repl:
	@$(RACKET_PROJECT) --project "$(PROJECT_ROOT)" repl

eval:
	@$(RACKET_PROJECT) --project "$(PROJECT_ROOT)" eval \
		'(begin (require sk/fixture/main) (displayln (fixture-answer)))'
