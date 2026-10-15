# scriptignore: skip
# scriptignore-reason: helper de teste; só faz sentido dentro dos subshells do runner
# Version Details: v0.0.1
# Shared helpers for archivepar2 test suites.
#
# Design notes:
#   - All public helpers are prefixed with _t_ to avoid collisions with
#     user environment (e.g. a bashrc that sources many function files).
#   - This file is meant to be sourced INSIDE a subshell by the runner.
#     It does not execute anything on its own.
#   - No external dependencies beyond Bash + coreutils.

# ─────────────────────────────────────────────────────────────────
# Test result codes (used by suites as return values)
# ─────────────────────────────────────────────────────────────────
readonly _T_PASS=0
readonly _T_FAIL=1
readonly _T_SKIP=77

# ─────────────────────────────────────────────────────────────────
# Per-test state (set by runner before calling each test function)
# ─────────────────────────────────────────────────────────────────
_T_CURRENT_TEST=""
_T_CURRENT_SUITE=""
_T_CURRENT_LOG=""
_T_TEST_TMPDIR=""
_T_SKIP_FILE=""

# ─────────────────────────────────────────────────────────────────
# Logging (writes to the per-test log file; runner handles console)
# ─────────────────────────────────────────────────────────────────
_t_log() {
  [[ -n "$_T_CURRENT_LOG" ]] && printf '%s\n' "$*" >> "$_T_CURRENT_LOG"
  return 0
}

# _t_log_cmd <cmd...>  — logs $ command, its output, and exit code
_t_log_cmd() {
  _t_log "\$ $*"
  local out rc
  out=$("$@" 2>&1)
  rc=$?
  [[ -n "$out" ]] && _t_log "$out"
  _t_log "[exit=$rc]"
  return $rc
}

# ─────────────────────────────────────────────────────────────────
# Assertions — each logs failure reason and returns non-zero on fail
# ─────────────────────────────────────────────────────────────────

_t_fail() {
  local msg="$1"
  _t_log "ASSERT FAIL: $msg"
  printf 'ASSERT FAIL: %s\n' "$msg" >&2
  return $_T_FAIL
}

_t_assert_eq() {
  local got="$1" want="$2" msg="${3:-values differ}"
  if [[ "$got" != "$want" ]]; then
    _t_fail "$msg (got='$got' want='$want')"
    return $_T_FAIL
  fi
  return $_T_PASS
}

_t_assert_ne() {
  local got="$1" want="$2" msg="${3:-values should differ}"
  if [[ "$got" == "$want" ]]; then
    _t_fail "$msg (both='$got')"
    return $_T_FAIL
  fi
  return $_T_PASS
}

_t_assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-substring not found}"
  if [[ "$haystack" != *"$needle"* ]]; then
    _t_fail "$msg (needle='$needle' not in haystack)"
    _t_log "haystack was:"
    _t_log "$haystack"
    return $_T_FAIL
  fi
  return $_T_PASS
}

_t_assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-substring unexpectedly found}"
  if [[ "$haystack" == *"$needle"* ]]; then
    _t_fail "$msg (needle='$needle' found in haystack)"
    return $_T_FAIL
  fi
  return $_T_PASS
}

_t_assert_file_exists() {
  local path="$1" msg="${2:-file does not exist}"
  if [[ ! -e "$path" ]]; then
    _t_fail "$msg (path='$path')"
    return $_T_FAIL
  fi
  return $_T_PASS
}

_t_assert_file_absent() {
  local path="$1" msg="${2:-file should not exist}"
  if [[ -e "$path" ]]; then
    _t_fail "$msg (path='$path')"
    return $_T_FAIL
  fi
  return $_T_PASS
}

_t_assert_dir_exists() {
  local path="$1" msg="${2:-directory does not exist}"
  if [[ ! -d "$path" ]]; then
    _t_fail "$msg (path='$path')"
    return $_T_FAIL
  fi
  return $_T_PASS
}

_t_assert_rc() {
  local rc="$1" want="$2" msg="${3:-wrong return code}"
  if [[ "$rc" != "$want" ]]; then
    _t_fail "$msg (got rc=$rc want rc=$want)"
    return $_T_FAIL
  fi
  return $_T_PASS
}

# ─────────────────────────────────────────────────────────────────
# Skip helper
# ─────────────────────────────────────────────────────────────────
_t_skip() {
  local reason="$1"
  [[ -n "$_T_SKIP_FILE" ]] && printf '%s\n' "$reason" > "$_T_SKIP_FILE"
  return $_T_SKIP
}

