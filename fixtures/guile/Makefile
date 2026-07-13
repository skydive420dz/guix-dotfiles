SHELL = /bin/sh

GUILE ?= guile
GUILD ?= guild

SOURCE_DIRECTORY = src
MODULE_SOURCE = $(SOURCE_DIRECTORY)/sk/fixture/math.scm
TEST_SOURCE = tests/math-test.scm

.PHONY: check compile test docs debug

check: compile test docs

compile:
	@temporary=$$(mktemp -d "$${TMPDIR:-/tmp}/sk-guile-fixture.XXXXXX") || exit 1; \
	trap 'rm -rf -- "$$temporary"' EXIT HUP INT TERM; \
	mkdir -p "$$temporary/sk/fixture"; \
	$(GUILD) compile -W3 -L "$(SOURCE_DIRECTORY)" \
		-o "$$temporary/sk/fixture/math.go" "$(MODULE_SOURCE)"; \
	test -s "$$temporary/sk/fixture/math.go"

test:
	@GUILE_AUTO_COMPILE=0 $(GUILE) -q --no-auto-compile \
		-L "$(SOURCE_DIRECTORY)" -s "$(TEST_SOURCE)"

docs:
	@$(GUILD) display-commentary "$(MODULE_SOURCE)"

debug:
	@printf '%s\n' \
		'Starting a debug-VM REPL with (sk fixture math) on the load path.'
	@GUILE_AUTO_COMPILE=0 exec $(GUILE) -q --debug --no-auto-compile \
		-L "$(SOURCE_DIRECTORY)" -l "$(MODULE_SOURCE)" --
