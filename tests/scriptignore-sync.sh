# scriptignore: skip
# scriptignore-reason: ferramenta de manutenção; roda como script, não precisa viver no shell
# Version Details: v0.1
# scriptignore-sync.sh — keeps the AUTO-GENERATED section of .scriptignore
#                       in sync with '# scriptignore: skip' directives at
#                       the top of every .sh file under the loader root.
#
# Usage:
#   scriptignore-sync.sh                 # dry-run: show what would change
#   scriptignore-sync.sh --write         # apply changes
#   scriptignore-sync.sh --check         # exit 1 if out of sync (for CI/hooks)
#   scriptignore-sync.sh --verbose       # extra diagnostics on stderr
#   scriptignore-sync.sh --root <path>   # override loader root detection
#   -h, --help
#
# How it works:
#   1. Loader root is detected as the parent of this script's directory by
#      default (script lives in <root>/shellutilities/, so root is ../).
#      Override with --root or $SCRIPTIGNORE_ROOT.
#   2. The .scriptignore at the loader root is read and split into:
#        - MANUAL section  (everything before the AUTO-GENERATED marker)
#        - AUTO-GENERATED  (everything from the marker onwards)
#   3. Every .sh under the loader root (excluding .git, .dev-logs,
#      node_modules) is scanned for the directive:
#        # scriptignore: skip   (or : keep)
#      A file with 'skip' is added to the generated section.
#      A file with 'keep' (or no directive) is not.
#   4. Directories where every .sh is 'skip' are collapsed into a single
#      '/<repo>/<dir>/' entry instead of listing each file.
#   5. The generated section is rebuilt as one sub-block per top-level repo
#      under the loader root:
#        # ─── <repo> ───
#        /<repo>/...
#      Blocks for repos that no longer contain .sh files are dropped.
#      Blocks for repos not touched by this run are preserved as-is.
#
# Design notes:
#   - Additive per repo: a run that scans <root>/ArchivePar2/ only rewrites
#     the "─── ArchivePar2 ───" block, leaving other blocks untouched.
#   - Paths are anchored with a leading '/' so load_all.sh treats them as
#     "match from loader root" (not as global substring patterns).
#   - Zero external dependencies beyond bash + coreutils.

