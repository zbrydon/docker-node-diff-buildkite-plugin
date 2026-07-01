#!/usr/bin/env bats

setup() {
  PLUGIN_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  # Sourcing the command hook also sources lib/shared.bash; the main() guard
  # keeps it from running the full report. This exposes fit_pr_body and the
  # MARKER_*/MAX_PR_BODY_BYTES globals for direct testing.
  source "${PLUGIN_ROOT}/hooks/command"
  BODY="$(mktemp)"
}

teardown() {
  rm -f "${BODY}" "${BODY}.tmp"
}

# big BYTES -> a single line of that many 'x' characters.
big() { head -c "$1" /dev/zero | tr '\0' x; }

@test "fit_pr_body collapses the largest changelog first, keeps small ones" {
  {
    printf '%s\n\n' "$MARKER_START"
    printf '<details><summary>Node.js changelog</summary>\n\n'
    printf '#### v20.11.0\n\n<!-- dd:cl:20.11.0 -->\n%s\n\n<!-- /dd:cl:20.11.0 -->\n\n' "$(big 70000)"
    printf '#### v20.10.0\n\n<!-- dd:cl:20.10.0 -->\nten.\n\n<!-- /dd:cl:20.10.0 -->\n\n'
    printf '</details>\n\n'
    printf '%s\n' "$MARKER_END"
  } >"$BODY"

  fit_pr_body "$BODY"

  [ "$(wc -c <"$BODY")" -le "$MAX_PR_BODY_BYTES" ]
  # every version label stays visible (heading sits outside the collapsed region)
  grep -q '#### v20.11.0' "$BODY"
  grep -q '#### v20.10.0' "$BODY"
  # the large section is collapsed to its release link
  grep -q 'See https://github.com/nodejs/node/releases/tag/v20.11.0' "$BODY"
  # the small section is kept in full (largest-first, not all-or-nothing)
  grep -q '^ten\.$' "$BODY"
  run ! grep -q 'releases/tag/v20.10.0' "$BODY"
  # the single outer collapsible stays well-formed for the next in-place replacement
  grep -q 'Node.js changelog</summary>' "$BODY"
  grep -q 'docker-diff:start' "$BODY"
  grep -q 'docker-diff:end' "$BODY"
}

@test "fit_pr_body collapses an oversized package list to a count + note" {
  {
    printf '%s\n\n' "$MARKER_START"
    printf '<details><summary>842 package change(s)</summary>\n\n<!-- dd:pkg -->\n- %s\n\n</details>\n\n' "$(big 70000)"
    printf '%s\n' "$MARKER_END"
  } >"$BODY"

  fit_pr_body "$BODY"

  [ "$(wc -c <"$BODY")" -le "$MAX_PR_BODY_BYTES" ]
  grep -q '842 package change(s)</summary>' "$BODY"
  grep -qF "_Package details omitted to fit GitHub's PR size limit._" "$BODY"
  grep -q 'docker-diff:end' "$BODY"
}

@test "fit_pr_body leaves a body under the limit byte-for-byte unchanged" {
  {
    printf '%s\n\n' "$MARKER_START"
    printf '<details><summary>Node.js changelog</summary>\n\n'
    printf '#### v20.11.0\n\n<!-- dd:cl:20.11.0 -->\neleven.\n\n<!-- /dd:cl:20.11.0 -->\n\n'
    printf '</details>\n\n'
    printf '%s\n' "$MARKER_END"
  } >"$BODY"

  local before
  before="$(sha256_file "$BODY")"
  fit_pr_body "$BODY"
  [ "$before" = "$(sha256_file "$BODY")" ]
}

@test "fit_pr_body hard-truncates when nothing is collapsible" {
  {
    printf '%s\n\n' "$MARKER_START"
    # marker-free bulk that neither the changelog nor package tier can collapse
    printf '%s\n' "$(big 70000)"
    printf '%s\n' "$MARKER_END"
  } >"$BODY"

  fit_pr_body "$BODY"

  [ "$(wc -c <"$BODY")" -le "$MAX_PR_BODY_BYTES" ]
  grep -qF "_Report truncated to fit GitHub's PR size limit._" "$BODY"
  # the block is re-closed so it can still be found and replaced next run
  grep -q 'docker-diff:start' "$BODY"
  grep -q 'docker-diff:end' "$BODY"
}

@test "fit_pr_body hard-truncation preserves MARKER_START under a large preamble" {
  {
    # >65KB of non-collapsible user content ahead of the block; naive top-down
    # truncation would drop MARKER_START and orphan MARKER_END.
    printf 'pre: %s\n\n' "$(big 70000)"
    printf '%s\n\n' "$MARKER_START"
    printf 'the report\n\n'
    printf '%s\n' "$MARKER_END"
  } >"$BODY"

  fit_pr_body "$BODY"

  # both markers survive so the next run finds and replaces the block in place
  grep -qF "$MARKER_START" "$BODY"
  grep -qF "$MARKER_END" "$BODY"
  # exactly one of each: no duplicated/orphaned marker
  [ "$(grep -cF "$MARKER_START" "$BODY")" -eq 1 ]
  [ "$(grep -cF "$MARKER_END" "$BODY")" -eq 1 ]
}

@test "fit_pr_body hard-truncation counts bytes, not characters, for multibyte bulk" {
  {
    printf '%s\n\n' "$MARKER_START"
    # 40000 two-byte UTF-8 chars = 80000 bytes but only 40000 characters, so a
    # character-based budget would keep it and blow past the byte cap.
    perl -e 'print "\x{00e9}" x 40000, "\n"'
    printf '%s\n' "$MARKER_END"
  } >"$BODY"

  fit_pr_body "$BODY"

  [ "$(wc -c <"$BODY")" -le "$MAX_PR_BODY_BYTES" ]
  grep -q 'docker-diff:start' "$BODY"
  grep -q 'docker-diff:end' "$BODY"
}
