#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.fkst/env"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

DEFAULT_OFFICIAL_SOURCE_URL="https://github.com/ChronoAIProject/fkst-hosted.git"
DEFAULT_OFFICIAL_SOURCE_REF="28563dd34e5eb4d4a481bd0e630d41378d49b3f6"
FKST_OFFICIAL_PACKAGE_SOURCE_URL="${FKST_OFFICIAL_PACKAGE_SOURCE_URL:-$DEFAULT_OFFICIAL_SOURCE_URL}"
FKST_OFFICIAL_PACKAGE_SOURCE_REF="${FKST_OFFICIAL_PACKAGE_SOURCE_REF:-$DEFAULT_OFFICIAL_SOURCE_REF}"

OFFICIAL_CACHE="$ROOT/.fkst/cache/fkst-hosted-src"
OFFICIAL_ROOT="$ROOT/.fkst/official/fkst-hosted"
OFFICIAL_PROXY_ROOT="$OFFICIAL_ROOT/packages/github-proxy"

MARKETING_ROOTS=(
  "$ROOT/packages/x-publisher"
  "$ROOT/packages/github-auto-twitter-marketing"
  "$ROOT/packages/marketing-radar"
)

usage() {
  cat <<'USAGE'
usage:
  scripts/run.sh check
  scripts/run.sh test [package]
  scripts/run.sh test-composed
  scripts/run.sh run <package> <department> <event-json>
  scripts/run.sh supervise [package]
  scripts/run.sh export-official

Environment:
  BIN                              Path to fkst-framework.
  FKST_OFFICIAL_PACKAGE_SOURCE_URL Official package source Git URL.
  FKST_OFFICIAL_PACKAGE_SOURCE_REF Official package source ref/SHA.
USAGE
}

