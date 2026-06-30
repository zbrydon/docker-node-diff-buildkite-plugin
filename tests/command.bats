#!/usr/bin/env bats

B_DIGEST="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
A_DIGEST="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

setup() {
  HOOK="${BATS_TEST_DIRNAME}/../hooks/command"

  REPO="$(mktemp -d)"
  (
    cd "$REPO" || exit 1
    git init -q
    git config user.email t@t.com
    git config user.name t
    git checkout -q -b main
    printf 'FROM node:20@sha256:%s\n' "$B_DIGEST" >Dockerfile
    git add -A && git commit -qm init
    git checkout -q -b renovate-docker-images
    printf 'FROM node:20@sha256:%s\n' "$A_DIGEST" >Dockerfile
    git add -A && git commit -qm bump
  )

  STUB="$(mktemp -d)"
  GH_LOG="$(mktemp)"
  PR_BODY_FILE="$(mktemp)"
  export GH_LOG PR_BODY_FILE

  # syft stub: map digest -> node version (default: 20.9.0 -> 20.11.0). Every
  # scan also carries a libssl package that always changes between digests, so
  # there is a non-node package diff even when the Node.js version is unchanged.
  syft_versions "20.9.0" "20.11.0"

  cat >"${STUB}/curl" <<'EOF'
#!/bin/bash
url=""; out=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  case "$a" in http*) url="$a";; esac
  prev="$a"
done
emit() { if [ -n "$out" ]; then printf '%s' "$1" >"$out"; else printf '%s' "$1"; fi; }
case "$url" in
  *nodejs.org/dist/index.json)
    emit '[{"version":"v20.11.0"},{"version":"v20.10.0"},{"version":"v20.9.0"},{"version":"v20.8.0"}]' ;;
  *CHANGELOG_V20.md)
    emit '<a id="20.11.0"></a>
## Version 20.11.0
eleven.
<a id="20.10.0"></a>
## Version 20.10.0
ten.
<a id="20.9.0"></a>
## Version 20.9.0
nine.' ;;
  *) emit '' ;;
esac
EOF
  chmod +x "${STUB}/curl"

  cat >"${STUB}/gh" <<EOF
#!/bin/bash
echo "gh \$*" >> "${GH_LOG}"
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
  cat "${PR_BODY_FILE}"
elif [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
  printf '%s' "\${GH_PR_LIST_NUMBER:-}"
elif [ "\$1" = "pr" ] && [ "\$2" = "edit" ]; then
  bf=""; prev=""
  for a in "\$@"; do [ "\$prev" = "--body-file" ] && bf="\$a"; prev="\$a"; done
  cp "\$bf" "${PR_BODY_FILE}"
fi
EOF
  chmod +x "${STUB}/gh"
}

teardown() {
  rm -rf "${REPO}" "${STUB}" "${GH_LOG}" "${PR_BODY_FILE}"
}

# syft_versions BEFORE AFTER -> rewrite the syft stub. Each image carries a
# libssl package (version keyed by digest, so it always differs) plus the node
# binary at the requested version (omitted when the version is empty).
syft_versions() {
  cat >"${STUB}/syft" <<EOF
#!/bin/bash
ref=""
for a in "\$@"; do case "\$a" in registry:*) ref="\$a";; esac; done
case "\$ref" in
  *${B_DIGEST}*) node="$1"; ssl="3.5.6-1~deb13u1" ;;
  *${A_DIGEST}*) node="$2"; ssl="3.5.6-1~deb13u2" ;;
  *) node=""; ssl="" ;;
esac
arts=""
if [ -n "\$ssl" ]; then
  arts="{\"name\":\"libssl3t64\",\"type\":\"deb\",\"version\":\"\${ssl}\"}"
fi
if [ -n "\$node" ]; then
  [ -n "\$arts" ] && arts="\${arts},"
  arts="\${arts}{\"name\":\"node\",\"type\":\"binary\",\"version\":\"\${node}\"}"
fi
printf '{"artifacts":[%s]}\n' "\$arts"
EOF
  chmod +x "${STUB}/syft"
}

run_hook() {
  # $1 = BUILDKITE_PULL_REQUEST value, $2 = branch (default renovate-docker-images),
  # $3 = BUILDKITE_PULL_REQUEST_REPO (default base repo, i.e. same-repo PR)
  run env -i \
    PATH="${STUB}:${PATH}" \
    HOME="${HOME}" \
    BUILDKITE_BRANCH="${2:-renovate-docker-images}" \
    BUILDKITE_PIPELINE_DEFAULT_BRANCH="main" \
    BUILDKITE_PULL_REQUEST="$1" \
    BUILDKITE_REPO="https://github.com/acme/widget.git" \
    BUILDKITE_PULL_REQUEST_REPO="${3:-https://github.com/acme/widget.git}" \
    GITHUB_TOKEN="tok" \
    GH_PR_LIST_NUMBER="${GH_PR_LIST_NUMBER:-}" \
    bash -c "cd '${REPO}' && bash '${HOOK}'"
}

