EMACS ?= emacs

SOURCES := sk-example.el test/sk-example-test.el

.PHONY: check byte-compile test package-lint
.NOTPARALLEL:

check: byte-compile test package-lint

byte-compile:
	@printf '%s\n' '== warning-fatal byte compilation =='
	@set -eu; \
	compile_directory=$$(mktemp -d "$${TMPDIR:-/tmp}/sk-example-byte-compile.XXXXXX"); \
	trap 'rm -rf -- "$$compile_directory"' EXIT HUP INT TERM; \
	SK_EXAMPLE_COMPILE_DIRECTORY="$$compile_directory" \
	  "$(EMACS)" --batch -Q -L . -L test \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  --eval '(setq byte-compile-dest-file-function (lambda (source) (expand-file-name (concat (file-name-base source) ".elc") (getenv "SK_EXAMPLE_COMPILE_DIRECTORY"))))' \
	  -f batch-byte-compile $(SOURCES)

test:
	@printf '%s\n' '== ERT and Checkdoc =='
	@"$(EMACS)" --batch -Q -L . -L test \
	  -l sk-example-test \
	  -f ert-run-tests-batch-and-exit

package-lint:
	@printf '%s\n' '== fatal package-lint =='
	@"$(EMACS)" --batch -Q \
	  -l package-lint \
	  --eval '(setq package-lint-batch-fail-on-warnings t)' \
	  -f package-lint-batch-and-exit sk-example.el
