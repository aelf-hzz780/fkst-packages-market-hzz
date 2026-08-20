#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.fkst/env"
COMMAND="${1:-}"
FORMAL_GATE=false

if [ "$COMMAND" = "formal-gate" ]; then
  FORMAL_GATE=true
  if [ "${FKST_FRAMEWORK_EXPECTED_SHA+x}" = "x" ]; then
    echo "formal-gate rejects process environment override: FKST_FRAMEWORK_EXPECTED_SHA" >&2
    exit 2
  fi
  if [ "${FKST_OFFICIAL_PACKAGE_SOURCE_URL+x}" = "x" ]; then
    echo "formal-gate rejects process environment override: FKST_OFFICIAL_PACKAGE_SOURCE_URL" >&2
    exit 2
  fi
  if [ "${FKST_OFFICIAL_PACKAGE_SOURCE_REF+x}" = "x" ]; then
    echo "formal-gate rejects process environment override: FKST_OFFICIAL_PACKAGE_SOURCE_REF" >&2
    exit 2
  fi
elif [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

DEFAULT_OFFICIAL_SOURCE_URL="https://github.com/ChronoAIProject/fkst-hosted.git"
DEFAULT_OFFICIAL_SOURCE_REF="6fe5f82f76f6b2c02058488587f5f6281c203cf3"
if [ "$FORMAL_GATE" = true ]; then
  FKST_OFFICIAL_PACKAGE_SOURCE_URL="$DEFAULT_OFFICIAL_SOURCE_URL"
  FKST_OFFICIAL_PACKAGE_SOURCE_REF="$DEFAULT_OFFICIAL_SOURCE_REF"
else
  FKST_OFFICIAL_PACKAGE_SOURCE_URL="${FKST_OFFICIAL_PACKAGE_SOURCE_URL:-$DEFAULT_OFFICIAL_SOURCE_URL}"
  FKST_OFFICIAL_PACKAGE_SOURCE_REF="${FKST_OFFICIAL_PACKAGE_SOURCE_REF:-$DEFAULT_OFFICIAL_SOURCE_REF}"
fi

if [[ ! "$FKST_OFFICIAL_PACKAGE_SOURCE_REF" =~ ^[0-9a-f]{40}$ ]]; then
  echo "FKST_OFFICIAL_PACKAGE_SOURCE_REF must be a full lowercase 40-character SHA" >&2
  exit 2
fi

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
  scripts/run.sh formal-gate
  scripts/run.sh check
  scripts/run.sh verify-framework
  scripts/run.sh test [package]
  scripts/run.sh test-composed
  scripts/run.sh run <package> <department> <event-json>
  scripts/run.sh supervise [package]
  scripts/run.sh export-official

Environment:
  BIN                              Path to fkst-framework.
  FKST_FRAMEWORK_EXPECTED_SHA      Explicit full-SHA override for testing another framework build.
  FKST_FRAMEWORK_SOURCE_ROOT       fkst-substrate checkout for custom binary target layouts.
  FKST_OFFICIAL_PACKAGE_SOURCE_URL Diagnostic official package source Git URL.
  FKST_OFFICIAL_PACKAGE_SOURCE_REF Diagnostic exact full commit SHA; branches are rejected.

formal-gate skips .fkst/env and rejects framework/official source pin overrides.
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

absolute_executable_path() {
  local candidate="$1"
  local directory
  directory="$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "$directory" "$(basename "$candidate")"
}

read_tracked_framework_sha() {
  local pin_file="$ROOT/.fkst/substrate-ref"
  local pin
  if [ ! -f "$pin_file" ]; then
    echo "tracked framework pin is missing: $pin_file" >&2
    return 2
  fi
  pin="$(sed -n '1p' "$pin_file")"
  if [ "$(awk 'END { print NR }' "$pin_file")" -ne 1 ] || [[ ! "$pin" =~ ^[0-9a-f]{40}$ ]]; then
    echo "$pin_file must contain exactly one lowercase 40-character SHA" >&2
    return 2
  fi
  printf '%s\n' "$pin"
}

probe_framework_source_sha() {
  local binary="$1"
  local probe_parent="$ROOT/.fkst/run"
  local probe_root
  local probe_output
  local source_lines
  local source_sha

  require_runtime_path "$probe_parent"
  mkdir -p "$probe_parent"
  probe_root="$(mktemp -d "$probe_parent/framework-pin.XXXXXX")"
  require_runtime_path "$probe_root"

  if ! probe_output="$(
    {
      git -C "$probe_root" init -q
      cd "$probe_root"
      "$binary" init-package-repo
    } 2>&1
  )"; then
    rm -rf -- "$probe_root"
    echo "cannot determine fkst-framework source SHA: binary=$binary" >&2
    printf '%s\n' "$probe_output" >&2
    return 2
  fi
  rm -rf -- "$probe_root"

  source_lines="$(printf '%s\n' "$probe_output" | sed -n 's/^init-package-repo substrate_ref=//p')"
  source_sha="$(printf '%s\n' "$source_lines" | sed -n '1p')"
  if [ "$(printf '%s\n' "$source_lines" | awk 'NF { count += 1 } END { print count + 0 }')" -ne 1 ] \
    || [[ ! "$source_sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "cannot determine fkst-framework source SHA: binary=$binary emitted no unique full SHA" >&2
    return 2
  fi
  printf '%s\n' "$source_sha"
}

probe_framework_engine_version() {
  local binary="$1"
  local package_root="$ROOT/packages/github-auto-twitter-marketing"
  local handler="$package_root/departments/optional_pr_event_sink/main.lua"
  local event_json='{"queue":"github-proxy.github_pr_changed","payload":{"repo":"fkst/provenance-probe","number":0}}'
  local probe_output
  local provenance_count
  local engine_lines
  local engine_ver

  if [ ! -f "$handler" ]; then
    echo "framework provenance probe handler is missing: $handler" >&2
    return 2
  fi
  if ! probe_output="$(
    "$binary" run "$handler" \
      --project-root "$ROOT" \
      --package-root "$package_root" \
      --event "$event_json" 2>&1
  )"; then
    echo "cannot determine fkst-framework binary provenance: binary=$binary" >&2
    printf '%s\n' "$probe_output" >&2
    return 2
  fi

  provenance_count="$(printf '%s\n' "$probe_output" \
    | awk 'index($0, "EVENT=code_provenance") { count += 1 } END { print count + 0 }')"
  engine_lines="$(printf '%s\n' "$probe_output" \
    | awk 'index($0, "EVENT=code_provenance") {
        for (i = 1; i <= NF; i += 1) {
          if ($i ~ /^ENGINE_VER=/) {
            sub(/^ENGINE_VER=/, "", $i)
            print $i
          }
        }
      }')"
  engine_ver="$(printf '%s\n' "$engine_lines" | sed -n '1p')"
  if [ "$provenance_count" -ne 1 ] \
      || [ "$(printf '%s\n' "$engine_lines" | awk 'NF { count += 1 } END { print count + 0 }')" -ne 1 ] \
      || [[ ! "$engine_ver" =~ ^[0-9a-f]{12,40}(-dirty)?$ ]]; then
    echo "cannot determine fkst-framework binary provenance: binary=$binary emitted no unique valid ENGINE_VER" >&2
    return 2
  fi
  printf '%s\n' "$engine_ver"
}

