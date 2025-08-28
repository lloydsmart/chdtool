SHELL := /usr/bin/env bash

# Path to your script; override with: make test SCRIPT=./path/to/script.sh
SCRIPT ?= ./chdtool.sh

.PHONY: test test-m3u test-m3u-single test-logging test-setup clean changelog changelog-tag

test: test-setup test-m3u test-m3u-single test-logging

test-setup:
	chmod +x tests/bin/chdman
	chmod +x tests/bin/unrar
	-chmod +x tests/bin/7z
	chmod +x tests/test_m3u.sh tests/test_m3u_single.sh
	@if [ -f tests/test_logging.sh ]; then chmod +x tests/test_logging.sh; fi

test-m3u:
	SCRIPT=$(SCRIPT) bash tests/test_m3u.sh

test-m3u-single:
	SCRIPT=$(SCRIPT) bash tests/test_m3u_single.sh

test-logging:
	@if [ -f tests/test_logging.sh ]; then \
	  SCRIPT=$(SCRIPT) bash tests/test_logging.sh ; \
	else \
	  echo "Skipping logging test (tests/test_logging.sh not present)"; \
	fi

clean:
	@echo "Nothing to clean; tests use mktemp dirs."

changelog:
	git cliff --config .cliff.toml -o CHANGELOG.md

changelog-tag:
	git cliff --config .cliff.toml --tag $${TAG} --strip header > CHANGELOG_RELEASE.md
