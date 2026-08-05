# 🎮 chdtool

[![License](https://img.shields.io/github/license/lloydsmart/chdtool)](https://github.com/lloydsmart/chdtool/blob/main/LICENSE.md)
[![Release](https://img.shields.io/github/v/release/lloydsmart/chdtool)](https://github.com/lloydsmart/chdtool/releases)
[![ShellCheck](https://img.shields.io/github/actions/workflow/status/lloydsmart/chdtool/shellcheck.yml?branch=main&label=shellcheck)](https://github.com/lloydsmart/chdtool/actions/workflows/shellcheck.yml)

A robust Bash script for converting CD/DVD disc images and archives into **CHD (Compressed Hunks of Data)** format using `chdman`.

Designed for batch processing, validation, logging, and multi-disc handling — ideal for emulation libraries.

---

Convert everything in a directory:

```bash
./chdtool.sh -r /path/to/roms
```

---

## ✨ Features

- 📦 Supports common input formats:
  - Archives: `zip`, `rar`, `7z`
  - Disc images: `iso`, `cue`, `gdi`, `ccd`
- 🔄 Automatic extraction of archives before conversion
- 💿 Intelligent CD vs DVD detection (`createcd` vs `createdvd`)
- ✅ Verification of CHDs using `chdman verify`
  - Automatic retry on failure
  - Deletes invalid CHDs
- 📉 Space savings reporting
- 🧾 Automatic M3U generation for multi-disc sets
- 🧹 Safe temp directory handling with cleanup traps
- 🧪 Dry-run mode (no source or conversion changes)
- 🪵 Structured logging system:
  - Console / file / syslog / journald
  - Configurable verbosity
- ⚡ Progress bar (TTY-aware, non-spammy)

---

## 🚀 Usage

```bash
./chdtool.sh [options] <input directory>
```

### Options

| Option | Description |
| ------ | ----------- |
| `-k`, `--keep-originals` | Do not delete source files after conversion |
| `-r`, `--recursive` | Process subdirectories |
| `-n`, `--dry-run` | Show what would happen without making changes |
| `-a`, `--allow-unverified-cue-audio` | Permit lossy or unverified CUE audio tracks (not preservation-safe) |
| `-F`, `--file-tee` | Force logging to file |
| `-N`, `--no-file-tee` | Disable logging to file |
| `-h`, `--help` | Show usage information |
| `-V`, `--version` | Show the packaged version |

Use `--` to end option parsing when an input directory starts with `-`:

```bash
./chdtool.sh -- -roms
```

---

## 📁 Example

```bash
./chdtool.sh -r /mnt/roms
```

Dry run:

```bash
./chdtool.sh -n /mnt/roms
```

---

## 📦 Supported Input Formats

### Disc images

- `.iso`
- `.cue` (with referenced BIN/WAV/MP3 validation)
- `.gdi`
- `.ccd`

### Archives

- `.zip`
- `.rar`
- `.7z`

Archives are extracted to a temporary directory and processed automatically.

---

## 💿 Output

- CHDs are created alongside the input files
- Temporary files use `.tmp` suffix until verified
- Originals are removed unless `--keep-originals` is set

---

## 🧾 Multi-disc Support

- Automatically detects disc numbering patterns:
  - `Disc 1`, `CD2`, `Part 3`, `Side A`, `1 of 2`, etc.
- Generates `.m3u` playlists when **2+ discs** are detected
- Filenames are sanitized for cross-platform compatibility

Example:

```text
Final Fantasy VII (Disc 1).chd
Final Fantasy VII (Disc 2).chd
Final Fantasy VII.m3u
```

---

## 🔍 Verification

- All CHDs are verified with `chdman verify`
- Failed verification:
  - Retried once
  - Deleted if still invalid
- Existing CHDs are verified before skipping conversion

---

## 🪵 Logging

Configurable via environment variables:

```bash
LOG_DEST=auto|console|file|syslog|journald
LOG_LEVEL_THRESHOLD=DEBUG|INFO|WARN|ERROR
LOG_TEE_CONSOLE=auto|1|0
LOG_TEE_FILE=1|0
LOG_TAG=chdtool
LOGFILE=/custom/path/chdtool.log
```

Default log file:

```text
logs/chd_conversion_<timestamp>.log
```

`--file-tee` and `--no-file-tee` control the optional file mirror for console,
syslog, and journald backends. When `LOG_DEST=file`, the file is the primary
destination and is therefore still written. A caller-supplied `LOGFILE` path is
used verbatim.

---

## 📊 Output Summary

At the end of a run:

- Total original size
- Total CHD size
- Space saved
- Archives processed
- CHDs created
- Failures
- Elapsed time

### Exit statuses

- `0` — clean success, including intentional skips and already-complete inputs
- `1` — usage, configuration, or startup failure
- `2` — one or more discovered inputs failed; independent inputs were still processed
- `130` — interrupted by SIGINT or SIGTERM

---

## ⚙️ Requirements

The following tools must be installed:

- `chdman`
- `unzip`
- `unrar`
- `7z`
- `stat`
- `awk`
- `stdbuf`

Optional (enhancements):

- `file` (better ISO detection)
- `perl` (improved filename parsing)
- `uconv` (Unicode normalization)
- `systemd-cat` / `logger` (logging backends)

---

## 🧪 Dry Run Mode

Use `--dry-run` to preview actions:

```bash
./chdtool.sh -n /roms
```

- No source files, CHDs, playlists, or temporary conversion workspaces are
  created, moved, or deleted
- All intended operations are logged

Logging remains active during a dry run and may create the configured log file.
Use `--no-file-tee` with the console, syslog, or journald backend to prevent a
file mirror.

### Resource selection

By default, CHD Tool lets `chdman` choose its format-appropriate hunk size. It
selects compression threads conservatively from Linux `MemAvailable` (never
swap), using roughly 2 GiB per CD thread or 4 GiB per DVD thread, and caps the
result at the available CPU count with a minimum of one.

- `CHDMAN_THREADS=N` requests a positive thread count; values above the CPU count
  are capped
- `CHDMAN_HUNK_SIZE=N` is an advanced opt-in that passes `-hs N` to `chdman`

---

## ⚠️ Notes

- DVD support requires a version of `chdman` with `createdvd`
- CUE files referencing missing files will fail validation
- CUE/GDI/CCD paths must be relative and remain below the descriptor directory;
  nested paths and unambiguous case-insensitive matches are supported
- A successfully converted direct descriptor is treated as one source set: unless
  `--keep-originals` is used, the descriptor and all validated companion tracks
  are removed together. Any validation or conversion failure retains the full set
- Archive members are rejected before conversion when paths escape the extraction
  directory, links are present, or selected entries collide after name sanitisation
- Temporary files are cleaned automatically, even on interruption
- `--allow-unverified-cue-audio` relaxes preservation checks for lossy or
  otherwise unverified CUE audio tracks; use it only when accepting that risk

---

## 📦 Release assets

Each release publishes `.tar.gz` and `.zip` archives containing `chdtool`,
`README.md`, `LICENSE.md`, and `CHANGELOG.md`, plus a standalone `chdtool`
script. Verify downloads with the published checksum file:

```bash
sha256sum --check SHA256SUMS
```

Maintainers should use the documented [release procedure](RELEASING.md) rather
than creating tags or assets manually.

---

## 🛠️ Design Goals

- Safe by default (verify before replace)
- Idempotent (re-runs don’t duplicate work)
- Transparent logging
- Minimal dependencies
- Works well on large ROM collections

---

## 📌 Future Ideas

- Parallel processing
- Better metadata integration
- Optional compression tuning
- Integration with tools like Retromount / ROM managers
