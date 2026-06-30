# Docker Diff Buildkite Plugin

On a [Renovate](https://docs.renovatebot.com/) Docker-digest-update pull request, this
plugin scans the before/after images with [Syft](https://github.com/anchore/syft) and
posts the **package-level diff for every bumped image** into the PR description. When an
image's **Node.js runtime version** changed, it additionally posts the **Node.js changelog
for every release in between**. The block is refreshed in place on every build.

## Example

```yaml
steps:
  - label: ":node: changelog diff"
    plugins:
      - zbrydon/docker-diff#v1.0.0:
          branches:
            - renovate-docker-images
            - renovate/docker-digests
          github-token-env: GH_PR_TOKEN
```

## How it works

1. **Branch gate** - only runs on the configured `branches`, and on a pull
   request build only when the PR source repo matches the base repo (so a fork
   PR cannot drive the scan; see [Security](#security)).
2. **Diff** - `git diff <default-branch>...HEAD` (the pipeline's default branch) and
   extracts `@sha256:` image refs from the removed (`-`) and added (`+`) lines, pairing
   them by `repo:tag` then by repository. Refs are paired across the whole diff, so a
   monorepo bumping the _same_ image name in multiple files could cross-pair; this is
   correct for the typical single-image Renovate PR. Duplicate before/after pairs (e.g.
   the same image pinned via several Compose anchors) are scanned and reported once.
3. **Scan & diff packages** - `syft scan registry:<ref>` catalogues each image's packages.
   For every bumped image the report lists the package changes (added / removed / version
   bumped), including non-Node packages such as `libssl3t64`. Each changed package name
   links to its registry/distro page (npm, Debian packages, Alpine packages) or the
   Node.js release notes for `node`.
4. **Changelogs** - when the `node` package version moved, fetches
   `https://nodejs.org/dist/index.json`, selects every release with `before < v <= after`
   (capped at 20), and extracts each release's section from the Node.js changelog on GitHub.
5. **Upsert** - writes the report between hidden markers in the PR description via `gh`,
   replacing any previous block so the description stays current. On a PR-triggered build
   Buildkite supplies the PR number in `BUILDKITE_PULL_REQUEST`; on a branch-push build
   (where that variable is `false`, e.g. for many draft PRs) the plugin falls back to
   `gh pr list --head <branch> --state open` to resolve an open PR (drafts included) for
   the current branch, and skips the update if none exists.

## Configuration

All options are optional.

| Option             | Type            | Default                                                                           | Description                                                                                                    |
| ------------------ | --------------- | --------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `branches`         | string \| array | `renovate-docker-images`                                                          | Branches the plugin is allowed to run on.                                                                      |
| `syft-version`     | string          | `v1.46.0@sha256:2fefc202b2eccab83888cc91f5a364a75df0dd777afbbae5b5e23ebd93d81ac6` | Pinned Syft release as `<version>@sha256:<digest>` (see [Syft integrity](#security)). Must include the digest. |
| `github-token-env` | string          | `GITHUB_TOKEN`                                                                    | Name of the env var holding the PR-write token.                                                                |

## Requirements

- `jq`, `git`, `curl`, `tar` and `gh` on the agent.
- A GitHub token with PR-write access. Without it the plugin still runs and prints the report but skips the PR update.

The `environment` hook downloads the pinned Syft release and verifies it before
installing it onto `PATH`. The `syft-version` pin is a `<version>@sha256:<digest>`
token (default baked into the plugin); the digest is the sha256 of that release's
`checksums.txt`, so it transitively pins every platform's binary. This plugin
assumes **ephemeral agents**: it re-downloads Syft each build and leaves the
install dir behind, which would accumulate on a persistent agent.

## Security

This plugin scans Docker images and renders content derived from the PR diff
into the PR description with a write-capable token. Treat the diff as the trust
boundary:

- **Fork PRs are refused.** The branch allow-list is not a trust boundary - a
  fork can name its branch anything. On a pull request build the plugin only
  runs when the PR source repo (`BUILDKITE_PULL_REQUEST_REPO`) matches the base
  repo (`BUILDKITE_REPO`). Even so, do not expose the PR-write token to
  fork/untrusted builds as a matter of pipeline policy.
- **Syft integrity.** The trust root is pinned in this repo. The `syft-version`
  value is `<version>@sha256:<digest>`, where the digest is the sha256 of the
  release's `checksums.txt`. The `environment` hook downloads that
  `checksums.txt`, refuses to proceed unless its sha256 matches the pinned
  digest, then verifies the downloaded archive against the (now-trusted)
  manifest. Because the digest lives in version control, the installed binary
  cannot change without a reviewable change to the pin - GitHub is no longer the
  sole integrity root. There is still no cosign/GPG signature verification, so
  trust is established at the moment you compute the digest; verify the release
  out of band before bumping the pin.

### Updating Syft

To bump the pinned version, recompute the digest of the new release's
`checksums.txt` and update `SYFT_DEFAULT_PIN` in `hooks/environment` (or the
`syft-version` option in your pipeline):

```bash
v=1.47.0
curl --proto '=https' --tlsv1.2 -fsSL \
  "https://github.com/anchore/syft/releases/download/v${v}/syft_${v}_checksums.txt" \
  | sha256sum
# -> set the pin to "v${v}@sha256:<that digest>"
```

The change lands as a one-line, reviewable diff, so the Syft binary can never
move without your knowledge.

## Development

```bash
shellcheck -x hooks/environment hooks/command lib/shared.bash
bats tests/
```

## License

MIT (see [LICENSE](LICENSE)).
