#!/usr/bin/env bats

setup() {
  PLUGIN_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  # Sourcing the command hook also sources lib/shared.bash; the main() guard
  # keeps it from running the full report.
  source "${PLUGIN_ROOT}/hooks/command"
}

sha() { printf "%0.s$1" $(seq 1 64); }  # 64-char fake digest of repeated char

@test "image_repo_family strips an embedded major-version token" {
  run image_repo_family "public.ecr.aws/seek-hirer-granite/node-22-alpine:latest@sha256:$(sha 0)"
  [ "$status" -eq 0 ]
  [ "$output" = "public.ecr.aws/seek-hirer-granite/node-alpine" ]
}

@test "image_repo_family strips a trailing version token" {
  run image_repo_family "public.ecr.aws/x/node-22:latest@sha256:$(sha 0)"
  [ "$output" = "public.ecr.aws/x/node" ]
}

@test "image_repo_family leaves non-numeric and dotted tokens intact" {
  run image_repo_family "registry/app-v2-service:tag@sha256:$(sha 0)"
  [ "$output" = "registry/app-v2-service" ]
  run image_repo_family "registry/node-18-alpine-3.20:tag@sha256:$(sha 0)"
  [ "$output" = "registry/node-alpine-3.20" ]
}

@test "image_repo_family normalizes only the name, not the namespace" {
  run image_repo_family "registry/team-1-svc/app:tag@sha256:$(sha 0)"
  [ "$output" = "registry/team-1-svc/app" ]
  run image_repo_family "registry/team-2-svc/app:tag@sha256:$(sha 0)"
  [ "$output" = "registry/team-2-svc/app" ]
}

@test "image_repo_family collapses adjacent version tokens" {
  run image_repo_family "registry/x/node-1-2-alpine:tag@sha256:$(sha 0)"
  [ "$output" = "registry/x/node-alpine" ]
}

@test "extract_refs ignores the syntax directive but keeps the FROM image" {
  removed="$(mktemp)"; added="$(mktemp)"
  diff="$(cat <<'EOF'
diff --git a/Dockerfile b/Dockerfile
--- a/Dockerfile
+++ b/Dockerfile
-# syntax=docker/dockerfile:1.24@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89
+# syntax=docker/dockerfile:1.25@sha256:0adf442eae370b6087e08edc7c50b552d80ddf261576f4ebd6421006b2461f12
-FROM public.ecr.aws/x/node-22-alpine:latest@sha256:63a48fcb03623f8c8d5eccf69c6b3c63bd4ac0309e43b57fbde3de5b864c6dc4 AS dev
+FROM public.ecr.aws/x/node-24-alpine:latest@sha256:d73a262627f23ecd818eb137918a17889b262b27ccfd596d6b265de632b623f2 AS dev
EOF
)"
  extract_refs "$diff" "$removed" "$added"
  run cat "$removed"
  [ "$output" = "public.ecr.aws/x/node-22-alpine:latest@sha256:63a48fcb03623f8c8d5eccf69c6b3c63bd4ac0309e43b57fbde3de5b864c6dc4" ]
  run cat "$added"
  [ "$output" = "public.ecr.aws/x/node-24-alpine:latest@sha256:d73a262627f23ecd818eb137918a17889b262b27ccfd596d6b265de632b623f2" ]
}

@test "pair_digests pairs a Node major bump that renames the repo" {
  removed="$(mktemp)"; added="$(mktemp)"
  printf 'public.ecr.aws/x/node-22-alpine:latest@sha256:%s\n' "$(sha 6)" >"$removed"
  printf 'public.ecr.aws/x/node-24-alpine:latest@sha256:%s\n' "$(sha d)" >"$added"
  run pair_digests "$removed" "$added"
  [ "$status" -eq 0 ]
  expected="public.ecr.aws/x/node-22-alpine:latest@sha256:$(sha 6)"$'\t'"public.ecr.aws/x/node-24-alpine:latest@sha256:$(sha d)"
  [ "$output" = "$expected" ]
}

@test "pair_digests does NOT guess when the family match is ambiguous" {
  removed="$(mktemp)"; added="$(mktemp)"
  printf 'reg/node-20-alpine:latest@sha256:%s\n' "$(sha 1)" >"$removed"
  printf 'reg/node-22-alpine:latest@sha256:%s\n' "$(sha 2)" >>"$removed"
  printf 'reg/node-23-alpine:latest@sha256:%s\n' "$(sha 3)" >"$added"
  printf 'reg/node-24-alpine:latest@sha256:%s\n' "$(sha 4)" >>"$added"
  run pair_digests "$removed" "$added"
  [ "$status" -eq 0 ]
  [ -z "$output" ]   # all four collapse to reg/node-alpine -> guard refuses
}
