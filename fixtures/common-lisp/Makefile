SBCL ?= sbcl

PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SYSTEM := sk-fixture

.PHONY: check test run

check: test

test:
	@set -eu; \
	cache=$$(mktemp -d "$${TMPDIR:-/tmp}/sk-fixture-asdf.XXXXXX"); \
	trap 'rm -rf -- "$$cache"' EXIT HUP INT TERM; \
	CL_SOURCE_REGISTRY='(:source-registry (:directory "$(PROJECT_ROOT)/") :ignore-inherited-configuration)' \
	ASDF_OUTPUT_TRANSLATIONS="(:output-translations (t (\"$$cache/\" :implementation)) :ignore-inherited-configuration)" \
	"$(SBCL)" --noinform --disable-debugger --non-interactive \
		--eval '(require :asdf)' \
		--eval '(asdf:load-asd #p"$(PROJECT_ROOT)/sk-fixture.asd")' \
		--eval '(asdf:test-system "$(SYSTEM)")'

run:
	@set -eu; \
	cache=$$(mktemp -d "$${TMPDIR:-/tmp}/sk-fixture-asdf.XXXXXX"); \
	trap 'rm -rf -- "$$cache"' EXIT HUP INT TERM; \
	CL_SOURCE_REGISTRY='(:source-registry (:directory "$(PROJECT_ROOT)/") :ignore-inherited-configuration)' \
	ASDF_OUTPUT_TRANSLATIONS="(:output-translations (t (\"$$cache/\" :implementation)) :ignore-inherited-configuration)" \
	"$(SBCL)" --noinform --disable-debugger --non-interactive \
		--eval '(require :asdf)' \
		--eval '(asdf:load-asd #p"$(PROJECT_ROOT)/sk-fixture.asd")' \
		--eval '(asdf:load-system "$(SYSTEM)")' \
		--eval '(format t "~A~%" (sk-fixture:add 20 22))'
