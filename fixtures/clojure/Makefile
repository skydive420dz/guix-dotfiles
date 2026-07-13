SHELL = /bin/sh

CLOJURE_PROJECT ?= ../../scripts/clojure-project
PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

.PHONY: check classpath eval format format-check lint lsp reload repl test

check: format-check lint test

# clojure-lsp reads this through .lsp/config.edn.  It intentionally names the
# Guix profile JAR directly instead of invoking tools.deps or resolving deps.edn.
classpath:
	@test -n "$(GUIX_ENVIRONMENT)" || { \
		printf '%s\n' 'Clojure classpath requires GUIX_ENVIRONMENT' >&2; \
		exit 2; \
	}
	@test -r "$(GUIX_ENVIRONMENT)/share/java/clojure.jar" || { \
		printf 'missing Guix Clojure JAR: %s\n' \
			"$(GUIX_ENVIRONMENT)/share/java/clojure.jar" >&2; \
		exit 2; \
	}
	@printf '%s:%s/src:%s/test\n' \
		"$(GUIX_ENVIRONMENT)/share/java/clojure.jar" \
		"$(PROJECT_ROOT)" "$(PROJECT_ROOT)"

format format-check lint lsp repl:
	@$(CLOJURE_PROJECT) $@ "$(PROJECT_ROOT)"

# These targets are fixture acceptance semantics.  The production wrapper only
# supplies the generic `clojure.main' primitive; each real project owns its own
# eval, reload, test, and `make check' policy in its Makefile.
eval:
	@$(CLOJURE_PROJECT) clojure "$(PROJECT_ROOT)" -- -e \
		"(require 'sk.fixture.core) (println (sk.fixture.core/fixture-answer))"

reload:
	@$(CLOJURE_PROJECT) clojure "$(PROJECT_ROOT)" -- -e \
		"(require 'sk.fixture.core :reload) (println (sk.fixture.core/fixture-answer))"

test:
	@$(CLOJURE_PROJECT) clojure "$(PROJECT_ROOT)" -- \
		-m sk.fixture.test-runner