sync_scriptignore () {
  local mode="dry-run"          # dry-run | write | check
  local verbose=0
  local loader_root=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --write)   mode="write"; shift ;;
      --check)   mode="check"; shift ;;
      --dry-run) mode="dry-run"; shift ;;
      --verbose) verbose=1; shift ;;
      --root)    loader_root="$2"; shift 2 ;;
      -h|--help)
        sed -n '4,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        return 0
        ;;
      *)
        echo "ERROR: unknown argument: $1" >&2
        return 2
        ;;
    esac
  done

  local self_path self_dir
  self_path=$(readlink -f "${BASH_SOURCE[0]}")
  self_dir=$(dirname "$self_path")

  if [[ -z "$loader_root" ]]; then
    if [[ -n "${SCRIPTIGNORE_ROOT:-}" ]]; then
      loader_root=$(readlink -f "$SCRIPTIGNORE_ROOT")
    else
      # Default: script lives in <root>/shellutilities/, so root is parent
      loader_root=$(cd "$self_dir/.." && pwd)
    fi
  else
    loader_root=$(readlink -f "$loader_root")
  fi

  if [[ ! -d "$loader_root" ]]; then
    echo "ERROR: loader root not found: $loader_root" >&2
    return 2
  fi

  local ignore_file="$loader_root/.scriptignore"

  if [[ ! -f "$ignore_file" ]]; then
    echo "ERROR: .scriptignore not found at $ignore_file" >&2
    echo "       (Create one first, or pass --root <path>)" >&2
    return 2
  fi

  (( verbose )) && echo "[verbose] loader root : $loader_root" >&2
  (( verbose )) && echo "[verbose] ignore file : $ignore_file" >&2

  # ─────────────────────────────────────────────────────────────
  # 1. Scan every .sh under loader root, collect skip paths per repo
  # ─────────────────────────────────────────────────────────────
  declare -A repo_skip=()      # repo_name -> "path1\npath2\n..."
  declare -A repo_keep=()      # repo_name -> "path1\npath2\n..."
  declare -A repo_exists=()    # repo_name -> 1 (seen)

  local f rel repo top_rel directive

  while IFS= read -r -d '' f; do
    case "$f" in
      */.git/*|*/.dev-logs/*|*/node_modules/*) continue ;;
    esac
    [[ "$f" == *.sh ]] || continue

    # Skip files outside loader root (defensive; find shouldn't produce them)
    case "$f" in
      "$loader_root"/*) ;;
      *) continue ;;
    esac

    rel="${f#$loader_root/}"
    repo="${rel%%/*}"
    top_rel="$rel"

    # If the file is directly at the loader root (no subdir), skip it.
    # (These are typically load_all.sh and similar — not tracked.)
    if [[ "$rel" == */* ]]; then
      repo_exists["$repo"]=1
    else
      continue
    fi

    directive=$(
      head -30 "$f" 2>/dev/null | awk '
        /^# scriptignore:[[:space:]]*(skip|keep)/ {
          sub(/^# scriptignore:[[:space:]]*/, "")
          print
          exit
        }
      '
    )
    [[ -z "$directive" ]] && continue

    if [[ "$directive" == "skip" ]]; then
      repo_skip["$repo"]+="$top_rel"$'\n'
    elif [[ "$directive" == "keep" ]]; then
      repo_keep["$repo"]+="$top_rel"$'\n'
    fi
  done < <(find "$loader_root" -type f -name "*.sh" -print0)

  # ─────────────────────────────────────────────────────────────
  # 2. For each repo, collapse directories where ALL .sh are skip
  # ─────────────────────────────────────────────────────────────
  generate_repo_block () {
    local r="$1"
    local skip_list="${repo_skip[$r]:-}"
    local keep_list="${repo_keep[$r]:-}"

    [[ -z "$skip_list" ]] && return 0

    # Map: directory -> number of skip files
    declare -A dir_skip_count=()
    # Map: directory -> 1 if any keep file lives under it
    declare -A dir_has_keep=()

    local line d
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      d=$(dirname "$line")
      dir_skip_count["$d"]=$(( ${dir_skip_count["$d"]:-0} + 1 ))
    done <<< "$skip_list"

    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      d=$(dirname "$line")
      dir_has_keep["$d"]=1
      # Also mark all ancestor dirs as having keep
      local ad="$d"
      while [[ "$ad" == */* ]]; do
        ad=$(dirname "$ad")
        dir_has_keep["$ad"]=1
      done
    done <<< "$keep_list"

    # A directory is "all skip" if no keep under it AND all .sh in it are skip.
    # (We can only verify the latter by re-walking; but since we scanned all
    # .sh and only recorded those WITH directives, an undeclared .sh would be
    # missing from both maps. To be safe, we also verify by walking the dir.)
    declare -A dir_all_skip=()
    local candidate
    for candidate in "${!dir_skip_count[@]}"; do
      [[ -n "${dir_has_keep[$candidate]:-}" ]] && continue
      # Verify: every .sh under candidate is in skip_list
      local undeclared=0
      while IFS= read -r -d '' f; do
        case "$f" in
          */.git/*|*/.dev-logs/*|*/node_modules/*) continue ;;
        esac
        rel="${f#$loader_root/}"
        if [[ "$skip_list" != *"$rel"$'\n'* ]]; then
          undeclared=1
          break
        fi
      done < <(find "$loader_root/$candidate" -type f -name "*.sh" -print0 2>/dev/null)
      (( undeclared )) && continue
      dir_all_skip["$candidate"]=1
    done

    # Emit: top-level dirs that are entirely skip + individual skip files
    #       not covered by such a dir.
    local -a emitted=()
    local covered
    for candidate in "${!dir_all_skip[@]}"; do
      emitted+=( "/$candidate/" )
    done

    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      covered=0
      for d in "${!dir_all_skip[@]}"; do
        if [[ "$line" == "$d/"* ]]; then
          covered=1
          break
        fi
      done
      (( covered )) || emitted+=( "/$line" )
    done <<< "$skip_list"

    # Sort and unique
    local -a sorted
    mapfile -t sorted < <(printf '%s\n' "${emitted[@]}" | sort -u)

    printf '# ─── %s ───\n' "$r"
    local e
    for e in "${sorted[@]}"; do
      [[ -n "$e" ]] && printf '%s\n' "$e"
    done
  }

  # ─────────────────────────────────────────────────────────────
  # 3. Build the new AUTO-GENERATED section
  # ─────────────────────────────────────────────────────────────
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')

  local -a repos
  mapfile -t repos < <(printf '%s\n' "${!repo_exists[@]}" | sort)

  local new_section
  new_section=$(
    printf '# ════════════════════════════════════════════════════════════════\n'
    printf '# AUTO-GENERATED SECTION — NÃO EDITE À MÃO\n'
    printf '# Regenerate with: shellutilities/scriptignore-sync.sh --write\n'
    printf '# ════════════════════════════════════════════════════════════════\n'
    printf '# Generated: %s\n' "$ts"
    printf "# Source of truth: '# scriptignore: skip' directive at top of each .sh\n"
    printf '\n'
    local r any=0
    for r in "${repos[@]}"; do
      [[ -z "${repo_skip[$r]:-}" ]] && continue
      any=1
      generate_repo_block "$r"
      printf '\n'
    done
    (( any )) || printf '# (no .sh files with directives found)\n'
  )

  # ─────────────────────────────────────────────────────────────
  # 4. Read current .scriptignore and split into manual / generated
  # ─────────────────────────────────────────────────────────────
  local marker='# ════════════════════════════════════════════════════════════════'
  local current_content
  current_content=$(< "$ignore_file")

  # Find the line number of the FIRST occurrence of the marker
  local marker_line
  marker_line=$(printf '%s\n' "$current_content" | grep -n -m1 -F "$marker" | cut -d: -f1)

  local manual_part=""
  if [[ -n "$marker_line" ]] && (( marker_line > 1 )); then
    manual_part=$(printf '%s\n' "$current_content" | head -n $(( marker_line - 1 )))
  elif [[ -n "$marker_line" ]] && (( marker_line == 1 )); then
    manual_part=""
  else
    # No marker present: entire file is manual, we append the section
    manual_part="$current_content"
  fi

  # Ensure manual part ends with a blank line before the marker
  while [[ "$manual_part" == *$'\n\n' ]]; do
    manual_part="${manual_part%$'\n'}"
  done
  [[ -n "$manual_part" ]] && manual_part+=$'\n'

  local final_content="$manual_part$new_section"

  # ─────────────────────────────────────────────────────────────
  # 5. Act on the selected mode
  # ─────────────────────────────────────────────────────────────
  local current_hash new_hash
  current_hash=$(printf '%s' "$current_content" | md5sum | cut -d' ' -f1)
  new_hash=$(printf '%s' "$final_content"   | md5sum | cut -d' ' -f1)

  if [[ "$current_hash" == "$new_hash" ]]; then
    (( verbose )) && echo "[verbose] .scriptignore is already in sync." >&2
    case "$mode" in
      check) return 0 ;;
      *) echo "OK: .scriptignore is already in sync." ;;
    esac
    return 0
  fi

  case "$mode" in
    dry-run)
      echo "DRY-RUN: .scriptignore would change."
      echo "--------------------------------------------------"
      diff -u "$ignore_file" <(printf '%s' "$final_content") || true
      echo "--------------------------------------------------"
      echo "Run with --write to apply."
      return 0
      ;;
    check)
      echo "OUT OF SYNC: .scriptignore needs regeneration." >&2
      return 1
      ;;
    write)
      local tmp
      tmp=$(mktemp "${ignore_file}.XXXXXX") || {
        echo "ERROR: cannot create temp file next to $ignore_file" >&2
        return 2
      }
      printf '%s' "$final_content" > "$tmp" || {
        rm -f "$tmp"
        echo "ERROR: failed to write temp file" >&2
        return 2
      }
      if ! mv "$tmp" "$ignore_file"; then
        rm -f "$tmp"
        echo "ERROR: failed to install new .scriptignore" >&2
        return 2
      fi
      echo "WROTE: $ignore_file"
      return 0
      ;;
  esac

  echo "ERROR: unknown mode: $mode" >&2
  return 2
}

# Direct execution wrapper
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  sync_scriptignore "$@"
  exit $?
fi