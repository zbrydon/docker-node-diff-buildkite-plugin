#!/usr/bin/env bats

setup() {
  HOOK="${BATS_TEST_DIRNAME}/../hooks/environment"
  STUB="$(mktemp -d)"
  export PATH="${STUB}:${PATH}"

  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/; s/arm64/arm64/')"
  export ASSET="syft_1.46.0_${os}_${arch}.tar.gz"

  # sha256 of the fixed fake tarball, portable across linux/macos
  GOOD_SUM="$(sha_str_file <(printf 'FAKE_SYFT_TARBALL'))"
  export GOOD_SUM

  # `tar` stub: drop a fake executable syft into the -C directory.
  cat >"${STUB}/tar" <<'EOF'
#!/bin/bash
prev=""; cdir="."
for a in "$@"; do [ "$prev" = "-C" ] && cdir="$a"; prev="$a"; done
printf '#!/bin/bash\necho "syft 1.46.0"\n' > "$cdir/syft"
chmod +x "$cdir/syft"
EOF
  chmod +x "${STUB}/tar"
}

teardown() {
  rm -rf "${STUB}"
  unset BUILDKITE_PLUGIN_DOCKER_DIFF_SYFT_VERSION
}

# sha_str_file FILE -> lowercase hex sha256, portable across linux/macos.
sha_str_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# publish ASSET_SUM -> serve a checksums.txt listing ASSET_SUM for the asset, and
# pin `syft-version` to a digest that matches that exact manifest file, so the
# trust gate passes and verification reaches the asset check.
publish() {
  printf '%s  %s\n' "$1" "${ASSET}" > "${STUB}/manifest"
  export BUILDKITE_PLUGIN_DOCKER_DIFF_SYFT_VERSION="v1.46.0@sha256:$(sha_str_file "${STUB}/manifest")"
  write_curl
}

write_curl() {
  cat >"${STUB}/curl" <<EOF
#!/bin/bash
url=""; out=""; prev=""
for a in "\$@"; do
  [ "\$prev" = "-o" ] && out="\$a"
  case "\$a" in http*) url="\$a";; esac
  prev="\$a"
done
case "\$url" in
  *.tar.gz)       printf 'FAKE_SYFT_TARBALL' > "\$out" ;;
  *checksums.txt) cp "${STUB}/manifest" "\$out" ;;
esac
EOF
  chmod +x "${STUB}/curl"
}

@test "downloads, verifies and installs syft onto PATH" {
  publish "$GOOD_SUM"

  run bash -c "source '${HOOK}'; command -v syft && syft --version"
  [ "$status" -eq 0 ]
  [[ "$output" == *"syft 1.46.0"* ]]
}

@test "fails closed on asset checksum mismatch" {
  # Manifest matches the pin, but the entry for the asset is wrong, so the
  # downloaded tarball does not match its own listed checksum.
  publish "deadbeefdeadbeef"

  run bash -c "source '${HOOK}'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]]
}

@test "fails closed when checksums.txt does not match the pinned digest" {
  publish "$GOOD_SUM"
  # Override the pin with a valid-shape but wrong digest.
  export BUILDKITE_PLUGIN_DOCKER_DIFF_SYFT_VERSION="v1.46.0@sha256:$(printf 0%.0s {1..64})"

  run bash -c "source '${HOOK}'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match the pinned sha256"* ]]
}

@test "rejects a syft-version without a pinned digest" {
  export BUILDKITE_PLUGIN_DOCKER_DIFF_SYFT_VERSION="v1.46.0"

  run bash -c "source '${HOOK}'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid syft-version"* ]]
}

@test "downloads on every build (no cache reuse)" {
  publish "$GOOD_SUM"
  # Wrap the curl stub so each invocation is counted.
  mv "${STUB}/curl" "${STUB}/curl.real"
  cat >"${STUB}/curl" <<EOF
#!/bin/bash
echo x >> "${STUB}/calls"
exec "${STUB}/curl.real" "\$@"
EOF
  chmod +x "${STUB}/curl"

  bash -c "source '${HOOK}'"
  bash -c "source '${HOOK}'"
  # two builds -> 4 curl calls (asset + checksums each)
  [ "$(wc -l <"${STUB}/calls")" -eq 4 ]
}
