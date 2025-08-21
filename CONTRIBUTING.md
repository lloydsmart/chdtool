# Contributing

Thanks for your interest in contributing to **chdscript**! 🎉

## How to Contribute

1. **Fork the repo** and create your feature branch:  
   ```bash
   git checkout -b feature/my-new-feature
   ```

2. **Commit your changes** with clear messages:  
   ```bash
   git commit -m "Add support for XYZ"
   ```

3. **Push to the branch**:  
   ```bash
   git push origin feature/my-new-feature
   ```

4. **Open a Pull Request** against `main`.

## Coding Guidelines

- Follow the existing coding style (Bash best practices: `set -euo pipefail`, quoting variables, etc.).
- Use **inline comments** when adding non-obvious logic.
- Keep logging consistent (`log` vs. `verify_output_log`).

## Testing

- Test against a directory with both **single-disc** and **multi-disc** games.
- Run at least once with:
  - `--recursive`
  - `--keep-originals`
- Confirm space savings and CHD verification messages.

## Versioning

We use [Semantic Versioning](https://semver.org/) (semver).  
Bump version numbers when you:
- `MAJOR`: Break backward compatibility
- `MINOR`: Add new functionality in a backward-compatible manner
- `PATCH`: Fix bugs or make small improvements

---

💡 If unsure, open an **Issue** first to discuss before coding.
