#!/bin/bash
# Reusable helpers for the docker-diff plugin. Sourced by both hooks.

PLUGIN_PREFIX="DOCKER_DIFF"

# plugin_read NAME [default] -> value of BUILDKITE_PLUGIN_<PREFIX>_<NAME>, or default.
plugin_read() {
  local name="$1"
  local default="${2:-}"
  local var="BUILDKITE_PLUGIN_${PLUGIN_PREFIX}_${name}"
  printf '%s' "${!var:-$default}"
}

# read_list_property NAME -> fills global array `result` from a scalar or _0,_1,... array.
# Returns non-zero when the property is unset/empty.
read_list_property() {
  local base="BUILDKITE_PLUGIN_${PLUGIN_PREFIX}_${1}"
  result=()

  if [ -n "${!base:-}" ]; then
    result+=("${!base}")
  fi

  local i=0
  local key="${base}_${i}"
  while [ -n "${!key:-}" ]; do
    result+=("${!key}")
    i=$((i + 1))
    key="${base}_${i}"
  done

  [ ${#result[@]} -gt 0 ]
}

# image_repo_tag REF -> REF with the @digest removed.
image_repo_tag() {
  printf '%s' "${1%@*}"
}

# image_repo REF -> registry/name, stripping :tag and @digest (registry ports kept).
image_repo() {
  local ref="${1%@*}"        # drop @digest
  local name="${ref##*/}"    # last path segment, may carry :tag
  local prefix=""
  if [ "$name" != "$ref" ]; then
    prefix="${ref%/*}/"      # registry[:port]/path/
  fi
  name="${name%:*}"          # drop :tag (tags never contain ':')
  printf '%s' "${prefix}${name}"
}

# repo_slug URL -> owner/name, stripping host, scheme, .git suffix, trailing slash.
repo_slug() {
  printf '%s' "$1" | sed -E 's#^.*github\.com[:/]##; s#\.git$##; s#/$##'
}

# is_node_version V -> success when V is exactly major.minor.patch (digits only).
is_node_version() {
  case "$1" in '' | *[!0-9.]*) return 1 ;; esac
  local IFS=.
  # shellcheck disable=SC2086 # deliberate: split V on dots into the three parts
  set -- $1
  [ $# -eq 3 ] && [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ]
}

# short_digest REF -> first 12 hex chars of the sha256 digest, for logs.
short_digest() {
  local d="${1##*@sha256:}"
  printf '%s' "${d:0:12}"
}

# version_gt A B -> success when A is strictly greater than B (numeric, via sort -V).
version_gt() {
  [ "$1" = "$2" ] && return 1
  local hi
  hi="$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)"
  [ "$hi" = "$1" ]
}

# sha256_file FILE -> lowercase hex sha256 of FILE (portable across sha256sum/shasum).
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# parse_syft_pin PIN -> splits "<version>@sha256:<64 hex>" into SYFT_PIN_VERSION
# and SYFT_PIN_SHA256 (lowercased). Non-zero if either part is missing/malformed.
parse_syft_pin() {
  local pin="$1" ver sha
  case "$pin" in *@sha256:*) ;; *) return 1 ;; esac
  ver="${pin%@sha256:*}"
  sha="${pin##*@sha256:}"
  [ -n "$ver" ] || return 1
  case "$sha" in '' | *[!0-9a-fA-F]*) return 1 ;; esac
  [ "${#sha}" -eq 64 ] || return 1
  # shellcheck disable=SC2034 # consumed by hooks/environment after sourcing
  SYFT_PIN_VERSION="$ver"
  # shellcheck disable=SC2034 # consumed by hooks/environment after sourcing
  SYFT_PIN_SHA256="$(printf '%s' "$sha" | tr 'A-F' 'a-f')"
}