# ─────────────────────────────────────────────────────────────────
# Fixture helpers
# ─────────────────────────────────────────────────────────────────

# _t_mkfix <name>  -> creates $_T_TEST_TMPDIR/<name>/ and echoes the path
_t_mkfix() {
  local name="$1"
  local dir="$_T_TEST_TMPDIR/$name"
  mkdir -p "$dir" || return 1
  printf '%s\n' "$dir"
}

# _t_mkfile <path> <content>
_t_mkfile() {
  local path="$1" content="$2"
  mkdir -p "$(dirname "$path")" || return 1
  printf '%s' "$content" > "$path"
}

# _t_random_file <path> <size_bytes>
_t_random_file() {
  local path="$1" size="$2"
  mkdir -p "$(dirname "$path")" || return 1
  head -c "$size" /dev/urandom > "$path"
}

# ─────────────────────────────────────────────────────────────────
# Version comparison
#
# Compares version strings:  X.Y[-rcZ][.A.B]
# Returns 0 if $1 satisfies the operator applied to $3.
# ─────────────────────────────────────────────────────────────────

# Normalizes to 6 integers: MAJOR MINOR RCMARK RCMAJ RCMIN PATCH
# RCMARK: 1 for stable release, 0 for -rcN
_t_version_normalize() {
  local v="$1"
  v="${v#v}"

  local major="" minor="" rcmark="" rcmaj="" rcmin="" patch=""

  major="${v%%.*}"
  local rest="${v#*.}"
  minor="${rest%%[.-]*}"
  rest="${rest#"$minor"}"
  rest="${rest#.}"
  rest="${rest#-}"

  if [[ "$rest" =~ ^rc([0-9]+)$ ]]; then
    rcmark=0
    rcmaj="${BASH_REMATCH[1]}"
    rcmin=0
    patch=0
  elif [[ "$rest" =~ ^rc([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    rcmark=0
    rcmaj="${BASH_REMATCH[1]}"
    rcmin="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
  elif [[ -z "$rest" ]]; then
    rcmark=1
    rcmaj=0
    rcmin=0
    patch=0
  else
    return 1
  fi

  printf '%s %s %s %s %s %s\n' \
    "${major:-0}" "${minor:-0}" "$rcmark" "${rcmaj:-0}" "${rcmin:-0}" "${patch:-0}"
}

_t_version_cmp() {
  local a="$1" op="$2" b="$3"
  local na nb
  na=$(_t_version_normalize "$a") || return 2
  nb=$(_t_version_normalize "$b") || return 2

  local -a ta tb
  read -r -a ta <<< "$na"
  read -r -a tb <<< "$nb"

  local i
  for (( i=0; i<6; i++ )); do
    if (( ta[i] < tb[i] )); then
      case "$op" in
        "<"|"<=") return 0 ;;
        "="|">="|">") return 1 ;;
      esac
    elif (( ta[i] > tb[i] )); then
      case "$op" in
        ">"|">=") return 0 ;;
        "="|"<="|"<") return 1 ;;
      esac
    fi
  done
  case "$op" in
    "="|"<="|">=") return 0 ;;
    "<"|">")       return 1 ;;
  esac
  return 2
}

# _t_version_satisfies <version> <constraint>
# Constraint forms: "*", "=X", ">=X", "<=X", ">X", "<X"
_t_version_satisfies() {
  local v="$1" c="$2"
  [[ "$c" == "*" ]] && return 0
  local op="${c%%[0-9]*}"
  local target="${c#"$op"}"
  [[ -z "$op" ]] && op="="
  _t_version_cmp "$v" "$op" "$target"
}

# ─────────────────────────────────────────────────────────────────
# Misc helpers
# ─────────────────────────────────────────────────────────────────

# _t_extract_version_from_script <file>  -> echoes "vX.Y..." or fails
_t_extract_version_from_script() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  local v
  v=$(awk '
    /^# Version Details:/ { sub(/^# Version Details:[[:space:]]*/, ""); print; exit }
  ' "$file")
  [[ -n "$v" ]] || return 1
  printf '%s\n' "$v"
}

# _t_bin_available <name>
_t_bin_available() {
  command -v "$1" >/dev/null 2>&1
}

# _t_require_bins <space-separated list>
# Returns 0 if all available; on failure sets _T_MISSING_BINS.
_t_require_bins() {
  local bins="$1" b
  _T_MISSING_BINS=""
  for b in $bins; do
    if ! _t_bin_available "$b"; then
      _T_MISSING_BINS+="$b "
    fi
  done
  [[ -z "$_T_MISSING_BINS" ]]
}