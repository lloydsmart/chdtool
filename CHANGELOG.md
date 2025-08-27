# Changelog
All notable changes to this project will be documented in this file.

This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.0.0),
and uses semantic versioning for tags (vMAJOR.MINOR.PATCH).
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

