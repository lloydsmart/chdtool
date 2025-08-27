SHELL := /usr/bin/env bash

# Path to your script; override with: make test SCRIPT=./path/to/script.sh
SCRIPT ?= ./chdtool.sh

.PHONY: test test-m3u test-m3u-single test-setup clean

test: test-setup test-m3u test-m3u-single

test-setup:
	chmod +x tests/bin/chdman
	chmod +x tests/test_m3u.sh tests/test_m3u_single.sh

test-m3u:
	SCRIPT=$(SCRIPT) bash tests/test_m3u.sh

test-m3u-single:
	SCRIPT=$(SCRIPT) bash tests/test_m3u_single.sh

clean:
	@echo "Nothing to clean; tests use mktemp dirs."
