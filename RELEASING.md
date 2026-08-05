# Release procedure

This project uses a gitflow-style release process. Development is integrated on
`develop`; releases are made from `main` and triggered by tags named
`vMAJOR.MINOR.PATCH`.

## Prerequisites

- Push access to `lloydsmart/chdtool`
- Permission to merge into `develop` and `main`
- GitHub Actions permission to create pull requests
- Bash, Make, ShellCheck, `tar`, `gzip`, `zip`, `unzip`, and `sha256sum`
- `git-cliff` when generating changelogs locally

Start with a clean, current checkout:

```bash
git switch develop
git pull --ff-only origin develop
git status --short
```

The final command should print nothing.

## 1. Choose and set the version

Choose the next version according to Semantic Versioning. Create a release
branch from `develop`. Keep the `v` in the branch name when using git-flow:

```bash
git switch -c release/v0.2.5
```

Update `CHDTOOL_VERSION` near the top of `chdtool.sh`. Confirm that the CLI
reports the intended value:

```bash
./chdtool.sh --version
```

The release workflow rejects a tag whose version does not match this value.

## 2. Run the preflight checks

Run the same functional and shell checks used by the release workflow:

```bash
make test
shellcheck chdtool.sh scripts/*.sh tests/*.sh tests/bin/*
```

When `actionlint` and `markdownlint-cli2` are available, also run:

```bash
actionlint
npx --yes markdownlint-cli2 "**/*.md" "#CHANGELOG.md" \
  "#CHANGELOG_RELEASE.md" "#LICENSE.md"
```

Build and validate the release assets locally:

```bash
make package VERSION=0.2.5
(cd dist && sha256sum --check SHA256SUMS)
tar -tzf dist/chdtool-v0.2.5.tar.gz
unzip -Z1 dist/chdtool-v0.2.5.zip
```

Both archives must contain exactly one top-level `chdtool-v0.2.5` directory
with these files:

- `chdtool`
- `README.md`
- `LICENSE.md`
- `CHANGELOG.md`

The `dist/` directory is rebuilt from scratch by the packaging command.

## 3. Promote the release to main

Commit the version change, push the release branch, and open a pull request
directly into `main`:

```bash
git add chdtool.sh
git commit -m "chore: prepare v0.2.5"
git push -u origin release/v0.2.5
```

The pull request represents the complete promotion of the release candidate
from `develop` to `main`. Merge only after all required checks pass. Do not tag
the release branch or an unmerged commit.

## 4. Tag and publish

Update local `main` and verify the version one final time:

```bash
git switch main
git pull --ff-only origin main
./chdtool.sh --version
git status --short
```

Create an annotated tag on that exact commit and push only the tag:

```bash
git tag -a v0.2.5 -m "Release v0.2.5"
git push origin v0.2.5
```

Pushing the tag starts the `Release` workflow. It:

1. runs the complete test suite and ShellCheck;
2. generates release notes with git-cliff;
3. builds reproducible `.tar.gz` and `.zip` archives;
4. validates their exact contents;
5. creates `SHA256SUMS` and verifies every checksum;
6. publishes the GitHub release and assets; and
7. opens a pull request to update `CHANGELOG.md` on `main`.

## 5. Verify and synchronise

On the GitHub release page, confirm:

- the release is attached to the intended tag and commit;
- the release notes are present;
- `chdtool`, both archives, and `SHA256SUMS` are attached; and
- downloaded assets pass `sha256sum --check SHA256SUMS`.

Merge the automated changelog pull request after its checks pass. Finally, open
a backport pull request from `main` into `develop` so both long-lived branches
contain the release merge, tag history, and generated changelog. Resolve the
backport before starting further release work.

## Failure handling

- If preflight checks or local packaging fail, fix them on the release branch;
  do not tag.
- If the tag workflow fails before publishing a release, inspect the failed job,
  fix the problem through the normal branch and pull-request flow, then decide
  whether the unused tag can be deleted and recreated.
- Never move or reuse a tag after a GitHub release has been published. Correct a
  published release with a new patch version.
- Do not upload hand-built replacement assets to an automated release; rerun a
  corrected workflow under a new version so provenance and checksums remain
  consistent.
