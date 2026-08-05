SHELL := /usr/bin/env bash

# Path to your script; override with: make test SCRIPT=./path/to/script.sh
SCRIPT ?= ./chdtool.sh

.PHONY: test test-m3u test-m3u-single test-partial-resume test-transactional-source-deletion test-temporary-chd-cleanup test-exit-status test-logging test-security-validation test-resource-handling test-regression-gaps test-cli test-package test-setup clean changelog changelog-tag package

test: test-setup test-m3u test-m3u-single test-partial-resume test-transactional-source-deletion test-temporary-chd-cleanup test-exit-status test-logging test-security-validation test-resource-handling test-regression-gaps test-cli test-package

test-setup:
	chmod +x tests/bin/chdman
	chmod +x tests/bin/unrar
	-chmod +x tests/bin/7z
	chmod +x tests/test_m3u.sh tests/test_m3u_single.sh tests/test_transactional_source_deletion.sh
	chmod +x tests/test_temporary_chd_cleanup.sh
	chmod +x tests/test_partial_resume.sh
	chmod +x tests/test_exit_status.sh
	chmod +x tests/test_security_validation.sh
	chmod +x tests/test_resource_handling.sh
	chmod +x tests/test_regression_gaps.sh
	chmod +x tests/test_cli.sh tests/test_package.sh scripts/package-release.sh
	@if [ -f tests/test_logging.sh ]; then chmod +x tests/test_logging.sh; fi

test-m3u:
	SCRIPT=$(SCRIPT) bash tests/test_m3u.sh

test-m3u-single:
	SCRIPT=$(SCRIPT) bash tests/test_m3u_single.sh

test-partial-resume:
	SCRIPT=$(SCRIPT) bash tests/test_partial_resume.sh

test-transactional-source-deletion:
	SCRIPT=$(SCRIPT) bash tests/test_transactional_source_deletion.sh

test-temporary-chd-cleanup:
	SCRIPT=$(SCRIPT) bash tests/test_temporary_chd_cleanup.sh

test-exit-status:
	SCRIPT=$(SCRIPT) bash tests/test_exit_status.sh

test-logging:
	@if [ -f tests/test_logging.sh ]; then \
	  SCRIPT=$(SCRIPT) bash tests/test_logging.sh ; \
	else \
	  echo "Skipping logging test (tests/test_logging.sh not present)"; \
	fi

test-security-validation:
	SCRIPT=$(SCRIPT) bash tests/test_security_validation.sh

test-resource-handling:
	SCRIPT=$(SCRIPT) bash tests/test_resource_handling.sh

test-regression-gaps:
	SCRIPT=$(SCRIPT) bash tests/test_regression_gaps.sh

test-cli:
	SCRIPT=$(SCRIPT) bash tests/test_cli.sh

test-package:
	bash tests/test_package.sh

clean:
	@echo "Nothing to clean; tests use mktemp dirs."

changelog:
	git cliff --config cliff.toml -o CHANGELOG.md

changelog-tag:
	git cliff --config cliff.toml --tag $${TAG} --strip header > CHANGELOG_RELEASE.md

package:
	bash scripts/package-release.sh "$${VERSION:-$$(sed -n 's/^CHDTOOL_VERSION="\([^"]*\)"/\1/p' chdtool.sh)}"
