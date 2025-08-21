# 🎮 chdtool  

[![License](https://img.shields.io/github/license/lloydsmart/chdtool)](https://github.com/lloydsmart/chdtool/blob/master/LICENSE)  
[![Latest Release](https://img.shields.io/github/v/release/lloydsmart/chdtool)](https://github.com/lloydsmart/chdtool/releases)  
[![ShellCheck](https://github.com/lloydsmart/chdtool/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/lloydsmart/chdtool/actions/workflows/shellcheck.yml)

A Bash script that converts CD/DVD disc images (ZIP/RAR/7Z/ISO/CUE/GDI/CCD) into CHD using chdman.

Convert, verify, and manage disc-based game images into CHD format with ease.
Supports recursive scanning, CD/DVD detection, archive extraction, and more.

---

## ✨ Features  

- 📦 Extracts archives (`.zip`, `.rar`, `.7z`)
- 💿 Converts **CD images** via `chdman createcd`
- 📀 Converts **DVD images** via `chdman createdvd` (if available)
- 🔍 Verifies existing CHDs before conversion
- 🗑️ Cleans up temp files automatically
- 📊 Logs space savings per file and in total
- 🔄 Recursive directory scanning
- ⚙️ Option to keep originals with `--keep-originals`

---

## 🚀 Usage
```bash
./chdtool.sh [--keep-originals|-k] [--recursive|-r] <input directory>
```

Examples:
```bash
./chdtool.sh /path/to/dir
./chdtool.sh -k -r /roms
```

### Options

- `--keep-originals` → Keep input archives/discs after conversion
- `--help` → Show usage

---

## 📋 Example Run

```text
[2025-07-05 12:07:24] 🚀 Script started, input dir: /mnt/roms/saturn
[2025-07-05 12:07:24] 💿 Converting: Game.cue -> Game.chd.tmp
[2025-07-05 12:07:24] ✅ Verified CHD: Game.chd
[2025-07-05 12:07:24] 📉 Space saving for Game.cue: 700 MB → 350 MB, saved 350 MB (50%)
```

---

## Notes
- Temporary CHDs are created as `*.chd.tmp` then verified and renamed.
- Logs are written under `logs/`.
- DVD detection: prefers UDF via `file`, otherwise size heuristic (≥1 GB → DVD).

## 🌟 Roadmap

- [ ] M3U playlist generation for multi-disc sets  
- [ ] Detect multi-part RAR/7z archives  
- [ ] Add parallel conversion mode  

---

## 🛠 Requirements

- `bash` ≥ 5.0  
- `chdman` (from [MAME](https://www.mamedev.org/))
- `p7zip`, `unrar`, `unzip` for archives
- `file` utility (for CD/DVD detection)
- stat, file, find, grep, sort, tee

---

## 📜 License

[MIT License](LICENSE) © 2025 Lloyd Smart