verify_framework_binary_provenance() {
  local binary="$1"
  local source_sha="$2"
  local engine_ver

  engine_ver="$(probe_framework_engine_version "$binary")" || return $?
  if [[ "$engine_ver" == *-dirty ]]; then
    echo "framework binary was built from a dirty source checkout: source_sha=$source_sha engine_ver=$engine_ver binary=$binary" >&2
    return 2
  fi
  case "$source_sha" in
    "$engine_ver"*) ;;
    *)
      echo "framework binary provenance mismatch: source_sha=$source_sha engine_ver=$engine_ver binary=$binary" >&2
      return 2
      ;;
  esac
  printf 'engine_ver=%s binary_state=clean\n' "$engine_ver"
}

resolve_framework_source_root() {
  local binary="$1"
  local candidate
  local explicit=false
  local source_root

  if [ -n "${FKST_FRAMEWORK_SOURCE_ROOT:-}" ]; then
    candidate="$FKST_FRAMEWORK_SOURCE_ROOT"
    explicit=true
  else
    candidate="$(dirname "$binary")/../.."
  fi

  if [ ! -d "$candidate" ] \
      || ! source_root="$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null)"; then
    if [ "$explicit" = true ]; then
      echo "FKST_FRAMEWORK_SOURCE_ROOT is not a Git checkout: $candidate" >&2
      return 2
    fi
    return 0
  fi
  printf '%s\n' "$source_root"
}

verify_framework_source_checkout() {
  local source_root="$1"
  local actual_sha="$2"
  local checkout_sha
  local dirty

  if ! checkout_sha="$(git -C "$source_root" rev-parse HEAD 2>/dev/null)"; then
    echo "cannot read framework source checkout HEAD: $source_root" >&2
    return 2
  fi
  if [ "$checkout_sha" != "$actual_sha" ]; then
    echo "framework source checkout mismatch: binary_sha=$actual_sha checkout_sha=$checkout_sha source_root=$source_root" >&2
    return 2
  fi
  if ! dirty="$(git -C "$source_root" status --porcelain=v1 --untracked-files=all 2>/dev/null)"; then
    echo "cannot inspect framework source checkout: $source_root" >&2
    return 2
  fi
  if [ -n "$dirty" ]; then
    echo "framework source checkout is dirty: $source_root" >&2
    return 2
  fi
  printf 'source_checkout=%s checkout_state=clean\n' "$source_root"
}