@test "reports a version change with the in-range releases" {
  printf 'Original body.\n' >"${PR_BODY_FILE}"
  run_hook 42
  [ "$status" -eq 0 ]
  grep -q "docker-diff:start" "${PR_BODY_FILE}"
  grep -q 'Node.js `20.9.0` → `20.11.0`' "${PR_BODY_FILE}"
  grep -q "v20.11.0</summary>" "${PR_BODY_FILE}"
  grep -q "v20.10.0</summary>" "${PR_BODY_FILE}"
  # the before-version is not in range (before < v <= after)
  run ! grep -q "v20.9.0</summary>" "${PR_BODY_FILE}"
  grep -q "Original body." "${PR_BODY_FILE}"
  # changed packages link to their registry/distro page
  grep -q '\[`libssl3t64`\](https://packages.debian.org/libssl3t64)' "${PR_BODY_FILE}"
  grep -q '\[`node`\](https://nodejs.org/en/blog/release/v20.11.0)' "${PR_BODY_FILE}"
}

@test "re-run replaces the block in place (idempotent)" {
  printf 'Original body.\n' >"${PR_BODY_FILE}"
  run_hook 42
  run_hook 42
  [ "$(grep -c "docker-diff:start" "${PR_BODY_FILE}")" -eq 1 ]
}

@test "replaces a large existing block in place (no SIGPIPE append)" {
  # Block interior > 64KB pipe buffer: the old printf|grep -q pipeline took
  # SIGPIPE (status 141) and appended a second block instead of replacing.
  {
    echo "Original body."
    echo "<!-- docker-diff:start -->"
    head -c 70000 </dev/zero | tr '\0' x
    echo
    echo "<!-- docker-diff:end -->"
  } >"${PR_BODY_FILE}"
  run_hook 42
  [ "$status" -eq 0 ]
  [ "$(grep -c "docker-diff:start" "${PR_BODY_FILE}")" -eq 1 ]
}

@test "collapses pre-existing duplicate blocks into one" {
  # A body that already carries two docker-diff blocks (e.g. from an earlier
  # stray append): the build must normalise it back to a single block, not
  # refresh both copies.
  {
    echo "Original body."
    echo "<!-- docker-diff:start -->"
    echo "stale one"
    echo "<!-- docker-diff:end -->"
    echo "<!-- docker-diff:start -->"
    echo "stale two"
    echo "<!-- docker-diff:end -->"
  } >"${PR_BODY_FILE}"
  run_hook 42
  [ "$status" -eq 0 ]
  [ "$(grep -c "docker-diff:start" "${PR_BODY_FILE}")" -eq 1 ]
  grep -q "Original body." "${PR_BODY_FILE}"
  ! grep -q "stale one" "${PR_BODY_FILE}"
  ! grep -q "stale two" "${PR_BODY_FILE}"
}

@test "keeps content below the block in place across re-runs" {
  # Renovate owns the body and appends a footer below our block. The footer must
  # stay below the block, not jump above it on the second run.
  printf 'Original body.\n' >"${PR_BODY_FILE}"
  run_hook 42
  printf '\n---\nThis PR was generated by Mend Renovate.\n' >>"${PR_BODY_FILE}"
  run_hook 42
  [ "$status" -eq 0 ]
  [ "$(grep -c "docker-diff:start" "${PR_BODY_FILE}")" -eq 1 ]
  local start_line end_line footer_line
  start_line="$(grep -n "docker-diff:start" "${PR_BODY_FILE}" | head -1 | cut -d: -f1)"
  end_line="$(grep -n "docker-diff:end" "${PR_BODY_FILE}" | head -1 | cut -d: -f1)"
  footer_line="$(grep -n "generated by Mend Renovate" "${PR_BODY_FILE}" | head -1 | cut -d: -f1)"
  # "Original body." stays above the block; the footer stays below it.
  grep -q "Original body." "${PR_BODY_FILE}"
  [ "$footer_line" -gt "$end_line" ]
  [ "$start_line" -gt 0 ]
}

@test "empty body gets the block with no leading horizontal rule" {
  : >"${PR_BODY_FILE}"
  run_hook 42
  [ "$status" -eq 0 ]
  # First non-blank line is the marker, not a stray '---' rule.
  local first
  first="$(grep -vE '^[[:space:]]*$' "${PR_BODY_FILE}" | head -1)"
  [[ "$first" == *"docker-diff:start"* ]]
}

@test "no node change still lists the package diff and clears stale changelogs" {
  printf 'Original body.\n' >"${PR_BODY_FILE}"
  run_hook 42
  grep -q "v20.11.0</summary>" "${PR_BODY_FILE}"
  syft_versions "20.9.0" "20.9.0"
  run_hook 42
  # node unchanged -> changelog blocks gone, but the libssl bump is still listed
  grep -q "no Node.js runtime change" "${PR_BODY_FILE}"
  grep -q "libssl3t64" "${PR_BODY_FILE}"
  ! grep -q "v20.11.0</summary>" "${PR_BODY_FILE}"
}

