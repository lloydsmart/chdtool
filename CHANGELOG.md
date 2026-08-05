# Changelog
All notable changes to this project will be documented in this file.

This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.0.0),
and uses semantic versioning for tags (vMAJOR.MINOR.PATCH).
## [0.2.5] - 2026-02-07

### Chores

- *(changelog)* Update for v0.2.4
- Initialize IS_RAM_DISK to false
- Add post-conversion sync and cooldown period

### Features

- Implement resource-aware thread scaling using total virtual memory
- Implement console fingerprinting and hunk size optimisation
- Align CD hunk sizes to 2448 bytes for chdman compatibility

### Fixes

- *(chdman)* Relax createdvd feature detection regex
- *(chdman)* Handle exit status for createdvd feature detection
- *(chdman)* Correct createdvd feature detection and debug logging
- *(chdtool)* Use disk-based temp directory for large file processing
- *(chdtool)* Limit memory usage for chdman createdvd/createcd
- Prevent OOM crashes by dynamically limiting chdman threads
- Account for RAM disk (tmpfs) overhead in thread calculation
- Move check_temp_storage definition before its first call
- Syntax error in chdtool.sh
- *(shellcheck)* SC2155 (warning): Declare and assign separately to avoid masking return values.
- Resolve bash syntax error and optimize disc sniffing I/O
- Unify subcommand and hunk-size mapping for ps2/psp/dvd
- Resolve progress bar stalling by handling carriage returns

### Performance

- Optimize thread calculation for high-memory environments
## [0.2.4] - 2025-08-28

### CI

- Add test for logging
- Tweak for debugging
- Use --dry-run for logging tests

### Chores

- *(changelog)* Update for v0.2.3
- Update gitignore
- Not sure how this got duplicated

### Features

- Add EXIT trap to do cleanup
- Add dry-run mode!
- Improve dry-run mode
- Improve logging. Default to file + journald, but be configurable.

### Fixes

- Remove duplication, add short options for logging switches
- Ci: not working
- Test script fails due to env vars
- Ci: failing
- Exit status on test
## [0.2.3] - 2025-08-27

### Fixes

- Git-cliff not working
## [0.2.2] - 2025-08-27

### Fixes

- Git-cliff doesn't exist on Ubuntu-latest so install it manually.
## [0.2.1] - 2025-08-27

### CI

- Automate changelog

### Chores

- Add git-cliff config and initial CHANGELOG

### Docs

- Added changelog automation
## [0.2.0] - 2025-08-27

### CI

- Add test to make sure M3U isn't broken
- Integrate Makefile
- Fix: handle dependencies
- Add stubs for unrar and 7z, so we don't have to install them

### Features

- *(m3u)* Robust multi-disc parsing + fix dangling bracket in base
- Add more robust M3U filename sanitization
- Robust "now in ms"
- Safer terminal printing
- Better logging
- Logging: add log levels
- Logging: minor fixes
- Add more cleanup
- Added interrupt handling to exit cleanly in terminal
- Also clean up the .tmp files in the input directory

### Fixes

- Shellcheck SC2034 unused variable "now"
- SC2034 unused variable "now"
- Typos
- SC2119 argument references
- Minor logigng fixes
- Various
- Minor fixes
- Minor fixes, improve logging, make regex safer
- Logging order + logfile dir guard
- NUL-safe find + mapfile
- NUL-safe find + mapfile
- Make validate_cue_file NUL-safe
- Normalize CHDMAN_MSG_LEVEL
- Regex tweaks
- Send usage errors to stderr in the arg parser
- Check input dir BEFORE creating log dir
- Local _cleanup()
- Don't pipe to a function, use here-string instead
- Add -- to destructive commands
- Remove duplicate defaulting of PROGRESS_BAR_MAX
- Also run _cleanup() on unexpected errors
- Force C collation for the numeric sort for systems with non-C locales
- Update verify_chds(). Uses the single-line progress bar (via _chdman_progress_filter + PHASE_DEFAULT="Verifying"),
- Simplify progress logging
- Better comment
- Trim unused bits
- Make cleanup_all a bit safer
- M3U generation
## [0.1.4] - 2025-08-22

### Fixes

- Multi-disc set detection
- Multi-disc set detection
## [0.1.3] - 2025-08-22

### CI

- Fix SC2015

### Docs

- Minor change

### Features

- Inital M3U logic
- Add progressbar
- *(chdtool)* Per-iteration M3U generation + single-line chdman progress

### Fixes

- Progress bar repeating
- More progressbar tweaks
- More progressbar tweaks
- Progressbar still being a pita
- More progressbar fixes
- Progressbar
- Progressbar
- Typo
- Progressbar
- Progressbar
- Progressbar
- Progressbar
- Progressbar
- Progressbar
- Progressbar
- Progressbar
- Progressbar
- Progressbar
- Progressbar (cleanup)
- Ci: SC2034
## [0.1.2] - 2025-08-21

### CI

- Add release workflow

### Docs

- Improved readme
- Minor fix
## [0.1.1] - 2025-08-21

### CI

- Add ShellCheck workflow

### Docs

- Add some standard files
- Updated README and created CHANGELOG

### Features

- CD/DVD detection with createcd/createdvd

### Fixes

- *(shellcheck)* Resolve SC2155, SC2076, and SC2086 warnings
- Shellcheck compliance SC2283
## [0.1.0] - 2025-08-21