verify_framework_source() {
  local binary="$1"
  local tracked_sha="$2"
  local expected_sha="$tracked_sha"
  local expectation_source="tracked"
  local actual_sha
  local binary_attestation
  local source_root
  local checkout_attestation

  if [ -n "${FKST_FRAMEWORK_EXPECTED_SHA:-}" ]; then
    expected_sha="$FKST_FRAMEWORK_EXPECTED_SHA"
    expectation_source="explicit-override"
  fi
  if [[ ! "$expected_sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "FKST_FRAMEWORK_EXPECTED_SHA must be a lowercase 40-character SHA" >&2
    return 2
  fi

  actual_sha="$(probe_framework_source_sha "$binary")" || return $?
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "fkst-framework source SHA mismatch: expected=$expected_sha actual=$actual_sha binary=$binary" >&2
    echo "build the tracked .fkst/substrate-ref, or explicitly set FKST_FRAMEWORK_EXPECTED_SHA to the alternate full SHA" >&2
    return 2
  fi

  binary_attestation="$(verify_framework_binary_provenance "$binary" "$actual_sha")" || return $?
  source_root="$(resolve_framework_source_root "$binary")" || return $?
  if [ -z "$source_root" ]; then
    echo "cannot attest framework source checkout for binary: $binary" >&2
    echo "use a standard Cargo target layout or set FKST_FRAMEWORK_SOURCE_ROOT" >&2
    return 2
  fi
  checkout_attestation="$(verify_framework_source_checkout "$source_root" "$actual_sha")" || return $?

  printf 'source_sha=%s source=%s tracked_sha=%s binary=%s %s %s\n' \
    "$actual_sha" "$expectation_source" "$tracked_sha" "$binary" \
    "$binary_attestation" "$checkout_attestation"
}

FRAMEWORK_BIN="$(resolve_bin)"
if [ -z "$FRAMEWORK_BIN" ] || [ ! -x "$FRAMEWORK_BIN" ]; then
  if [ "$FORMAL_GATE" = true ]; then
    echo "fkst-framework binary not found; formal-gate skips .fkst/env, set BIN in the process environment" >&2
  else
    echo "fkst-framework binary not found; set BIN in .fkst/env or environment" >&2
  fi
  exit 2
fi
FRAMEWORK_BIN="$(absolute_executable_path "$FRAMEWORK_BIN")"
TRACKED_FRAMEWORK_SHA="$(read_tracked_framework_sha)"
FRAMEWORK_VERIFICATION="$(verify_framework_source "$FRAMEWORK_BIN" "$TRACKED_FRAMEWORK_SHA")"

export FKST_RUNTIME_ROOT="${FKST_RUNTIME_ROOT:-$ROOT/.fkst/run/runtime}"
export FKST_DURABLE_ROOT="${FKST_DURABLE_ROOT:-$ROOT/.fkst/run/durable}"

OFFICIAL_FETCHED_SHA=""

read_locked_official_tree() {
  local lock_file="$ROOT/fkst.lock"
  local tree_lines
  local tree

  if [ ! -f "$lock_file" ]; then
    echo "tracked official lock is missing: $lock_file" >&2
    return 2
  fi
  tree_lines="$(sed -n 's/^tree_sha256 = "\(sha256-[0-9a-f]*\)"$/\1/p' "$lock_file")"
  tree="$(printf '%s\n' "$tree_lines" | sed -n '1p')"
  if [ "$(printf '%s\n' "$tree_lines" | awk 'NF { count += 1 } END { print count + 0 }')" -ne 1 ] \
      || [[ ! "$tree" =~ ^sha256-[0-9a-f]{64}$ ]]; then
    echo "$lock_file must contain exactly one valid official tree_sha256" >&2
    return 2
  fi
  printf '%s\n' "$tree"
}

ensure_official_package() {
  local fetched_sha
  local cache_head
  local export_root
  local file
  local path
  local -a required_paths=(
    packages/github-proxy
    libraries/contract
    libraries/forge
    libraries/workflow
    libraries/testkit
    libraries/devloop
    libraries/github-proxy-effects
  )
  local -a archive_paths=("${required_paths[@]}")

  require_runtime_path "$OFFICIAL_CACHE"
  require_runtime_path "$OFFICIAL_ROOT"

  mkdir -p "$ROOT/.fkst/cache" "$ROOT/.fkst/official"

  if [ ! -d "$OFFICIAL_CACHE/.git" ]; then
    rm -rf "$OFFICIAL_CACHE"
    git clone --no-checkout --filter=blob:none "$FKST_OFFICIAL_PACKAGE_SOURCE_URL" "$OFFICIAL_CACHE" >/dev/null
  fi

  git -C "$OFFICIAL_CACHE" remote set-url origin "$FKST_OFFICIAL_PACKAGE_SOURCE_URL"
  git -C "$OFFICIAL_CACHE" fetch --no-tags --depth 1 origin "$FKST_OFFICIAL_PACKAGE_SOURCE_REF" >/dev/null
  if ! fetched_sha="$(git -C "$OFFICIAL_CACHE" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null)"; then
    echo "official package source ref is not a usable commit: ref=$FKST_OFFICIAL_PACKAGE_SOURCE_REF" >&2
    return 2
  fi
  if [ "$fetched_sha" != "$FKST_OFFICIAL_PACKAGE_SOURCE_REF" ]; then
    echo "official package fetch mismatch: expected=$FKST_OFFICIAL_PACKAGE_SOURCE_REF fetched=$fetched_sha" >&2
    return 2
  fi
  OFFICIAL_FETCHED_SHA="$fetched_sha"

  git -C "$OFFICIAL_CACHE" checkout --detach --force "$fetched_sha" >/dev/null
  if ! cache_head="$(git -C "$OFFICIAL_CACHE" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)"; then
    echo "cannot read official package cache HEAD: $OFFICIAL_CACHE" >&2
    return 2
  fi
  if [ "$cache_head" != "$fetched_sha" ]; then
    echo "official package cache HEAD mismatch: fetched=$fetched_sha head=$cache_head" >&2
    return 2
  fi

  for path in "${required_paths[@]}"; do
    if ! git -C "$OFFICIAL_CACHE" cat-file -e "$cache_head:$path" 2>/dev/null; then
      echo "official package source is missing required tracked path: ref=$cache_head path=$path" >&2
      return 2
    fi
  done

  for file in fkst.workspace.toml fkst.lock; do
    if git -C "$OFFICIAL_CACHE" cat-file -e "$cache_head:$file" 2>/dev/null; then
      archive_paths+=("$file")
    fi
  done

  export_root="$(mktemp -d "$ROOT/.fkst/official/fkst-hosted.XXXXXX")"
  require_runtime_path "$export_root"
  if ! git -C "$OFFICIAL_CACHE" archive --format=tar "$cache_head" -- "${archive_paths[@]}" \
      | tar -xf - -C "$export_root"; then
    rm -rf -- "$export_root"
    echo "cannot export official package source: ref=$cache_head" >&2
    return 2
  fi

  rm -rf "$export_root/packages/github-proxy/tests"
  rm -rf "$export_root/packages/github-proxy/departments/test_entity_view_probe"
  rm -rf "$OFFICIAL_ROOT"
  mv "$export_root" "$OFFICIAL_ROOT"
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
  python3 "$ROOT/scripts/check_x_publishing_contract.py"
  python3 "$ROOT/scripts/check_x_publishing_contract_test.py"
  python3 "$ROOT/scripts/check_release_provenance_test.py"
  python3 "$ROOT/scripts/run_sh_test.py"
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
  "$FRAMEWORK_BIN" test --project-root "$ROOT" "${PACKAGE_ROOT_ARGS[@]}"
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

cmd_formal_gate() {
  local locked_tree

  printf 'formal_gate_stage=verify-framework\n'
  printf '%s\n' "$FRAMEWORK_VERIFICATION"
  python3 "$ROOT/scripts/check_release_provenance.py"
  ensure_official_package
  locked_tree="$(read_locked_official_tree)"
  printf '%s\n' \
    "formal_gate_provenance tracked_official_url=$DEFAULT_OFFICIAL_SOURCE_URL effective_official_url=$FKST_OFFICIAL_PACKAGE_SOURCE_URL tracked_official_ref=$DEFAULT_OFFICIAL_SOURCE_REF effective_official_ref=$FKST_OFFICIAL_PACKAGE_SOURCE_REF fetched_official_sha=$OFFICIAL_FETCHED_SHA locked_official_tree=$locked_tree"

  printf 'formal_gate_stage=check\n'
  cmd_check
  printf 'formal_gate_stage=test\n'
  cmd_test
  printf 'formal_gate_stage=test-composed\n'
  cmd_test_composed
  python3 "$ROOT/scripts/check_release_provenance.py"
  printf 'formal_gate_status=passed\n'
}

case "${1:-}" in
  formal-gate)
    shift
    if [ "$#" -ne 0 ]; then
      usage >&2
      exit 2
    fi
    cmd_formal_gate
    ;;
  verify-framework)
    printf '%s\n' "$FRAMEWORK_VERIFICATION"
    ;;
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
