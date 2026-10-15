# scriptignore: skip
# scriptignore-reason: runner de testes; invocado sob demanda, não deve poluir o shell de login
# Version Details: v0.0.1
# Runner for archivepar2 test suites.
#
# Can be used two ways:
#   1) Execute directly:   ./tests/run-tests.sh [options]
#   2) Source from bashrc: source tests/run-tests.sh
#                          run_tests [options]
#
# Options:
#   --target <path>       Path to archivepar2.sh (default: <repo>/archivepar2.sh)
#   --suite <NN|name>     Run only suites matching prefix (e.g. 02) or substring
#   --test <substring>    Run only tests whose function name matches
#   --list                List suites and tests, then exit
#   --no-version-filter   Run all suites regardless of SUITE_APPLIES_TO
#   --logdir <path>       Override log directory (default: <repo>/.dev-logs)
#   -h, --help            Show this help
#
# Exit codes:
#   0  all tests passed (skips allowed)
#   1  one or more tests failed
#   2  setup error (missing target, missing bins, etc.)

run_tests () {
  local _rt_target="" _rt_suite="" _rt_test="" _rt_list=0
  local _rt_no_filter=0 _rt_logdir=""
  local _rt_self_dir _rt_repo_root

  _rt_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  _rt_repo_root=$(cd "$_rt_self_dir/.." && pwd)

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)      _rt_target="$2"; shift 2 ;;
      --suite)       _rt_suite="$2";  shift 2 ;;
      --test)        _rt_test="$2";   shift 2 ;;
      --list)        _rt_list=1;      shift ;;
      --no-version-filter) _rt_no_filter=1; shift ;;
      --logdir)      _rt_logdir="$2"; shift 2 ;;
      -h|--help)
        sed -n '4,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        return 0
        ;;
      *)
        echo "ERROR: unknown argument: $1" >&2
        echo "Try: run_tests --help" >&2
        return 2
        ;;
    esac
  done

  [[ -z "$_rt_target" ]] && _rt_target="$_rt_repo_root/archivepar2.sh"
  _rt_target=$(readlink -f "$_rt_target" 2>/dev/null || echo "$_rt_target")

  if [[ ! -f "$_rt_target" ]]; then
    echo "ERROR: target script not found: $_rt_target" >&2
    return 2
  fi

  local _rt_target_version
  _rt_target_version=$(
    awk '/^# Version Details:/ { sub(/^# Version Details:[[:space:]]*/, ""); print; exit }' \
      "$_rt_target"
  )
  if [[ -z "$_rt_target_version" ]]; then
    echo "ERROR: could not extract version from $_rt_target" >&2
    return 2
  fi

  [[ -z "$_rt_logdir" ]] && _rt_logdir="$_rt_repo_root/.dev-logs"
  local _rt_runid _rt_rundir
  _rt_runid="$(date '+%Y-%m-%d_%H-%M-%S')_$$"
  _rt_rundir="$_rt_logdir/$_rt_runid"
  mkdir -p "$_rt_rundir" || {
    echo "ERROR: cannot create log dir: $_rt_rundir" >&2
    return 2
  }

  local -a _rt_suites=()
  local _rt_s
  for _rt_s in "$_rt_self_dir"/suites/[0-9][0-9]_*.sh; do
    [[ -f "$_rt_s" ]] || continue
    _rt_suites+=( "$_rt_s" )
  done

  if (( ${#_rt_suites[@]} == 0 )); then
    echo "ERROR: no suites found in $_rt_self_dir/suites/" >&2
    return 2
  fi

  printf '════════════════════════════════════════════════════════════════\n'
  printf '  archivepar2 test runner  v0.0.1\n'
  printf '  Target  : %s  (%s)\n' "$(basename "$_rt_target")" "$_rt_target_version"
  printf '  Filter  : suite=%s  test=%s\n' "${_rt_suite:-ALL}" "${_rt_test:-ALL}"
  printf '  Log dir : %s\n' "$_rt_rundir"
  printf '════════════════════════════════════════════════════════════════\n\n'

  local _rt_n_pass=0 _rt_n_fail=0 _rt_n_skip=0 _rt_n_error=0
  local -a _rt_failed_tests=()
  local -a _rt_skipped_tests=()
  local _rt_start_ts _rt_end_ts
  _rt_start_ts=$(date +%s)

  local _rt_suite_file
  for _rt_suite_file in "${_rt_suites[@]}"; do
    local _rt_suite_base
    _rt_suite_base=$(basename "$_rt_suite_file" .sh)

    if [[ -n "$_rt_suite" ]]; then
      if [[ "$_rt_suite_base" != "$_rt_suite"* ]] && \
         [[ "$_rt_suite_base" != *"$_rt_suite"* ]]; then
        continue
      fi
    fi

    # Load suite metadata in a throwaway subshell
    local _rt_meta
    _rt_meta=$(
      set +e
      (
        # shellcheck disable=SC1090
        source "$_rt_suite_file" >/dev/null 2>&1 || exit 99
        printf 'NAME=%s\n' "${SUITE_NAME:-}"
        printf 'APPLIES_TO=%s\n' "${SUITE_APPLIES_TO:-*}"
        printf 'NEEDS=%s\n' "${SUITE_NEEDS_BINS:-}"
        printf 'FUNCS=%s\n' "$(declare -F | awk '/^declare -f t[0-9]/{print $3}' | tr '\n' ' ')"
      )
    )
    if [[ -z "$_rt_meta" ]]; then
      printf '▶ %s  [ERROR: failed to load suite]\n' "$_rt_suite_base"
      (( _rt_n_error++ ))
      continue
    fi

    local _rt_s_name _rt_s_applies _rt_s_needs _rt_s_funcs
    _rt_s_name=$(   printf '%s\n' "$_rt_meta" | sed -n 's/^NAME=//p')
    _rt_s_applies=$(printf '%s\n' "$_rt_meta" | sed -n 's/^APPLIES_TO=//p')
    _rt_s_needs=$(  printf '%s\n' "$_rt_meta" | sed -n 's/^NEEDS=//p')
    _rt_s_funcs=$(  printf '%s\n' "$_rt_meta" | sed -n 's/^FUNCS=//p')

    printf '▶ %s: %s\n' "$_rt_suite_base" "${_rt_s_name:-?}"

    # Version filter
    if (( ! _rt_no_filter )) && [[ "$_rt_s_applies" != "*" ]]; then
      (
        set +e
        # shellcheck disable=SC1090
        source "$_rt_self_dir/lib.sh" >/dev/null 2>&1
        _t_version_satisfies "$_rt_target_version" "$_rt_s_applies"
      )
      if (( $? != 0 )); then
        printf '  ⊘ ENTIRE SUITE SKIPPED  [requires %s, target is %s]\n' \
          "$_rt_s_applies" "$_rt_target_version"
        (( _rt_n_skip++ ))
        _rt_skipped_tests+=( "$_rt_suite_base (whole suite)" )
        printf '\n'
        continue
      fi
    fi

    if (( _rt_list )); then
      local _rt_f
      for _rt_f in $_rt_s_funcs; do
        printf '    - %s\n' "$_rt_f"
      done
      printf '\n'
      continue
    fi

    local _rt_suite_logdir="$_rt_rundir/$_rt_suite_base"
    mkdir -p "$_rt_suite_logdir"

    # Required-bins check: skip whole suite if a required bin is missing
    if [[ -n "$_rt_s_needs" ]]; then
      local _rt_missing
      _rt_missing=$(
        set +e
        (
          # shellcheck disable=SC1090
          source "$_rt_self_dir/lib.sh" >/dev/null 2>&1
          _t_require_bins "$_rt_s_needs" || printf '%s' "$_T_MISSING_BINS"
        )
      )
      if [[ -n "$_rt_missing" ]]; then
        printf '  ⊘ ENTIRE SUITE SKIPPED  [missing binaries: %s]\n' "${_rt_missing% }"
        (( _rt_n_skip++ ))
        _rt_skipped_tests+=( "$_rt_suite_base (missing bins: ${_rt_missing% })" )
        rmdir "$_rt_suite_logdir" 2>/dev/null || true
        printf '\n'
        continue
      fi
    fi

    local _rt_func
    for _rt_func in $_rt_s_funcs; do
      if [[ -n "$_rt_test" ]] && [[ "$_rt_func" != *"$_rt_test"* ]]; then
        continue
      fi

      local _rt_test_log="$_rt_suite_logdir/$_rt_func.log"
      local _rt_test_tmp
      _rt_test_tmp=$(mktemp -d "/tmp/a2test_${_rt_func}_XXXXXX")
      local _rt_skip_file="$_rt_test_tmp/.skip"

      local _rt_rc=0
      (
        set +e
        # shellcheck disable=SC1090
        source "$_rt_self_dir/lib.sh"
        # shellcheck disable=SC1090
        source "$_rt_suite_file"

        _T_CURRENT_SUITE="$_rt_suite_base"
        _T_CURRENT_TEST="$_rt_func"
        _T_CURRENT_LOG="$_rt_test_log"
        _T_TEST_TMPDIR="$_rt_test_tmp"
        _T_SKIP_FILE="$_rt_skip_file"

        _t_log "=== $_rt_suite_base / $_rt_func ==="
        _t_log "TMPDIR: $_rt_test_tmp"

        cd "$_rt_test_tmp" || exit 99

        "$_rt_func"
        exit $?
      ) > "$_rt_test_log.console" 2>&1
      _rt_rc=$?

      local _rt_skip_reason=""
      if [[ "$_rt_rc" == "77" ]]; then
        [[ -f "$_rt_skip_file" ]] && _rt_skip_reason=$(< "$_rt_skip_file")
        printf '  ⊘ %s  [SKIP: %s]\n' "$_rt_func" "${_rt_skip_reason:-no reason given}"
        (( _rt_n_skip++ ))
        _rt_skipped_tests+=( "$_rt_func" )
      elif [[ "$_rt_rc" == "0" ]]; then
        printf '  ✓ %s\n' "$_rt_func"
        (( _rt_n_pass++ ))
      else
        printf '  ✗ %s  [rc=%s]\n' "$_rt_func" "$_rt_rc"
        if [[ -f "$_rt_test_log.console" ]]; then
          grep -E '^ASSERT FAIL' "$_rt_test_log.console" | tail -1 | sed 's/^/      /'
        fi
        (( _rt_n_fail++ ))
        _rt_failed_tests+=( "$_rt_suite_base/$_rt_func" )
      fi

      rm -rf "$_rt_test_tmp"
    done
    printf '\n'
  done

  _rt_end_ts=$(date +%s)
  local _rt_dur=$(( _rt_end_ts - _rt_start_ts ))

  printf '════════════════════════════════════════════════════════════════\n'
  printf '  TOTAL: %d   PASS: %d   FAIL: %d   SKIP: %d   ERROR: %d\n' \
    "$(( _rt_n_pass + _rt_n_fail + _rt_n_skip ))" \
    "$_rt_n_pass" "$_rt_n_fail" "$_rt_n_skip" "$_rt_n_error"
  printf '  Duration: %ds\n' "$_rt_dur"
  printf '  Logs    : %s\n' "$_rt_rundir"

  if (( ${#_rt_failed_tests[@]} > 0 )); then
    printf '\n  Failed tests:\n'
    local _rt_ft
    for _rt_ft in "${_rt_failed_tests[@]}"; do
      printf '    - %s\n' "$_rt_ft"
    done
  fi
  if (( ${#_rt_skipped_tests[@]} > 0 )); then
    printf '\n  Skipped:\n'
    local _rt_st
    for _rt_st in "${_rt_skipped_tests[@]}"; do
      printf '    - %s\n' "$_rt_st"
    done
  fi

  local _rt_final_rc=0
  if (( _rt_n_fail > 0 || _rt_n_error > 0 )); then
    _rt_final_rc=1
  fi

  printf '  Exit    : %d\n' "$_rt_final_rc"
  printf '════════════════════════════════════════════════════════════════\n'

  return $_rt_final_rc
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  run_tests "$@"
  exit $?
fi