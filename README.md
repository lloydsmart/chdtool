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
[2025-07-05 14:00:12] 🚀 Script started, input dir: /mnt/retronas/roms/sega/saturn/
[2025-07-05 14:00:12] ℹ️ Using chdman - MAME Compressed Hunks of Data (CHD) manager 0.251 (unknown)
[2025-07-05 14:00:12] 🔎 Found 6 inputs
[2025-07-05 14:00:12] ▶️ Processing file: /mnt/retronas/roms/sega/saturn/Virtua Fighter (Europe).zip
[2025-07-05 14:00:12] 📦 Extracting Virtua Fighter (Europe).zip to /tmp/chdconv_Virtua Fighter (Europe)_a1B2
[2025-07-05 14:00:14] 💿 Converting: Virtua Fighter (Europe).cue → Virtua Fighter (Europe).chd.tmp
Compression complete ... final ratio = 58.7%
[2025-07-05 14:01:02] 🔎 Verifying: Virtua Fighter (Europe).chd.tmp
[2025-07-05 14:01:20] ✅ Verified CHD: Virtua Fighter (Europe).chd.tmp
[2025-07-05 14:01:20] 🔄 Replaced old CHD with new verified CHD: Virtua Fighter (Europe).chd
[2025-07-05 14:01:20] 🗑️ Removing original input file: Virtua Fighter (Europe).zip
[2025-07-05 14:01:20] 📉 Space saving for Virtua Fighter (Europe).zip: 640 MB → 375 MB, saved 265 MB (41%)
[2025-07-05 14:01:20] 🔤 Raw base name: Virtua Fighter (Europe)
[2025-07-05 14:01:20] 🔤 Normalized base name for M3U: virtua fighter
[2025-07-05 14:01:20] 🔍 Found 1 CHD candidate, remaining inputs: yes
[2025-07-05 14:01:20] 🧹 Cleaned up temp dir on exit: /tmp/chdconv_Virtua Fighter (Europe)_a1B2
[2025-07-05 14:01:20] 🎉 All inputs processed successfully!
[2025-07-05 14:01:20] 📊 Summary:
[2025-07-05 14:01:20] 📦 Total original size: 5 GB
[2025-07-05 14:01:20] 💿 Total CHD size: 4 GB
[2025-07-05 14:01:20] 📉 Total space saved: 1 GB (23%)
[2025-07-05 14:01:20] 📦 Archives processed: 6
[2025-07-05 14:01:20] 💿 CHDs created:       6
[2025-07-05 14:01:20] ❌ Failures:           0
[2025-07-05 14:01:20] ⏱️ Elapsed time: 55m 56s
[2025-07-05 14:01:20] ✅ Done!

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
