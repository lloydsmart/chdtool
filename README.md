# chdtool

A Bash script that converts CD/DVD disc images (ZIP/RAR/7Z/ISO/CUE/GDI/CCD) into CHD using `chdman`.
- Auto-detects CD vs DVD to choose `createcd` vs `createdvd`
- Verifies CHDs and replaces originals on success (optional keep originals)
- Works non-recursively by default; recursive mode available
- Logs everything to `logs/`

## Requirements
- bash 5+
- chdman (MAME)
- unzip, unrar, 7z
- stat, file, find, grep, sort, tee

## Usage
```bash
./chdtool.sh [--keep-originals|-k] [--recursive|-r] <input directory>
```

Examples:
```bash
./chdtool.sh /path/to/dir
./chdtool.sh -k -r /roms
```

## Notes
- Temporary CHDs are created as `*.chd.tmp` then verified and renamed.
- Logs are written under `logs/`.
- DVD detection: prefers UDF via `file`, otherwise size heuristic (≥1 GB → DVD).