@test "package-only diff posts a fresh block with no existing markers" {
  # The real-world case: a digest bump that changes packages (libssl) but not
  # the Node.js runtime, on a PR whose description has no existing block.
  syft_versions "20.9.0" "20.9.0"
  printf 'Original body.\n' >"${PR_BODY_FILE}"
  run_hook 42
  [ "$status" -eq 0 ]
  grep -q "docker-diff:start" "${PR_BODY_FILE}"
  grep -q "Docker image changes" "${PR_BODY_FILE}"
  grep -q "libssl3t64" "${PR_BODY_FILE}"
  grep -q "no Node.js runtime change" "${PR_BODY_FILE}"
  grep -q "Original body." "${PR_BODY_FILE}"
}

@test "no image changes and no existing block leaves the PR untouched" {
  (
    cd "$REPO"
    git checkout -q renovate-docker-images
    # Keep the same digest as main and change only a non-image line, so the diff
    # carries no @sha256 refs at all.
    printf 'FROM node:20@sha256:%s\n# unrelated change\n' "$B_DIGEST" >Dockerfile
    git add -A && git commit -qm noise
  )
  printf 'Pristine body.\n' >"${PR_BODY_FILE}"
  run_hook 42
  [ "$(cat "${PR_BODY_FILE}")" = "Pristine body." ]
}

@test "branch-push build with no open PR skips the PR update" {
  printf 'untouched\n' >"${PR_BODY_FILE}"
  GH_PR_LIST_NUMBER="" run_hook false
  [ "$status" -eq 0 ]
  # only the branch lookup is attempted; no view/edit
  grep -q "gh pr list" "${GH_LOG}"
  run ! grep -q "gh pr edit" "${GH_LOG}"
  [ "$(cat "${PR_BODY_FILE}")" = "untouched" ]
}

@test "branch-push build resolves an open PR by branch and updates it" {
  printf 'Original body.\n' >"${PR_BODY_FILE}"
  GH_PR_LIST_NUMBER="42" run_hook false
  [ "$status" -eq 0 ]
  grep -q "gh pr list" "${GH_LOG}"
  grep -q "docker-diff:start" "${PR_BODY_FILE}"
  grep -q "Original body." "${PR_BODY_FILE}"
}

@test "branch not in allow-list is skipped" {
  run_hook false "feature/x"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not in allow-list"* ]]
}

@test "fork PR (source repo != base repo) is refused before scanning" {
  printf 'untouched\n' >"${PR_BODY_FILE}"
  run_hook 42 "renovate-docker-images" "https://github.com/attacker/widget.git"
  [ "$status" -eq 0 ]
  [[ "$output" == *"refusing to scan"* ]]
  [ ! -s "${GH_LOG}" ]
  [ "$(cat "${PR_BODY_FILE}")" = "untouched" ]
}

@test "non-node image still lists its package diff but no changelog" {
  syft_versions "" ""
  printf 'body\n' >"${PR_BODY_FILE}"
  run_hook 42
  [ "$status" -eq 0 ]
  grep -q "no Node.js runtime change" "${PR_BODY_FILE}"
  grep -q "libssl3t64" "${PR_BODY_FILE}"
  ! grep -q "summary>v" "${PR_BODY_FILE}"
}

@test "handles multiple changed images" {
  (
    cd "$REPO"
    # base (main) carries both images; branch bumps both digests
    git checkout -q main
    printf 'FROM node:20@sha256:%s\nFROM node:18@sha256:%s\n' \
      "$B_DIGEST" "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" >Dockerfile
    git add -A && git commit -qm base-multi
    git branch -qD renovate-docker-images
    git checkout -q -b renovate-docker-images
    printf 'FROM node:20@sha256:%s\nFROM node:18@sha256:%s\n' \
      "$A_DIGEST" "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" >Dockerfile
    git add -A && git commit -qm bump-multi
  )
  # second image (node:18) maps cccc -> 18.x; extend syft stub
  cat >"${STUB}/syft" <<EOF
#!/bin/bash
ref=""
for a in "\$@"; do case "\$a" in registry:*) ref="\$a";; esac; done
case "\$ref" in
  *${B_DIGEST}*) ver="20.9.0" ;;
  *${A_DIGEST}*) ver="20.11.0" ;;
  *dddddddddddd*) ver="18.18.0" ;;
  *cccccccccccc*) ver="18.19.0" ;;
  *) ver="" ;;
esac
printf '{"artifacts":[{"name":"node","type":"binary","version":"%s"}]}\n' "\$ver"
EOF
  chmod +x "${STUB}/syft"
  printf 'body\n' >"${PR_BODY_FILE}"
  run_hook 42
  grep -q "2 bumped the Node.js runtime" "${PR_BODY_FILE}"
}
