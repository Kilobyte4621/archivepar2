# Version Details: v0.17-rc1.0.2
# Change (from v0.17-rc1.0.1):
# Reuse of _a2_init_fail: In argument errors and --keep, we exchange repeated pipefail restore lines for a clean call to _a2_init_fail.
# Compression of the allocation: The temporary files are now created sequentially and cleanly, grouping the cleaning of previous files directly on the keys ||.

archivepar2 () {
  if [[ $# -eq 0 ]]; then
    echo "Error: no input folder provided" >&2
    return 1
  fi

  local oldpwd="$PWD"
  local arch="$1"; shift

  local maxsize="2G" single_mode=0 fast_mode=0 out base dir parent_dir manifest logfile
  local -a parts

  local t_start t_end t_total
  local t_compress_dur="0s" t_check_dur="0s" t_par2_dur="0s"
  local compress_status="SKIPPED" check_status="SKIPPED" par2_status="PENDING"
  local zstd_golden_line=""

  local keep_versions=3
  local keep_set=0
  local no_migrate=0
  local par2_done=0

  local _a2_orig_pipefail=0
  [[ -o pipefail ]] && _a2_orig_pipefail=1
  set -o pipefail

  t_start=$(date +%s)

  _a2_init_fail() {
    (( _a2_orig_pipefail )) || set +o pipefail
    cd "$oldpwd" >/dev/null 2>&1
    return 1
  }

  while [[ $# -gt 0 ]]; do
    local current_arg="${1^^}"
    case "$current_arg" in
      --SINGLE) single_mode=1 ;;
      --FAST)    fast_mode=1 ;;
      --NO-MIGRATE) no_migrate=1 ;;
      --KEEP)
        shift
        if [[ -z "${1:-}" ]] || ! [[ "$1" =~ ^[0-9]+$ ]]; then
          echo "ERROR: --keep requires a non-negative integer" >&2
          _a2_init_fail
          return 1
        fi
        keep_versions="$1"
        keep_set=1
        ;;
      *)
        if [[ "$current_arg" =~ ^[1-9]+[0-9]*[KMGTP]$ ]]; then
          maxsize="$current_arg"
        else
          echo "ERROR: invalid argument: $1" >&2
          _a2_init_fail
          return 1
        fi
        ;;
    esac
    shift
  done

  if (( ! keep_set )) && [[ -n "${ARCHIVEPAR2_KEEP:-}" ]] && [[ "$ARCHIVEPAR2_KEEP" =~ ^[0-9]+$ ]]; then
    keep_versions="$ARCHIVEPAR2_KEEP"
  fi

  # --- Alocação Unificada de Temporários (Mais Enxuta) ---
  local status_file fifo_dir hash_fifo zstd_err_file par2_tty_file resume_out_file

  status_file=$(mktemp /tmp/archivepar2_status_XXX.dat) || { echo "ERROR: failed to create temporary status file" >&2; _a2_init_fail; return 1; }
  fifo_dir=$(mktemp -d /tmp/archivepar2_fifo_dir_XXX) || { rm -f "$status_file"; _a2_init_fail; return 1; }
  
  hash_fifo="$fifo_dir/hash.fifo"
  mkfifo "$hash_fifo" || { rm -rf "$fifo_dir" "$status_file"; _a2_init_fail; return 1; }

  zstd_err_file=$(mktemp /tmp/archivepar2_zstd_err_XXX.log) || { rm -rf "$fifo_dir" "$status_file"; _a2_init_fail; return 1; }
  par2_tty_file=$(mktemp /tmp/archivepar2_par2_tty_XXX.log) || { rm -f "$zstd_err_file"; rm -rf "$fifo_dir" "$status_file"; _a2_init_fail; return 1; }
  resume_out_file=$(mktemp /tmp/archivepar2_resume_out_XXX.dat) || { rm -f "$zstd_err_file" "$par2_tty_file"; rm -rf "$fifo_dir" "$status_file"; _a2_init_fail; return 1; }

  local abort_flag=0
  local pgid_b3sum="" pid_b3sum=""
  local pgid_main_pipeline="" pid_main_pipeline=""
  local pgid_par2="" pid_par2=""
  local pgid_helper="" pid_helper=""
  local pgid_check="" pid_check=""
  local pgid_resume="" pid_resume=""
  local _a2_cleaned=0
  local _a2_in_cleanup=0
  local -a _a2_orphan_pgids=()

  local _a2_old_trap_int _a2_old_trap_term
  _a2_old_trap_int=$(trap -p INT)
  _a2_old_trap_term=$(trap -p TERM)

  _a2_restore_traps() {
    if [[ -n "$_a2_old_trap_int" ]]; then eval "$_a2_old_trap_int"; else trap - INT; fi
    if [[ -n "$_a2_old_trap_term" ]]; then eval "$_a2_old_trap_term"; else trap - TERM; fi
  }

  _a2_cleanup() {
    _a2_in_cleanup=1
    _a2_release_lock 2>/dev/null || true
    _a2_cleanup_staging 2>/dev/null || true

    local cleanup_failed=0
    local local_pgid local_pid

    for local_pgid in "$pgid_par2" "$pgid_main_pipeline" "$pgid_b3sum" "$pgid_helper" "$pgid_check" "$pgid_resume"; do
      if [[ -n "$local_pgid" ]] && [[ "$local_pgid" =~ ^[0-9]+$ ]]; then
        if kill -0 -- -"$local_pgid" 2>/dev/null; then
          kill -TERM -- -"$local_pgid" 2>/dev/null || true
          local count=0
          while kill -0 -- -"$local_pgid" 2>/dev/null && (( count < 30 )); do
            sleep 0.1
            (( ++count ))
          done
          if kill -0 -- -"$local_pgid" 2>/dev/null; then
            kill -KILL -- -"$local_pgid" 2>/dev/null || true
            sleep 0.1
          fi
        fi
        if kill -0 -- -"$local_pgid" 2>/dev/null; then
          cleanup_failed=1
        fi
      fi
    done

    local _a2_op
    for _a2_op in "${_a2_orphan_pgids[@]+"${_a2_orphan_pgids[@]}"}"; do
      if [[ -n "$_a2_op" ]] && [[ "$_a2_op" =~ ^[0-9]+$ ]]; then
        if kill -0 -- -"$_a2_op" 2>/dev/null; then
          kill -TERM -- -"$_a2_op" 2>/dev/null || true
          local _a2_op_count=0
          while kill -0 -- -"$_a2_op" 2>/dev/null && (( _a2_op_count < 30 )); do
            sleep 0.1
            (( ++_a2_op_count ))
          done
          if kill -0 -- -"$_a2_op" 2>/dev/null; then
            kill -KILL -- -"$_a2_op" 2>/dev/null || true
          fi
        fi
        if kill -0 -- -"$_a2_op" 2>/dev/null; then
          cleanup_failed=1
        fi
      fi
    done

    for local_pid in "$pid_par2" "$pid_main_pipeline" "$pid_b3sum" "$pid_helper" "$pid_check" "$pid_resume"; do
      if [[ -n "$local_pid" ]] && [[ "$local_pid" =~ ^[0-9]+$ ]]; then
        local wait_count=0
        while (( wait_count < 20 )); do
          if wait "$local_pid" 2>/dev/null; then
            break
          else
            local rc=$?
            if (( rc == 127 )); then
              break
            fi
            sleep 0.05
          fi
          (( ++wait_count ))
        done
        if kill -0 "$local_pid" 2>/dev/null; then
          cleanup_failed=1
        fi
      fi
    done

    local f
    for f in "$zstd_err_file" "$par2_tty_file" "$status_file" "$resume_out_file"; do
      if [[ -f "$f" ]]; then
        rm -f "$f" 2>/dev/null || true
        [[ -f "$f" ]] && cleanup_failed=1
      fi
    done

    if [[ -d "$fifo_dir" ]]; then
      rm -rf "$fifo_dir" 2>/dev/null || true
      [[ -d "$fifo_dir" ]] && cleanup_failed=1
    fi

    cd "$oldpwd" >/dev/null 2>&1

    (( _a2_orig_pipefail )) || set +o pipefail
    _a2_restore_traps

        if (( cleanup_failed == 0 )); then
      _a2_cleaned=1
      unset -f _a2_print_log _a2_format_duration _a2_check_content_integrity \
               _a2_update_parts_array _a2_show_manifest _a2_verify_manifest_single \
               _a2_verify_manifest_split _a2_validate_global_manifest _a2_cleanup \
               _a2_handle_signal _a2_init_fail _a2_restore_traps _a2_launch_job _a2_reap_job \
               _a2_detect_layout _a2_resolve_active_dir _a2_log_layout_diagnostics \
               _a2_check_same_filesystem _a2_acquire_lock _a2_release_lock \
               _a2_remove_orphan_stagings _a2_create_staging _a2_commit_staging \
               _a2_cleanup_staging _a2_prune_obsolete_parts \
               _a2_is_versioned_layout _a2_generate_version_name \
               _a2_migrate_legacy_to_versioned _a2_commit_versioned \
               _a2_prune_old_versions _a2_extract_global_hash 2>/dev/null || true
    else
      return 1
    fi
  }

  _a2_handle_signal() {
    (( _a2_in_cleanup )) && return

    abort_flag=1
    echo -e "\n[ABORT] Operation interrupted by user or signal." >&2

    local local_pgid
    for local_pgid in "$pgid_par2" "$pgid_main_pipeline" "$pgid_b3sum" "$pgid_helper" "$pgid_check" "$pgid_resume"; do
      if [[ -n "$local_pgid" ]] && [[ "$local_pgid" =~ ^[0-9]+$ ]]; then
        if kill -0 -- -"$local_pgid" 2>/dev/null; then
          kill -TERM -- -"$local_pgid" 2>/dev/null || true
        fi
      fi
    done

    _a2_cleanup

    exit 1
  }

  trap _a2_handle_signal INT TERM

  if [[ -z "$arch" ]]; then
    echo "Error: no input folder provided" >&2
    _a2_cleanup
    return 1
  fi

  arch="$(realpath -e "$arch")" || {
    echo "Error: path not found" >&2
    _a2_cleanup
    return 1
  }

  if [[ ! -d "$arch" ]]; then
    echo "Error: provided path is not a directory" >&2
    _a2_cleanup
    return 1
  fi

  base="$(basename "$arch")"
  parent_dir="$(dirname "$arch")"

  out=$(printf "%s" "$base" \
    | tr '[:upper:]' '[:lower:]' \
    | tr ' ' '_' \
    | sed 's/[^a-z0-9_-]//g')

  dir="${out}-bak"
  manifest="${out}.blake3"
  logfile="${out}.log"

  mkdir -p "$dir" || {
    _a2_cleanup
    return 1
  }

  local backup_dir
  backup_dir=$(realpath "$dir") || {
    _a2_cleanup
    return 1
  }
  cd "$backup_dir" || {
    _a2_cleanup
    return 1
  }

  local lock_fd=9
  local lock_dir="$backup_dir/.archivepar2.lockdir"
  local lock_file="$backup_dir/.archivepar2.lock"
  local lock_acquired=0
  local lock_fs_type=""

  local staging_dir=""
  local staging_committed=0
  local run_id="$$.$RANDOM.$(date +%s)"

  local active_dir=""
  local versioned_layout=0
  local use_legacy_commit=0

  echo "==================================================" > "$logfile"
  echo "             ARCHIVEPAR2 SESSION LOG             " >> "$logfile"
  echo "==================================================" >> "$logfile"
  echo "Start Timestamp : $(date '+%Y-%m-%d %H:%M:%S')" >> "$logfile"
  echo "Source Path     : $arch" >> "$logfile"
  echo "Output Base Name: $out" >> "$logfile"
  echo "Target Directory: $backup_dir" >> "$logfile"
  echo "Arguments Used  : Single Mode=$single_mode | Fast Mode=$fast_mode | Max Size=$maxsize | Keep=$keep_versions | No-Migrate=$no_migrate" >> "$logfile"
  echo "Version         : v0.17-rc1.0.1" >> "$logfile"
  echo "--------------------------------------------------" >> "$logfile"

  _a2_print_log() {
    echo -e "$@" | tee -a "$logfile"
  }

  _a2_format_duration() {
    local sec=$1
    printf "%02d:%02d" $((sec / 60)) $((sec % 60))
  }

  _a2_detect_layout() {
    local target="$1"
    if [[ -L "$target/current" ]]; then
      echo "versioned"; return 0
    fi
    if compgen -G "$target/v[0-9]*-[0-9]*" > /dev/null; then
      echo "versioned"; return 0
    fi
    if compgen -G "$target/${out}.tar.zst.part-*" > /dev/null; then
      echo "legacy"; return 0
    fi
    if [[ -f "$target/${out}.tar.zst" ]] || [[ -f "$target/${out}.blake3" ]]; then
      echo "legacy"; return 0
    fi
    echo "empty"; return 0
  }

  _a2_resolve_active_dir() {
    local target="$1"
    local layout
    layout=$(_a2_detect_layout "$target")
    case "$layout" in
      versioned)
        if [[ -L "$target/current" ]]; then
          local resolved
          resolved=$(realpath "$target/current" 2>/dev/null) || { echo "$target"; return 0; }
          echo "$resolved"
        else
          local latest=""
          local v
          while IFS= read -r v; do
            [[ -n "$v" ]] && latest="$v"
          done < <(ls -1d "$target"/v[0-9]*-[0-9]* 2>/dev/null | sort)
          if [[ -n "$latest" ]]; then echo "$latest"; else echo "$target"; fi
        fi
        ;;
      legacy|empty|*) echo "$target" ;;
    esac
  }

  _a2_log_layout_diagnostics() {
    local target="$1"
    local layout active
    layout=$(_a2_detect_layout "$target")
    active=$(_a2_resolve_active_dir "$target")
    _a2_print_log "[LAYOUT] Detected layout: $layout"
    _a2_print_log "[LAYOUT] Active dir     : $active"
    if [[ "$layout" == "versioned" ]]; then
      if [[ -L "$target/current" ]]; then
        local link_target
        link_target=$(readlink "$target/current" 2>/dev/null || echo "?")
        _a2_print_log "[LAYOUT] current -> $link_target"
      else
        _a2_print_log "[LAYOUT] No 'current' symlink present; using latest v* dir"
      fi
      local -a versions=()
      local v
      while IFS= read -r v; do
        [[ -n "$v" ]] && versions+=("$v")
      done < <(ls -1d "$target"/v[0-9]*-[0-9]* 2>/dev/null | sort)
      if [[ ${#versions[@]} -gt 0 ]]; then
        _a2_print_log "[LAYOUT] Version history (${#versions[@]}):"
        for v in "${versions[@]}"; do
          _a2_print_log "[LAYOUT]   - $(basename "$v")"
        done
      fi
    fi
  }

  _a2_check_same_filesystem() {
    local path_a="$1"
    local path_b="$2"
    local dev_a dev_b
    dev_a=$(stat -c %d "$path_a" 2>/dev/null) || return 0
    dev_b=$(stat -c %d "$path_b" 2>/dev/null) || return 0
    [[ -n "$dev_a" ]] && [[ -n "$dev_b" ]] && [[ "$dev_a" == "$dev_b" ]]
  }

  _a2_remove_orphan_stagings() {
    local target="$1"
    local orig_nullglob=0
    [[ -o nullglob ]] && orig_nullglob=1
    shopt -s nullglob
    local -a orphans=( "$target"/.staging.* )
    (( orig_nullglob )) || shopt -u nullglob
    local o
    for o in "${orphans[@]}"; do
      [[ -d "$o" ]] || continue
      local base
      base=$(basename "$o")
      local pid_part
      pid_part=$(printf '%s' "$base" | awk -F. '{print $3}')
      if [[ "$pid_part" =~ ^[0-9]+$ ]] && kill -0 "$pid_part" 2>/dev/null; then
        _a2_print_log "[STAGING] Active staging of PID $pid_part found (not an orphan): $base"
        continue
      fi
      _a2_print_log "[STAGING] Removing orphan staging directory: $base"
      rm -rf "$o" 2>/dev/null || {
        _a2_print_log "[STAGING] WARN: could not remove orphan staging: $o"
      }
    done
  }

  _a2_create_staging() {
    local target="$1"
    staging_dir="$target/.staging.${run_id}"
    if ! mkdir "$staging_dir" 2>/dev/null; then
      _a2_print_log "[STAGING] ERROR: cannot create staging directory '$staging_dir'"
      return 1
    fi
    if ! _a2_check_same_filesystem "$staging_dir" "$target"; then
      _a2_print_log "[STAGING] ERROR: staging and backup are on different filesystems"
      _a2_print_log "[STAGING]         staging: $staging_dir"
      _a2_print_log "[STAGING]         backup : $target"
      _a2_print_log "[STAGING]         commit would require copying data (not supported)"
      rm -rf "$staging_dir" 2>/dev/null || true
      staging_dir=""
      return 1
    fi
    _a2_print_log "[STAGING] Created staging directory: $(basename "$staging_dir")"
    return 0
  }

  _a2_cleanup_staging() {
    [[ -n "$staging_dir" ]] || return 0
    [[ -d "$staging_dir" ]] || return 0
    if (( staging_committed )); then
      rm -rf "$staging_dir" 2>/dev/null || true
    else
      _a2_print_log "[STAGING] Removing uncommitted staging directory: $(basename "$staging_dir")"
      rm -rf "$staging_dir" 2>/dev/null || true
    fi
    staging_dir=""
    return 0
  }

  _a2_is_versioned_layout() {
    local target="$1"
    [[ -L "$target/current" ]] || compgen -G "$target/v[0-9]*-[0-9]*" > /dev/null
  }

  _a2_generate_version_name() {
    local base_name
    base_name="v$(date '+%Y%m%d-%H%M%S')"
    local candidate="$base_name"
    local suffix=1
    while [[ -e "$backup_dir/$candidate" ]]; do
      candidate="${base_name}-${suffix}"
      (( ++suffix ))
      if (( suffix > 999 )); then
        _a2_print_log "[VERSION] ERROR: could not generate unique version name after 999 attempts"
        return 1
      fi
    done
    echo "$candidate"
    return 0
  }

  _a2_migrate_legacy_to_versioned() {
    local target="$1"
    local layout
    layout=$(_a2_detect_layout "$target")
    if [[ "$layout" != "legacy" ]]; then
      return 0
    fi
    if (( no_migrate )); then
      _a2_print_log "[MIGRATE] Legacy layout detected but --no-migrate was given; keeping legacy"
      return 0
    fi
    local orig_nullglob=0
    [[ -o nullglob ]] && orig_nullglob=1
    shopt -s nullglob
    local -a legacy_files=(
      "$target"/${out}.tar.zst.part-*
      "$target"/${out}.tar.zst
      "$target"/${out}.blake3
      "$target"/${out}.par2
      "$target"/${out}.vol*.par2
    )
    (( orig_nullglob )) || shopt -u nullglob
    if (( ${#legacy_files[@]} == 0 )); then
      return 0
    fi
    local version_name
    version_name=$(_a2_generate_version_name) || return 1
    local version_dir="$target/$version_name"
    _a2_print_log "[MIGRATE] Migrating legacy layout to versioned: $version_name"
    if ! mkdir "$version_dir" 2>/dev/null; then
      _a2_print_log "[MIGRATE] ERROR: cannot create version directory '$version_dir'"
      return 1
    fi
    local f base moved=0
    for f in "${legacy_files[@]}"; do
      [[ -e "$f" ]] || continue
      base=$(basename "$f")
      if ! mv -f "$f" "$version_dir/$base" 2>/dev/null; then
        _a2_print_log "[MIGRATE] ERROR: failed to move '$base' to $version_name"
        local g gbase
        for g in "$version_dir"/*; do
          [[ -e "$g" ]] || continue
          gbase=$(basename "$g")
          mv -f "$g" "$target/$gbase" 2>/dev/null || true
        done
        rmdir "$version_dir" 2>/dev/null || true
        return 1
      fi
      (( ++moved ))
    done
    _a2_print_log "[MIGRATE] Moved $moved file(s) to $version_name"
    if ! ln -sfn "$version_name" "$target/current.tmp" 2>/dev/null; then
      _a2_print_log "[MIGRATE] ERROR: cannot create symlink current.tmp"
      return 1
    fi
    if ! mv -T "$target/current.tmp" "$target/current" 2>/dev/null; then
      _a2_print_log "[MIGRATE] ERROR: cannot rename current.tmp to current"
      rm -f "$target/current.tmp" 2>/dev/null || true
      return 1
    fi
    _a2_print_log "[MIGRATE] Migration complete; current -> $version_name"
    return 0
  }

  _a2_commit_versioned() {
    local staging="$1"
    local target="$2"
    [[ -d "$staging" ]] || {
      _a2_print_log "[COMMIT] ERROR: staging directory does not exist: $staging"
      return 1
    }
    local version_name
    version_name=$(_a2_generate_version_name) || return 1
    local version_dir="$target/$version_name"
    _a2_print_log "[COMMIT] Publishing staging as version: $version_name"
    if ! mv "$staging" "$version_dir" 2>/dev/null; then
      _a2_print_log "[COMMIT] ERROR: failed to rename staging to $version_name"
      return 1
    fi
    if ! ln -sfn "$version_name" "$target/current.tmp" 2>/dev/null; then
      _a2_print_log "[COMMIT] ERROR: cannot create current.tmp symlink"
      mv "$version_dir" "$staging" 2>/dev/null || true
      return 1
    fi
    if ! mv -T "$target/current.tmp" "$target/current" 2>/dev/null; then
      _a2_print_log "[COMMIT] ERROR: cannot rename current.tmp to current"
      rm -f "$target/current.tmp" 2>/dev/null || true
      mv "$version_dir" "$staging" 2>/dev/null || true
      return 1
    fi
    _a2_print_log "[COMMIT] Version $version_name is now active"
    staging_committed=1
    return 0
  }

  _a2_prune_old_versions() {
    local target="$1"
    local keep="$2"
    local orig_nullglob=0
    [[ -o nullglob ]] && orig_nullglob=1
    shopt -s nullglob
    local -a versions=( "$target"/v[0-9]*-[0-9]* )
    (( orig_nullglob )) || shopt -u nullglob
    if (( ${#versions[@]} == 0 )); then
      return 0
    fi
    local -a sorted
    mapfile -t sorted < <(printf '%s\n' "${versions[@]}" | sort)
    local active_target=""
    if [[ -L "$target/current" ]]; then
      active_target=$(readlink "$target/current" 2>/dev/null)
    fi
    local total=${#sorted[@]}
    local to_keep=$((keep + 1))
    if (( total <= to_keep )); then
      return 0
    fi
    local to_remove=$((total - to_keep))
    local removed=0
    local v vbase
    for v in "${sorted[@]}"; do
      (( to_remove == 0 )) && break
      [[ -d "$v" ]] || continue
      vbase=$(basename "$v")
      if [[ "$vbase" == "$active_target" ]]; then
        continue
      fi
      if rm -rf "$v" 2>/dev/null; then
        _a2_print_log "[PRUNE] Removed old version: $vbase"
        (( ++removed ))
        (( --to_remove ))
      else
        _a2_print_log "[PRUNE] WARN: could not remove old version: $vbase"
      fi
    done
    (( removed > 0 )) && _a2_print_log "[PRUNE] Removed $removed old version(s)."
    return 0
  }

  _a2_commit_staging() {
    local staging="$1"
    local target="$2"

    [[ -d "$staging" ]] || {
      _a2_print_log "[COMMIT] ERROR: staging directory does not exist: $staging"
      return 1
    }

    _a2_print_log "[COMMIT] Publishing staging to $target..."

    local orig_nullglob=0
    [[ -o nullglob ]] && orig_nullglob=1
    shopt -s nullglob

    local -a part_files=( "$staging"/*.tar.zst.part-* )
    local -a manifest_files=( "$staging"/*.blake3 )
    local -a par2_files=( "$staging"/*.par2 "$staging"/*.vol*.par2 )

    local moved=0
    local f base

    for f in "${part_files[@]}"; do
      [[ -e "$f" ]] || continue
      base=$(basename "$f")
      mv -f "$f" "$target/$base" 2>/dev/null || {
        _a2_print_log "[COMMIT] ERROR: failed to publish part '$base'"
        (( orig_nullglob )) || shopt -u nullglob
        return 1
      }
      (( ++moved ))
    done

    for f in "${manifest_files[@]}"; do
      [[ -e "$f" ]] || continue
      base=$(basename "$f")
      mv -f "$f" "$target/$base" 2>/dev/null || {
        _a2_print_log "[COMMIT] ERROR: failed to publish manifest '$base'"
        (( orig_nullglob )) || shopt -u nullglob
        return 1
      }
      (( ++moved ))
    done

    for f in "${par2_files[@]}"; do
      [[ -e "$f" ]] || continue
      base=$(basename "$f")
      mv -f "$f" "$target/$base" 2>/dev/null || {
        _a2_print_log "[COMMIT] ERROR: failed to publish par2 '$base'"
        (( orig_nullglob )) || shopt -u nullglob
        return 1
      }
      (( ++moved ))
    done

    (( orig_nullglob )) || shopt -u nullglob

    _a2_print_log "[COMMIT] Published $moved file(s)."
    staging_committed=1
    return 0
  }

      _a2_prune_obsolete_parts() {
    local target="$1"
    local manifest_name="${out}.blake3"

    [[ -f "$target/$manifest_name" ]] || {
      _a2_print_log "[PRUNE] WARN: manifest not found in $target; skipping obsolete-part prune"
      return 0
    }

    local -A expected=()
    local line name
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${line// }" ]] && continue
      name="${line##*[[:space:]]}"
      name="${name##*/}"
      [[ "$name" == *".tar.zst.part-"* ]] || continue
      expected["$name"]=1
    done < "$target/$manifest_name"

    local orig_nullglob=0
    [[ -o nullglob ]] && orig_nullglob=1
    shopt -s nullglob

    local -a existing=( "$target"/${out}.tar.zst.part-* )
    (( orig_nullglob )) || shopt -u nullglob

    local f base
    local removed=0
    local prune_failed=0
    for f in "${existing[@]}"; do
      [[ -e "$f" ]] || continue
      base=$(basename "$f")
      if [[ -z "${expected[$base]:-}" ]]; then
        if rm -f "$f" 2>/dev/null; then
          (( ++removed ))
          _a2_print_log "[PRUNE] Removed obsolete part: $base"
        else
          _a2_print_log "[PRUNE] ERROR: could not remove obsolete part: $base"
          prune_failed=1
        fi
      fi
    done

    (( removed > 0 )) && _a2_print_log "[PRUNE] Removed $removed obsolete part(s)."
    
    (( prune_failed )) && return 1
    return 0
  }


    _a2_acquire_lock() {
    local target="$1"
    lock_fs_type=$(stat -f -c %T "$target" 2>/dev/null || echo "unknown")
    case "$lock_fs_type" in
      sshfs|fuse*|cifs|smb*|9p)
        _a2_print_log "[LOCK] WARN: filesystem '$lock_fs_type' may not support reliable locking"
        ;;
    esac
    if command -v flock >/dev/null 2>&1; then
      exec {lock_fd}>"$lock_file" || {
        _a2_print_log "[LOCK] ERROR: cannot open lock file '$lock_file'"
        return 1
      }
      if ! flock -n "$lock_fd"; then
        local holder_pid="" holder_time="" holder_cmd=""
        if [[ -d "$lock_dir" ]]; then
          holder_pid=$(cat "$lock_dir/pid" 2>/dev/null)
          holder_time=$(cat "$lock_dir/time" 2>/dev/null)
          holder_cmd=$(cat "$lock_dir/cmd" 2>/dev/null)
        fi
        _a2_print_log "[LOCK] ERROR: another archivepar2 instance holds the lock on $target"
        _a2_print_log "[LOCK]   PID     : ${holder_pid:-?}"
        [[ -n "$holder_time" ]] && _a2_print_log "[LOCK]   Started : $holder_time"
        [[ -n "$holder_cmd"  ]] && _a2_print_log "[LOCK]   Command : $holder_cmd"
        _a2_print_log "[LOCK]   To force: rm -rf '$lock_dir'"
        exec {lock_fd}>&- 2>/dev/null || true
        return 1
      fi
    fi
    if ! mkdir "$lock_dir" 2>/dev/null; then
      local holder_pid holder_time holder_cmd holder_alive=0
      holder_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
      holder_time=$(cat "$lock_dir/time" 2>/dev/null || echo "")
      holder_cmd=$(cat "$lock_dir/cmd" 2>/dev/null || echo "")
      if [[ -n "$holder_pid" ]] && [[ "$holder_pid" =~ ^[0-9]+$ ]]; then
        if kill -0 "$holder_pid" 2>/dev/null; then
          local cmdline=""
          if [[ -r "/proc/$holder_pid/cmdline" ]]; then
            cmdline=$(tr '\0' ' ' < "/proc/$holder_pid/cmdline" 2>/dev/null)
          elif command -v ps >/dev/null 2>&1; then
            cmdline=$(ps -p "$holder_pid" -o comm= 2>/dev/null)
          fi
          if [[ "$cmdline" == *archivepar2* ]] || [[ "$cmdline" == *bash* ]]; then
            holder_alive=1
          fi
        fi
      fi
      if (( holder_alive )); then
        _a2_print_log "[LOCK] ERROR: another archivepar2 instance holds the lock on $target"
        _a2_print_log "[LOCK]   PID     : ${holder_pid:-?}"
        [[ -n "$holder_time" ]] && _a2_print_log "[LOCK]   Started : $holder_time"
        [[ -n "$holder_cmd"  ]] && _a2_print_log "[LOCK]   Command : $holder_cmd"
        _a2_print_log "[LOCK]   To force: rm -rf '$lock_dir'"
        if command -v flock >/dev/null 2>&1; then
          exec {lock_fd}>&- 2>/dev/null || true
        fi
        return 1
      fi
      _a2_print_log "[LOCK] WARN: stale lockdir detected (PID ${holder_pid:-unknown} not an active archivepar2). Removing."
      rm -rf "$lock_dir" 2>/dev/null || {
        _a2_print_log "[LOCK] ERROR: cannot remove stale lockdir '$lock_dir'"
        if command -v flock >/dev/null 2>&1; then
          exec {lock_fd}>&- 2>/dev/null || true
        fi
        return 1
      }
      if ! mkdir "$lock_dir" 2>/dev/null; then
        _a2_print_log "[LOCK] ERROR: cannot create lockdir after stale-lock cleanup"
        if command -v flock >/dev/null 2>&1; then
          exec {lock_fd}>&- 2>/dev/null || true
        fi
        return 1
      fi
    fi
    echo "$BASHPID" > "$lock_dir/pid" 2>/dev/null || true
    date '+%Y-%m-%d %H:%M:%S' > "$lock_dir/time" 2>/dev/null || true
    if [[ -r "/proc/$BASHPID/cmdline" ]]; then
      tr '\0' ' ' < "/proc/$BASHPID/cmdline" > "$lock_dir/cmd" 2>/dev/null || true
    else
      ps -p "$BASHPID" -o args= > "$lock_dir/cmd" 2>/dev/null || echo "archivepar2" > "$lock_dir/cmd"
    fi
    lock_acquired=1
    _a2_print_log "[LOCK] Acquired lock on $target (PID $BASHPID, fs=$lock_fs_type)"
    return 0
  }

  _a2_release_lock() {
    (( lock_acquired )) || return 0
    if [[ -d "$lock_dir" ]]; then
      local owner_pid=""
      owner_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
      if [[ "$owner_pid" == "$BASHPID" ]]; then
        rm -rf "$lock_dir" 2>/dev/null || true
      fi
    fi
    if command -v flock >/dev/null 2>&1; then
      exec {lock_fd}>&- 2>/dev/null || true
    fi
    lock_acquired=0
  }

  if ! _a2_acquire_lock "$backup_dir"; then
    _a2_cleanup
    return 1
  fi

  if ! _a2_migrate_legacy_to_versioned "$backup_dir"; then
    _a2_print_log "ERROR: migration failed"
    _a2_cleanup
    return 1
  fi

  active_dir="$(_a2_resolve_active_dir "$backup_dir")"
  if _a2_is_versioned_layout "$backup_dir"; then
    versioned_layout=1
  fi

  if (( versioned_layout )); then
    use_legacy_commit=0
  elif (( no_migrate )); then
    use_legacy_commit=1
  else
    use_legacy_commit=0
  fi

  _a2_print_log "[LAYOUT] Active dir (resolved): $active_dir"
  _a2_print_log "[LAYOUT] Versioned mode       : $versioned_layout"
  _a2_print_log "[LAYOUT] Commit strategy      : $([[ $use_legacy_commit -eq 1 ]] && echo 'legacy (files in backup_dir)' || echo 'versioned (v<timestamp> + symlink)')"

  _a2_remove_orphan_stagings "$backup_dir"

  echo "==============================="
  echo "Archiving: $arch"
  echo "Working dir: $backup_dir"
  echo "Output base: $out"
  echo "==============================="

  _a2_log_layout_diagnostics "$backup_dir"

  if _a2_check_same_filesystem "$backup_dir" "$backup_dir"; then
    _a2_print_log "[FS] Backup directory filesystem check: same-device trivially OK"
  else
    _a2_print_log "[FS] WARN: could not determine filesystem device for $backup_dir"
  fi

  _a2_launch_job() {
    local _a2_target_pid="$1"
    local _a2_target_pgid="$2"
    shift 2
    local _a2_pgid_file _a2_ack_file
    _a2_pgid_file=$(mktemp "$fifo_dir/pgid_XXX.dat") || return 1
    _a2_ack_file=$(mktemp -u "$fifo_dir/ack_XXX.dat") || { rm -f "$_a2_pgid_file"; return 1; }
    {
      set +m
      setsid -w bash -c '
        echo "$BASHPID" > "$1" || exit 1
        count=0
        while [[ ! -f "$2" ]] && (( count < 100 )); do
          sleep 0.01
          (( ++count ))
        done
        [[ -f "$2" ]] || exit 1
        rm -f "$2" 2>/dev/null || true
        shift 2
        exec "$@"
      ' _ "$_a2_pgid_file" "$_a2_ack_file" "$@" &
      local _a2_child_pid=$!
    } 2>/dev/null
    local _a2_captured_pgid=""
    local _a2_count=0
    while [[ ! -s "$_a2_pgid_file" ]] && (( _a2_count < 100 )); do
      if ! kill -0 "$_a2_child_pid" 2>/dev/null; then
        break
      fi
      sleep 0.01
      (( ++_a2_count ))
    done
    if [[ -s "$_a2_pgid_file" ]]; then
      _a2_captured_pgid=$(< "$_a2_pgid_file")
    fi
    rm -f "$_a2_pgid_file" 2>/dev/null || true
    local _a2_g_active=0
    if [[ -n "$_a2_captured_pgid" ]] && [[ "$_a2_captured_pgid" =~ ^[0-9]+$ ]] && kill -0 -- -"${_a2_captured_pgid}" 2>/dev/null; then
      _a2_g_active=1
    fi
    local _a2_launch_failed=0
    if (( _a2_g_active == 0 )) || (( abort_flag == 1 )); then
      _a2_launch_failed=1
    elif ! touch "$_a2_ack_file" 2>/dev/null; then
      _a2_launch_failed=1
    fi
    if (( _a2_launch_failed )); then
      rm -f "$_a2_ack_file" 2>/dev/null || true
      if (( _a2_g_active )) && kill -0 -- -"${_a2_captured_pgid}" 2>/dev/null; then
        kill -TERM -- -"${_a2_captured_pgid}" 2>/dev/null || true
      fi
      kill -TERM "$_a2_child_pid" 2>/dev/null || true
      local _a2_sub_c=0
      while (( _a2_sub_c < 20 )); do
        local _a2_alive=0
        kill -0 "$_a2_child_pid" 2>/dev/null && _a2_alive=1
        (( _a2_g_active )) && kill -0 -- -"${_a2_captured_pgid}" 2>/dev/null && _a2_alive=1
        (( _a2_alive == 0 )) && break
        sleep 0.05
        (( ++_a2_sub_c ))
      done
      if kill -0 "$_a2_child_pid" 2>/dev/null; then
        kill -KILL "$_a2_child_pid" 2>/dev/null || true
      fi
      if (( _a2_g_active )) && kill -0 -- -"${_a2_captured_pgid}" 2>/dev/null; then
        kill -KILL -- -"${_a2_captured_pgid}" 2>/dev/null || true
      fi
      wait "$_a2_child_pid" 2>/dev/null || true
      if (( _a2_g_active )); then
        local _a2_conf_c=0
        while kill -0 -- -"${_a2_captured_pgid}" 2>/dev/null && (( _a2_conf_c < 10 )); do
          sleep 0.05
          (( ++_a2_conf_c ))
        done
        if kill -0 -- -"${_a2_captured_pgid}" 2>/dev/null; then
          _a2_orphan_pgids+=("${_a2_captured_pgid}")
        fi
      fi
      return 1
    fi
    eval "$_a2_target_pid=$_a2_child_pid"
    eval "$_a2_target_pgid=$_a2_captured_pgid"
    return 0
  }

  _a2_reap_job() {
    local _a2_target_pid_var="$1"
    local _a2_target_pgid_var="$2"
    local _a2_status_var_name="$3"
    local _a2_r_pid="${!_a2_target_pid_var}"
    local _a2_r_pgid="${!_a2_target_pgid_var}"
    local _a2_r_st=1
    local _a2_retry_count=0
    local _a2_reap_confirmed=0
    if [[ -z "$_a2_r_pid" ]] || ! [[ "$_a2_r_pid" =~ ^[0-9]+$ ]] || [[ -z "$_a2_r_pgid" ]] || ! [[ "$_a2_r_pgid" =~ ^[0-9]+$ ]]; then
      eval "$_a2_status_var_name=1"
      return 1
    fi
    while (( _a2_retry_count < 100 )); do
      if wait "$_a2_r_pid" 2>/dev/null; then
        _a2_r_st=0
        _a2_reap_confirmed=1
        break
      else
        _a2_r_st=$?
        if (( _a2_r_st == 127 )); then
          _a2_reap_confirmed=0
          break
        fi
        if kill -0 "$_a2_r_pid" 2>/dev/null; then
          if (( abort_flag == 1 )); then
            if kill -0 -- -"${_a2_r_pgid}" 2>/dev/null; then
              kill -TERM -- -"${_a2_r_pgid}" 2>/dev/null || true
            fi
          fi
          (( ++_a2_retry_count ))
          sleep 0.05
          continue
        fi
        _a2_reap_confirmed=1
        break
      fi
    done
    local _a2_g_count=0
    local _a2_forced_kill=0
    while kill -0 -- -"${_a2_r_pgid}" 2>/dev/null && (( _a2_g_count < 40 )); do
      sleep 0.05
      (( ++_a2_g_count ))
    done
    if kill -0 -- -"${_a2_r_pgid}" 2>/dev/null; then
      _a2_forced_kill=1
      kill -KILL -- -"${_a2_r_pgid}" 2>/dev/null || true
      local _a2_k_count=0
      while kill -0 -- -"${_a2_r_pgid}" 2>/dev/null && (( _a2_k_count < 20 )); do
        sleep 0.05
        (( ++_a2_k_count ))
      done
      if kill -0 -- -"${_a2_r_pgid}" 2>/dev/null; then
        _a2_reap_confirmed=0
      fi
    fi
    if (( _a2_forced_kill )); then
      _a2_reap_confirmed=0
      (( _a2_r_st == 0 )) && _a2_r_st=1
    fi
    eval "$_a2_status_var_name=$_a2_r_st"
    if (( _a2_reap_confirmed )); then
      eval "$_a2_target_pid_var=\"\""
      eval "$_a2_target_pgid_var=\"\""
      return 0
    else
      return 1
    fi
  }

  _a2_check_content_integrity() {
    (( abort_flag )) && return 1
    if (( fast_mode )); then
      check_status="PASSED (FAST MODE)"
      return 0
    fi
    local chk_start chk_end
    chk_start=$(date +%s)
    _a2_print_log "=============================="
    _a2_print_log "[TAR CHECK] Checking content integrity against origin..."
    (( abort_flag )) && return 1
    local where=""
    if [[ -n "$staging_dir" ]] && [[ -d "$staging_dir" ]]; then
      where="$staging_dir"
    elif [[ -n "$active_dir" ]] && [[ -d "$active_dir" ]]; then
      where="$active_dir"
    else
      where="$backup_dir"
    fi
    local status=0
    if (( single_mode )); then
        _a2_launch_job pid_check pgid_check bash -c '
          set -o pipefail
          cd "$1" || exit 1
          zstd -dc --progress "$2/$3.tar.zst" | tar --diff -f -
        ' _ "$parent_dir" "$where" "$out"
    else
        local -a abs_parts=()
        local p
        for p in "${parts[@]}"; do
          abs_parts+=( "$where/$(basename "$p")" )
        done
        if (( ${#abs_parts[@]} == 0 )); then
          _a2_print_log "ERROR: no parts available for integrity check"
          check_status="FAILED"
          return 1
        fi
        _a2_launch_job pid_check pgid_check bash -c '
          set -o pipefail
          cd "$1" || exit 1
          shift
          cat "$@" | zstd -dc --progress | tar --diff -f -
        ' _ "$parent_dir" "${abs_parts[@]}"
    fi
    if (( $? != 0 )); then
      _a2_print_log "ERROR: Failed to launch integrity check job."
      check_status="FAILED"
      return 1
    fi
    if ! _a2_reap_job pid_check pgid_check status; then
      _a2_print_log "ERROR: Could not reliably reap integrity check job."
      check_status="FAILED"
      return 1
    fi
    chk_end=$(date +%s)
    t_check_dur=$(_a2_format_duration $((chk_end - chk_start)))
    (( abort_flag )) && return 1
    if [ $status -eq 0 ]; then
        _a2_print_log "[TAR CHECK] Content Successfully Validated (100% Identical)."
        _a2_print_log "=============================="
        check_status="SUCCESS"
    else
        _a2_print_log "ERROR: Content verification failed!"
        check_status="FAILED"
    fi
    return $status
  }

  _a2_update_parts_array() {
    local where="${1:-}"
    if [[ -z "$where" ]]; then
      if [[ -n "$staging_dir" ]] && [[ -d "$staging_dir" ]]; then
        where="$staging_dir"
      elif [[ -n "$active_dir" ]] && [[ -d "$active_dir" ]]; then
        where="$active_dir"
      else
        where="$backup_dir"
      fi
    fi
    local orig_nullglob=0
    [[ -o nullglob ]] && orig_nullglob=1
    shopt -s nullglob
    local -a raw=( "$where"/${out}.tar.zst.part-* )
    (( orig_nullglob )) || shopt -u nullglob
    parts=()
    local f
    for f in "${raw[@]}"; do
      [[ -e "$f" ]] || continue
      parts+=( "$(basename "$f")" )
    done
  }

  _a2_show_manifest() {
    local m_file="${1:-$manifest}"
    [[ -f "$m_file" ]] || return
    _a2_print_log "[BLAKE3 MANIFEST CONTENT]"
    cat "$m_file" >> "$logfile"
    cat "$m_file"
  }

  # _a2_extract_global_hash <manifest_file> <target_name>
  #
  # Ecoa o hash BLAKE3 da entrada global de <target_name> em stdout (se válido).
  # Retorna:
  #   0  = entrada encontrada, válida e única; hash ecoado em stdout
  #   10 = entrada ausente (manifest vazio, ou sem entrada para target)
  #   11 = entrada malformada / duplicada / target no campo errado
  #   4  = erro de I/O ou sintaxe no manifest (awk falhou)
  #
  # Não loga nada. O chamador decide como reportar.
  _a2_extract_global_hash() {
    local m_file="$1"
    local target_name="$2"

    [[ -f "$m_file" ]] || return 10

    local result
    result=$(awk -v target="$target_name" '
      BEGIN { count = 0; malformed_pos = 0; invalid = 0; valid_hash = "" }
      /^[[:space:]]*#/ { next }
      NF == 0 { next }
      {
        if ($2 == target) {
          count++
          if (NF == 2 && length($1) == 64 && $1 ~ /^[0-9a-fA-F]+$/) {
            valid_hash = $1
          } else {
            invalid = 1
          }
        } else {
          for (i = 1; i <= NF; i++) {
            if ($i == target) malformed_pos = 1
          }
        }
      }
      END {
        if (malformed_pos) exit 11
        if (count == 0) exit 10
        if (count > 1 || invalid) exit 11
        print valid_hash
        exit 0
      }
    ' "$m_file")
    local rc=$?

    case $rc in
      0)
        [[ -n "$result" ]] || return 10
        printf '%s\n' "$result"
        return 0
        ;;
      10) return 10 ;;
      11) return 11 ;;
      *)  return 4  ;;
    esac
  }

  _a2_verify_manifest_single() {
    local active_manifest="$active_dir/${out}.blake3"
    local stored

    stored=$(_a2_extract_global_hash "$active_manifest" "${out}.tar.zst")
    local v_status=$?

    case $v_status in
      0)  : ;;
      10) return 10 ;;
      11) _a2_print_log "ERROR: Manifest contains duplicate, malformed, or misplaced global entry for target."
          return 3 ;;
      *)  _a2_print_log "ERROR: Failed to read or parse manifest file due to I/O or syntax error."
          return 4 ;;
    esac

    : > "$resume_out_file"
    if ! _a2_launch_job pid_resume pgid_resume bash -c '
      set -o pipefail
      b3sum "$1" | awk '\''{print $1}'\'' > "$2"
    ' _ "$active_dir/${out}.tar.zst" "$resume_out_file"; then
      _a2_print_log "ERROR: Failed to launch resume hash job."
      return 4
    fi
    local resume_wait_status=0
    if ! _a2_reap_job pid_resume pgid_resume resume_wait_status; then
      _a2_print_log "ERROR: Could not reliably reap resume hash job."
      return 4
    fi
    if (( resume_wait_status != 0 )) || ! [[ -f "$resume_out_file" ]]; then
      _a2_print_log "ERROR: Failed to compute hash for existing archive during resume."
      return 4
    fi
    local current
    current=$(< "$resume_out_file")
    [[ -n "$current" ]] || return 4
    _a2_print_log "[BLAKE3] Stored Global : $stored"
    _a2_print_log "[BLAKE3] Current Stream: $current"
    [[ "$stored" == "$current" ]]
  }

  _a2_verify_manifest_split() {
    local active_manifest="$active_dir/${out}.blake3"
    local stored

    stored=$(_a2_extract_global_hash "$active_manifest" "${out}.tar.zst")
    local v_status=$?

    case $v_status in
      0)  : ;;
      10) return 10 ;;
      11) _a2_print_log "ERROR: Manifest contains duplicate, malformed, or misplaced global entry for target."
          return 3 ;;
      *)  _a2_print_log "ERROR: Failed to read or parse manifest file due to I/O or syntax error."
          return 4 ;;
    esac

    : > "$resume_out_file"
    if command -v pv >/dev/null 2>&1; then
      if ! _a2_launch_job pid_resume pgid_resume bash -c '
        set -o pipefail
        out_file="${@: -1}"
        parts_list=("${@:1:$#-1}")
        cat -- "${parts_list[@]}" | pv -N "Validating Split Files" -p -t -e -r -b | b3sum | awk '\''{print $1}'\'' > "$out_file"
      ' _ "${parts[@]/#/$active_dir/}" "$resume_out_file"; then
        _a2_print_log "ERROR: Failed to launch split resume hash job."
        return 4
      fi
    else
      if ! _a2_launch_job pid_resume pgid_resume bash -c '
        set -o pipefail
        out_file="${@: -1}"
        parts_list=("${@:1:$#-1}")
        cat -- "${parts_list[@]}" | b3sum | awk '\''{print $1}'\'' > "$out_file"
      ' _ "${parts[@]/#/$active_dir/}" "$resume_out_file"; then
        _a2_print_log "ERROR: Failed to launch split resume hash job."
        return 4
      fi
    fi
    local resume_wait_status=0
    if ! _a2_reap_job pid_resume pgid_resume resume_wait_status; then
      _a2_print_log "ERROR: Could not reliably reap split resume hash job."
      return 4
    fi
    if (( resume_wait_status != 0 )) || ! [[ -f "$resume_out_file" ]]; then
      _a2_print_log "ERROR: Failed to read/compute hash of split parts during resume."
      return 4
    fi
    local current
    current=$(< "$resume_out_file")
    [[ -n "$current" ]] || return 4
    _a2_print_log "[BLAKE3] Stored Global : $stored"
    _a2_print_log "[BLAKE3] Current Stream: $current"
    [[ "$stored" == "$current" ]]
  }

  _a2_validate_global_manifest() {
    local m_file="${1:-$manifest}"
    _a2_extract_global_hash "$m_file" "${out}.tar.zst" >/dev/null
  }

  # ==================== FLUXO PRINCIPAL ====================
  local run_compression=1
  local comp_start comp_end
  local response

  if (( abort_flag )); then
    _a2_print_log "Operation aborted."
    _a2_cleanup
    return 1
  fi

  if [[ "$single_mode" -eq 0 && -n "$maxsize" ]]; then
    # ==================== MODO SPLIT ====================
    _a2_print_log "[MODE] Split mode ($maxsize)"
    _a2_update_parts_array
    (( abort_flag )) && { _a2_cleanup; return 1; }

    if [[ ${#parts[@]} -gt 0 ]]; then
      _a2_print_log "[RESUME] Found existing split parts. Testing their integrity directly..."
      _a2_verify_manifest_split
      local v_status=$?
      if (( v_status == 0 )); then
        _a2_print_log "[BLAKE3] Manifest OK"
        if _a2_check_content_integrity; then
          _a2_print_log "[RESUME] Existing parts are healthy! Skipping compression stage."
          _a2_show_manifest "$active_dir/${out}.blake3"
          run_compression=0
        fi
      elif (( v_status == 10 )); then
        _a2_print_log "[WARN] Manifest not found or missing global entry."
        read -r -p "Continue without valid BLAKE3 validation? [y/N]: " response </dev/tty
        if [[ "$response" =~ ^[yY](es)?$ ]]; then
          if _a2_check_content_integrity; then
            _a2_print_log "[RESUME] Existing parts are healthy! Skipping compression stage."
            run_compression=0
          fi
        fi
      else
        _a2_print_log "ERROR: Resume validation failed due to manifest corruption, duplication, structural error, or read failure."
        _a2_cleanup
        return 1
      fi
    fi
    (( abort_flag )) && { _a2_cleanup; return 1; }

    if (( run_compression )); then
      if ! _a2_create_staging "$backup_dir"; then
        _a2_print_log "ERROR: failed to create staging directory"
        _a2_cleanup
        return 1
      fi
      local staging_manifest="$staging_dir/${out}.blake3"
      local staging_status_file="$staging_dir/.status"
      comp_start=$(date +%s)
      echo "# Created: $(date '+%Y-%m-%d %H:%M:%S')" > "$staging_manifest"
      echo "1" > "$staging_status_file"

      if ! _a2_launch_job pid_b3sum pgid_b3sum bash -c '
        set -o pipefail
        if b3sum < "$1" | awk -v target="$2" '\''{print $1 "  " target}'\'' >> "$3"; then
          echo "0" > "$4"
        else
          echo "1" > "$4"
        fi
      ' _ "$hash_fifo" "${out}.tar.zst" "$staging_manifest" "$staging_status_file"; then
        _a2_print_log "ERROR: Failed to launch b3sum job."
        _a2_cleanup
        return 1
      fi
      (( abort_flag )) && { _a2_cleanup; return 1; }

      local split_prefix="$staging_dir/${out}.tar.zst.part-"
      if ! _a2_launch_job pid_main_pipeline pgid_main_pipeline bash -c '
        set -o pipefail
        zstd_cmd="tar -cf - -C '\''$1'\'' '\''$2'\'' | zstd -T0 -10 --long=27 -v --progress | tee '\''$4'\'' | split -d -a 3 -b '\''$5'\'' - '\''$6'\''"
        script -q -f "$3" -c "$zstd_cmd"
      ' _ "$parent_dir" "$base" "$zstd_err_file" "$hash_fifo" "$maxsize" "$split_prefix"; then
        _a2_print_log "ERROR: Failed to launch main compression pipeline job."
        _a2_cleanup
        return 1
      fi
      local pipe_status=1
      if ! _a2_reap_job pid_main_pipeline pgid_main_pipeline pipe_status; then
        _a2_print_log "ERROR: Could not reliably reap archive pipeline."
        _a2_cleanup
        return 1
      fi
      if (( pipe_status != 0 )); then
        _a2_print_log "ERROR: archive pipeline failed (status: $pipe_status)"
        _a2_cleanup
        return 1
      fi
      (( abort_flag )) && {
        _a2_print_log "ERROR: Operation aborted."
        _a2_cleanup
        return 1
      }
      local b3sum_wait_status=1
      if ! _a2_reap_job pid_b3sum pgid_b3sum b3sum_wait_status; then
        _a2_print_log "ERROR: Could not reliably reap global BLAKE3 hashing process."
        _a2_cleanup
        return 1
      fi
      local b3sum_file_status="MISSING"
      [[ -f "$staging_status_file" ]] && b3sum_file_status=$(< "$staging_status_file")
      if [[ $b3sum_wait_status -ne 0 || "$b3sum_file_status" != "0" ]]; then
        _a2_print_log "ERROR: global BLAKE3 hashing process failed or did not complete successfully"
        _a2_cleanup
        return 1
      fi
      if ! _a2_validate_global_manifest "$staging_manifest"; then
        _a2_print_log "ERROR: BLAKE3 manifest missing or has invalid/duplicate/misplaced global archive entry"
        _a2_cleanup
        return 1
      fi
      if [[ -f "$zstd_err_file" ]]; then
        zstd_golden_line=$(tr '\r' '\n' < "$zstd_err_file" | grep -E 'GiB|MiB|B =>' | tail -n1 | sed 's/^[ \t]*//')
      fi
      if [[ -n "$zstd_golden_line" ]]; then
        _a2_print_log "--------------------------------------------------"
        _a2_print_log "            ZSTD COMPRESSION METRICS"
        _a2_print_log "--------------------------------------------------"
        _a2_print_log "$zstd_golden_line"
      fi
      (( abort_flag )) && { _a2_cleanup; return 1; }

      _a2_print_log "\n[SPLIT MODE] Collecting split parts and hashing individual files..."
      _a2_update_parts_array "$staging_dir"
      [[ ${#parts[@]} -gt 0 ]] || { _a2_print_log "ERROR: no split parts found in staging"; _a2_cleanup; return 1; }
      if ! _a2_launch_job pid_helper pgid_helper bash -c '
        manifest="$1"
        shift
        for part in "$@"; do
          p_size=$(stat -c%s "$part") || exit 1
          bname=$(basename "$part")
          if command -v pv >/dev/null 2>&1; then
            hash=$(set -o pipefail; pv -N "Hashing $bname" -s "$p_size" -p -t -e -r "$part" | b3sum | awk '\''{print $1}'\'') || exit 1
          else
            hash=$(set -o pipefail; b3sum "$part" | awk '\''{print $1}'\'') || exit 1
          fi
          [[ -n "$hash" ]] || exit 1
          echo "$hash  $bname" >> "$manifest" || exit 1
        done
      ' _ "$staging_manifest" "${parts[@]/#/$staging_dir/}"; then
        _a2_print_log "ERROR: Failed to launch split parts hashing job."
        _a2_cleanup
        return 1
      fi
      local helper_status=1
      if ! _a2_reap_job pid_helper pgid_helper helper_status; then
        _a2_print_log "ERROR: Could not reliably reap split parts hashing job."
        _a2_cleanup
        return 1
      fi
      if (( helper_status != 0 )) || (( abort_flag )); then
        _a2_print_log "ERROR: failed to compute hashes for split parts or operation aborted."
        _a2_cleanup
        return 1
      fi
      _a2_print_log "[BLAKE3 MANIFEST CONTENT]"
      cat "$staging_manifest" >> "$logfile"
      cat "$staging_manifest"
      comp_end=$(date +%s)
      t_compress_dur=$(_a2_format_duration $((comp_end - comp_start)))
      compress_status="SUCCESS"
      _a2_check_content_integrity || { _a2_cleanup; return 1; }

      local par2_start par2_end
      par2_start=$(date +%s)
      _a2_print_log "[PAR2] Creating recovery files..."
      local -a rel_parts=()
      local p
      for p in "${parts[@]}"; do
        rel_parts+=( "$(basename "$p")" )
      done
      local par2_cmd
      par2_cmd=$(printf "par2 create -r10 %q " "${out}.par2"; printf "%q " "${rel_parts[@]}"; printf "%q" "$(basename "$staging_manifest")")
      if ! _a2_launch_job pid_par2 pgid_par2 bash -c '
        cd "$1" || exit 1
        script -q -f "$2" -c "$3"
      ' _ "$staging_dir" "$par2_tty_file" "$par2_cmd"; then
        _a2_print_log "ERROR: Failed to launch PAR2 job."
        _a2_cleanup
        return 1
      fi
      local par2_exit_status=1
      if ! _a2_reap_job pid_par2 pgid_par2 par2_exit_status; then
        _a2_print_log "ERROR: Could not reliably reap PAR2 job."
        _a2_cleanup
        return 1      
      fi
      if [[ -f "$par2_tty_file" ]]; then
        tr '\r' '\n' < "$par2_tty_file" | sed 's/\x1B\[[0-9;]*[JKmsu]//g' | grep -v -E '[0-9]+\.[0-9]%|Opening:|Processing:|Constructing:' >> "$logfile"
      fi
      (( abort_flag )) && { _a2_cleanup; return 1; }
      if (( par2_exit_status != 0 )); then
        par2_status="FAILED"
        _a2_print_log "ERROR: PAR2 creation failed"
        _a2_cleanup
        return 1
      fi
      par2_end=$(date +%s)
      t_par2_dur=$(_a2_format_duration $((par2_end - par2_start)))
      par2_status="SUCCESS"
      par2_done=1

      if (( use_legacy_commit )); then
        if ! _a2_commit_staging "$staging_dir" "$backup_dir"; then
          _a2_print_log "ERROR: legacy commit failed; previous backup may be partially overwritten"
          _a2_cleanup
          return 1
        fi
        _a2_prune_obsolete_parts "$backup_dir"
        _a2_cleanup_staging
      else
        if ! _a2_commit_versioned "$staging_dir" "$backup_dir"; then
          _a2_print_log "ERROR: versioned commit failed; previous backup remains active"
          _a2_cleanup
          return 1
        fi
        _a2_prune_old_versions "$backup_dir" "$keep_versions"
        staging_dir=""
        staging_committed=0
      fi
    fi

    (( abort_flag )) && { _a2_cleanup; return 1; }

    if (( ! par2_done )); then
      local active_par2="$active_dir/${out}.par2"
      if [[ -f "$active_par2" ]]; then
        _a2_print_log "[PAR2] Existing recovery files found in active version; skipping PAR2 creation."
        par2_status="SUCCESS"
        par2_done=1
      else
        local par2_start par2_end
        par2_start=$(date +%s)
        _a2_print_log "[PAR2] Creating recovery files (resume path)..."
        local -a rel_parts=()
        local p
        for p in "${parts[@]}"; do
          rel_parts+=("$(basename "$p")")
        done
        local par2_cmd
        par2_cmd=$(printf "par2 create -r10 %q " "${out}.par2"; printf "%q " "${rel_parts[@]}"; printf "%q" "$(basename "$manifest")")
        if ! _a2_launch_job pid_par2 pgid_par2 bash -c '
          cd "$1" || exit 1
          script -q -f "$2" -c "$3"
        ' _ "$active_dir" "$par2_tty_file" "$par2_cmd"; then
          _a2_print_log "ERROR: Failed to launch PAR2 job."
          _a2_cleanup
          return 1
        fi
        local par2_exit_status=1
        if ! _a2_reap_job pid_par2 pgid_par2 par2_exit_status; then
          _a2_print_log "ERROR: Could not reliably reap PAR2 job."
          _a2_cleanup
          return 1
        fi
        if [[ -f "$par2_tty_file" ]]; then
          tr '\r' '\n' < "$par2_tty_file" | sed 's/\x1B\[[0-9;]*[JKmsu]//g' | grep -v -E '[0-9]+\.[0-9]%|Opening:|Processing:|Constructing:' >> "$logfile"
        fi
        (( abort_flag )) && { _a2_cleanup; return 1; }
        if (( par2_exit_status != 0 )); then
          par2_status="FAILED"
          _a2_cleanup
          return 1
        fi
        par2_end=$(date +%s)
        t_par2_dur=$(_a2_format_duration $((par2_end - par2_start)))
        par2_status="SUCCESS"
        par2_done=1
      fi
    fi

  else
    # ==================== MODO SINGLE FILE ====================
    _a2_print_log "[MODE] Single file"
    (( abort_flag )) && { _a2_cleanup; return 1; }

    local active_single="$active_dir/${out}.tar.zst"
    if [[ -f "$active_single" ]]; then
      _a2_print_log "[RESUME] Found existing target archive. Testing its integrity directly..."
      _a2_verify_manifest_single
      local v_status=$?
      if (( v_status == 0 )); then
        _a2_print_log "[BLAKE3] Manifest OK"
        if _a2_check_content_integrity; then
          _a2_print_log "[RESUME] Existing archive is healthy! Skipping compression stage."
          _a2_show_manifest "$active_dir/${out}.blake3"
          run_compression=0
        fi
      elif (( v_status == 10 )); then
        _a2_print_log "[WARN] Manifest not found or missing global entry."
        read -r -p "Continue without valid BLAKE3 validation? [y/N]: " response </dev/tty
        if [[ "$response" =~ ^[yY](es)?$ ]]; then
          if _a2_check_content_integrity; then
            _a2_print_log "[RESUME] Existing parts are healthy! Skipping compression stage."
            run_compression=0
          fi
        fi
      else
        _a2_print_log "ERROR: Resume validation failed due to manifest corruption, duplication, structural error, or read failure."
        _a2_cleanup
        return 1
      fi
    fi
    (( abort_flag )) && { _a2_cleanup; return 1; }

    if (( run_compression )); then
      if ! _a2_create_staging "$backup_dir"; then
        _a2_print_log "ERROR: failed to create staging directory"
        _a2_cleanup
        return 1
      fi
      local staging_manifest="$staging_dir/${out}.blake3"
      local staging_status_file="$staging_dir/.status"
      local staging_archive="$staging_dir/${out}.tar.zst"
      comp_start=$(date +%s)
      echo "# Created: $(date '+%Y-%m-%d %H:%M:%S')" > "$staging_manifest"
      echo "1" > "$staging_status_file"
      if ! _a2_launch_job pid_b3sum pgid_b3sum bash -c '
        set -o pipefail
        if b3sum < "$1" | awk -v target="$2" '\''{print $1 "  " target}'\'' >> "$3"; then
          echo "0" > "$4"
        else
          echo "1" > "$4"
        fi
      ' _ "$hash_fifo" "${out}.tar.zst" "$staging_manifest" "$staging_status_file"; then
        _a2_print_log "ERROR: Failed to launch b3sum job."
        _a2_cleanup
        return 1
      fi
      (( abort_flag )) && { _a2_cleanup; return 1; }
      if ! _a2_launch_job pid_main_pipeline pgid_main_pipeline bash -c '
        set -o pipefail
        zstd_cmd="tar -cf - -C '\''$1'\'' '\''$2'\'' | zstd -T0 -10 --long=27 -v --progress | tee '\''$4'\'' > '\''$5'\''"
        script -q -f "$3" -c "$zstd_cmd"
      ' _ "$parent_dir" "$base" "$zstd_err_file" "$hash_fifo" "$staging_archive"; then
        _a2_print_log "ERROR: Failed to launch main compression pipeline job."
        _a2_cleanup
        return 1
      fi
      local pipe_status=1
      if ! _a2_reap_job pid_main_pipeline pgid_main_pipeline pipe_status; then
        _a2_print_log "ERROR: Could not reliably reap archive creation pipeline."
        _a2_cleanup
        return 1
      fi
      if (( pipe_status != 0 )); then
        _a2_print_log "ERROR: archive creation pipeline failed (status: $pipe_status)"
        _a2_cleanup
        return 1
      fi
      (( abort_flag )) && {
        _a2_print_log "ERROR: Operation aborted."
        _a2_cleanup
        return 1
      }
      local b3sum_wait_status=1
      if ! _a2_reap_job pid_b3sum pgid_b3sum b3sum_wait_status; then
        _a2_print_log "ERROR: Could not reliably reap global BLAKE3 hashing process."
        _a2_cleanup
        return 1
      fi
      local b3sum_file_status="MISSING"
      [[ -f "$staging_status_file" ]] && b3sum_file_status=$(< "$staging_status_file")
      if [[ $b3sum_wait_status -ne 0 || "$b3sum_file_status" != "0" ]]; then
        _a2_print_log "ERROR: global BLAKE3 hashing process failed or did not complete successfully"
        _a2_cleanup
        return 1
      fi
      if ! _a2_validate_global_manifest "$staging_manifest"; then
        _a2_print_log "ERROR: BLAKE3 manifest missing or has invalid/duplicate/misplaced global archive entry"
        _a2_cleanup
        return 1
      fi
      if [[ -f "$zstd_err_file" ]]; then
        zstd_golden_line=$(tr '\r' '\n' < "$zstd_err_file" | grep -E 'GiB|MiB|B =>' | tail -n1 | sed 's/^[ \t]*//')
      fi
      if [[ -n "$zstd_golden_line" ]]; then
        _a2_print_log "--------------------------------------------------"
        _a2_print_log "            ZSTD COMPRESSION METRICS"
        _a2_print_log "--------------------------------------------------"
        _a2_print_log "$zstd_golden_line"
      fi
      _a2_print_log "[BLAKE3 MANIFEST CONTENT]"
      cat "$staging_manifest" >> "$logfile"
      cat "$staging_manifest"
      comp_end=$(date +%s)
      t_compress_dur=$(_a2_format_duration $((comp_end - comp_start)))
      compress_status="SUCCESS"
      _a2_check_content_integrity || { _a2_cleanup; return 1; }
      local par2_start par2_end
      par2_start=$(date +%s)
      _a2_print_log "[PAR2] Creating recovery files..."
      local par2_cmd
      par2_cmd=$(printf "par2 create -r10 %q %q %q" "${out}.par2" "${out}.tar.zst" "$(basename "$staging_manifest")")
      if ! _a2_launch_job pid_par2 pgid_par2 bash -c '
        cd "$1" || exit 1
        script -q -f "$2" -c "$3"
      ' _ "$staging_dir" "$par2_tty_file" "$par2_cmd"; then
        _a2_print_log "ERROR: Failed to launch PAR2 job."
        _a2_cleanup
        return 1
      fi
      local par2_exit_status=1
      if ! _a2_reap_job pid_par2 pgid_par2 par2_exit_status; then
        _a2_print_log "ERROR: Could not reliably reap PAR2 job."
        _a2_cleanup
        return 1
      fi
      if [[ -f "$par2_tty_file" ]]; then
        tr '\r' '\n' < "$par2_tty_file" | sed 's/\x1B\[[0-9;]*[JKmsu]//g' | grep -v -E '[0-9]+\.[0-9]%|Opening:|Processing:|Constructing:' >> "$logfile"
      fi
      (( abort_flag )) && { _a2_cleanup; return 1; }
      if (( par2_exit_status != 0 )); then
        par2_status="FAILED"
        _a2_print_log "ERROR: PAR2 creation failed"
        _a2_cleanup
        return 1
      fi
      par2_end=$(date +%s)
      t_par2_dur=$(_a2_format_duration $((par2_end - par2_start)))
      par2_status="SUCCESS"
      par2_done=1

      if (( use_legacy_commit )); then
        if ! _a2_commit_staging "$staging_dir" "$backup_dir"; then
          _a2_print_log "ERROR: legacy commit failed; previous backup may be partially overwritten"
          _a2_cleanup
          return 1
        fi
        _a2_cleanup_staging
      else
        if ! _a2_commit_versioned "$staging_dir" "$backup_dir"; then
          _a2_print_log "ERROR: versioned commit failed; previous backup remains active"
          _a2_cleanup
          return 1
        fi
        _a2_prune_old_versions "$backup_dir" "$keep_versions"
        staging_dir=""
        staging_committed=0
      fi
    fi

    (( abort_flag )) && { _a2_cleanup; return 1; }

    if (( ! par2_done )); then
      local active_par2="$active_dir/${out}.par2"
      if [[ -f "$active_par2" ]]; then
        _a2_print_log "[PAR2] Existing recovery files found in active version; skipping PAR2 creation."
        par2_status="SUCCESS"
        par2_done=1
      else
        local par2_start par2_end
        par2_start=$(date +%s)
        _a2_print_log "[PAR2] Creating recovery files (resume path)..."
        local par2_cmd
        par2_cmd=$(printf "par2 create -r10 %q %q %q" "${out}.par2" "${out}.tar.zst" "$(basename "$manifest")")
        if ! _a2_launch_job pid_par2 pgid_par2 bash -c '
          cd "$1" || exit 1
          script -q -f "$2" -c "$3"
        ' _ "$active_dir" "$par2_tty_file" "$par2_cmd"; then
          _a2_print_log "ERROR: Failed to launch PAR2 job."
          _a2_cleanup
          return 1
        fi
        local par2_exit_status=1
        if ! _a2_reap_job pid_par2 pgid_par2 par2_exit_status; then
          _a2_print_log "ERROR: Could not reliably reap PAR2 job."
          _a2_cleanup
          return 1
        fi
        if [[ -f "$par2_tty_file" ]]; then
          tr '\r' '\n' < "$par2_tty_file" | sed 's/\x1B\[[0-9;]*[JKmsu]//g' | grep -v -E '[0-9]+\.[0-9]%|Opening:|Processing:|Constructing:' >> "$logfile"
        fi
        (( abort_flag )) && { _a2_cleanup; return 1; }
        if (( par2_exit_status != 0 )); then
          par2_status="FAILED"
          _a2_cleanup
          return 1
        fi
        par2_end=$(date +%s)
        t_par2_dur=$(_a2_format_duration $((par2_end - par2_start)))
        par2_status="SUCCESS"
        par2_done=1
      fi
    fi
  fi

  if (( abort_flag )); then
    _a2_print_log "ERROR: Operation aborted before finalization."
    _a2_cleanup
    return 1
  fi

  t_end=$(date +%s)
  t_total=$(_a2_format_duration $((t_end - t_start)))

  {
    echo "--------------------------------------------------"
    echo "                PERFORMANCE SUMMARY"
    echo "=================================================="
    echo "• [COMPRESSION] : $t_compress_dur | Status: $compress_status"
    echo "• [TAR CHECK]   : $t_check_dur | Status: $check_status"
    echo "• [PAR2 CREATE] : $t_par2_dur | Status: $par2_status"
    echo "--------------------------------------------------"
    echo "TOTAL ELAPSED TIME: $t_total"
    echo "End Timestamp     : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=================================================="
  } | tee -a "$logfile"

  (( abort_flag )) && { _a2_print_log "ERROR: Operation aborted during finalization."; _a2_cleanup; return 1; }

  if ! _a2_cleanup; then
    return 1
  fi
  return 0
}