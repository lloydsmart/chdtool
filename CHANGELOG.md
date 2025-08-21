# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- Planned support for `.m3u` playlist generation (multi-disc sets).

### Roadmap
- [ ] Implement `.m3u` playlist generation.
- [ ] Additional heuristics for more robust CD/DVD detection.
- [ ] Broader archive support (e.g., CHD inside 7z).
- [ ] Automated test suite.

---

## [0.6.0] - 2025-07-12
### Added
- Detection of `chdman` version and capabilities (`createdvd` support).
- Improved log output with visual icons for CD vs. DVD conversion.

### Fixed
- Prevented unrelated games with similar names from being grouped into the same `.m3u`.
- Correct handling of multi-disc `.m3u` creation on a per-loop basis.

---

## [0.5.0] - 2025-07-10
### Added
- `--keep-originals` flag to preserve source archives/disc images after conversion.
- Smarter `.m3u` generation logic:
  - Only generates when multiple CHDs exist **and** input files are missing.
  - Improved normalization to correctly identify disc sets.
- Extended logging: game base names, normalized names, and remaining inputs.

### Fixed
- Archives no longer skipped due to false negatives in disc file detection.
- Prevented premature script exit before all files were processed.
- Stopped `.m3u` generation for single-disc games.

---

## [0.4.0] - 2025-07-04
### Added
- Global temp directory tracking via `TEMP_DIRS` array with `trap` cleanup.
- `inputs_remaining_for_base()` check to ensure `.m3u` creation only occurs when all discs are processed.

### Fixed
- Corrected CHD size calculation for archives (sum of CHDs instead of input size).
- Fixed double-increment bug in failure counter on verification failure.
- Standardized `verify_chds` return codes (true/false).

---

## [0.3.0] - 2025-07-03
### Added
- CLI argument parsing (`--keep-originals`, `--dry-run`).
- Structured logging functions: `log` and `verify_output_log`.

### Fixed
- Disc detection regex improvements for `.zip`, `.rar`, `.7z`, `.cue`, `.iso`, `.gdi`.

---

## [0.2.0] - 2025-07-01
### Added
- Per-input temp directories with immediate cleanup.
- Space-saving calculation (original vs. CHD size) in logs.

### Fixed
- Logging improvements to include detailed verification output.

---

## [0.1.0] - 2025-06-30
### Added
- Initial working script:
  - Converts supported disc images (`.cue`, `.iso`, `.gdi`, `.ccd`) and archives (`.zip`, `.7z`, `.rar`) into CHD.
  - Verifies CHDs after creation.
  - Deletes originals after successful conversion.
  - Basic `.m3u` generation for multi-disc games.