require_runtime_path() {
  local target="$1"
  case "$target" in
    "$ROOT"/.fkst/*) ;;
    *)
      echo "refusing to modify path outside .fkst: $target" >&2
      exit 2
      ;;
  esac
}

resolve_bin() {
  if [ -n "${BIN:-}" ]; then
    printf '%s\n' "$BIN"
    return
  fi
  if command -v fkst-framework >/dev/null 2>&1; then
    command -v fkst-framework
    return
  fi
  local sibling="$ROOT/../fkst-substrate/target/debug/fkst-framework"
  if [ -x "$sibling" ]; then
    printf '%s\n' "$sibling"
    return
  fi
  echo ""
}

FRAMEWORK_BIN="$(resolve_bin)"
if [ -z "$FRAMEWORK_BIN" ] || [ ! -x "$FRAMEWORK_BIN" ]; then
  echo "fkst-framework binary not found; set BIN in .fkst/env or environment" >&2
  exit 2
fi

export FKST_RUNTIME_ROOT="${FKST_RUNTIME_ROOT:-$ROOT/.fkst/run/runtime}"
export FKST_DURABLE_ROOT="${FKST_DURABLE_ROOT:-$ROOT/.fkst/run/durable}"

ensure_official_package() {
  require_runtime_path "$OFFICIAL_CACHE"
  require_runtime_path "$OFFICIAL_ROOT"

  mkdir -p "$ROOT/.fkst/cache" "$ROOT/.fkst/official"

  if [ ! -d "$OFFICIAL_CACHE/.git" ]; then
    rm -rf "$OFFICIAL_CACHE"
    git clone --no-checkout --filter=blob:none "$FKST_OFFICIAL_PACKAGE_SOURCE_URL" "$OFFICIAL_CACHE" >/dev/null
  fi

  git -C "$OFFICIAL_CACHE" remote set-url origin "$FKST_OFFICIAL_PACKAGE_SOURCE_URL"
  git -C "$OFFICIAL_CACHE" fetch --no-tags --depth 1 origin "$FKST_OFFICIAL_PACKAGE_SOURCE_REF" >/dev/null
  git -C "$OFFICIAL_CACHE" checkout --detach FETCH_HEAD >/dev/null

  rm -rf "$OFFICIAL_ROOT"
  mkdir -p "$OFFICIAL_ROOT/packages" "$OFFICIAL_ROOT/libraries"

  for file in fkst.workspace.toml fkst.lock; do
    if [ -f "$OFFICIAL_CACHE/$file" ]; then
      cp "$OFFICIAL_CACHE/$file" "$OFFICIAL_ROOT/$file"
    fi
  done

  cp -R "$OFFICIAL_CACHE/packages/github-proxy" "$OFFICIAL_ROOT/packages/github-proxy"
  rm -rf "$OFFICIAL_ROOT/packages/github-proxy/tests"
  rm -rf "$OFFICIAL_ROOT/packages/github-proxy/departments/test_entity_view_probe"

  for library in contract forge workflow testkit devloop github-proxy-effects; do
    cp -R "$OFFICIAL_CACHE/libraries/$library" "$OFFICIAL_ROOT/libraries/$library"
  done
}

package_root_for() {
  local package="$1"
  local root="$ROOT/packages/$package"
  if [ ! -d "$root" ]; then
    echo "unknown package: $package" >&2
    exit 2
  fi
  printf '%s\n' "$root"
}

PACKAGE_ROOT_ARGS=()

set_all_roots() {
  PACKAGE_ROOT_ARGS=(--package-root "$OFFICIAL_PROXY_ROOT")
  for root in "${MARKETING_ROOTS[@]}"; do
    PACKAGE_ROOT_ARGS+=(--package-root "$root")
  done
}

set_package_roots() {
  local package="$1"
  local root
  root="$(package_root_for "$package")"
  PACKAGE_ROOT_ARGS=()

  case "$package" in
    github-auto-twitter-marketing)
      PACKAGE_ROOT_ARGS+=(--package-root "$OFFICIAL_PROXY_ROOT")
      PACKAGE_ROOT_ARGS+=(--package-root "$ROOT/packages/x-publisher")
      PACKAGE_ROOT_ARGS+=(--package-root "$root")
      ;;
    marketing-radar)
      PACKAGE_ROOT_ARGS+=(--package-root "$OFFICIAL_PROXY_ROOT")
      PACKAGE_ROOT_ARGS+=(--package-root "$root")
      ;;
    *)
      PACKAGE_ROOT_ARGS+=(--package-root "$root")
      ;;
  esac
}

check_file_sizes() {
  local failures=0
  while IFS= read -r -d '' file; do
    local lines
    lines="$(wc -l < "$file" | tr -d ' ')"
    if [ "$lines" -gt 1000 ]; then
      echo "file exceeds 1000 lines: $file ($lines)" >&2
      failures=1
    fi
  done < <(find "$ROOT/packages" "$ROOT/libraries" "$ROOT/scripts" -type f \( -name '*.lua' -o -name '*.sh' -o -name '*.py' -o -name '*.rs' \) -print0)
  return "$failures"
}

cmd_check() {
  "$FRAMEWORK_BIN" deps --project-root "$ROOT" >/dev/null
  check_file_sizes
}

prepare_test_roots() {
  local name="$1"
  local test_root="$ROOT/.fkst/run/test/$name"
  require_runtime_path "$test_root"
  rm -rf "$test_root"
  mkdir -p "$test_root"
  export FKST_RUNTIME_ROOT="$test_root/runtime"
  export FKST_DURABLE_ROOT="$test_root/durable"
}

run_package_test() {
  local package="$1"
  ensure_official_package
  prepare_test_roots "$package"
  set_package_roots "$package"
  "$FRAMEWORK_BIN" test --project-root "$ROOT" "${PACKAGE_ROOT_ARGS[@]}"
}

cmd_test() {
  if [ "$#" -gt 0 ]; then
    run_package_test "$1"
    return
  fi

  run_package_test x-publisher
  run_package_test github-auto-twitter-marketing
  run_package_test marketing-radar
}

cmd_test_composed() {
  ensure_official_package
  prepare_test_roots composed
  set_all_roots
  "$FRAMEWORK_BIN" deps --project-root "$ROOT" "${PACKAGE_ROOT_ARGS[@]}" >/dev/null
  "$FRAMEWORK_BIN" conformance --project-root "$ROOT" "${PACKAGE_ROOT_ARGS[@]}"
  run_package_test x-publisher
  run_package_test github-auto-twitter-marketing
  run_package_test marketing-radar
}

cmd_run() {
  if [ "$#" -ne 3 ]; then
    usage >&2
    exit 2
  fi
  ensure_official_package
  local package="$1"
  local department="$2"
  local event_json="$3"
  local package_root
  package_root="$(package_root_for "$package")"
  local handler="$package_root/departments/$department/main.lua"
  if [ ! -f "$handler" ]; then
    echo "unknown department handler: $handler" >&2
    exit 2
  fi
  set_all_roots
  "$FRAMEWORK_BIN" run "$handler" --project-root "$ROOT" "${PACKAGE_ROOT_ARGS[@]}" --event "$event_json"
}

cmd_supervise() {
  ensure_official_package
  if [ "$#" -gt 0 ]; then
    set_package_roots "$1"
  else
    set_all_roots
  fi
  "$FRAMEWORK_BIN" supervise --project-root "$ROOT" --framework-bin "$FRAMEWORK_BIN" "${PACKAGE_ROOT_ARGS[@]}"
}

case "${1:-}" in
  check)
    shift
    cmd_check "$@"
    ;;
  test)
    shift
    cmd_test "$@"
    ;;
  test-composed)
    shift
    cmd_test_composed "$@"
    ;;
  run)
    shift
    cmd_run "$@"
    ;;
  supervise)
    shift
    cmd_supervise "$@"
    ;;
  export-official)
    ensure_official_package
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
