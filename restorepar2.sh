# Version Details: v0.5
# Change: Added versioned layout support. The utility now resolves
#   'current' symlink or the newest v<timestamp>/ subdirectory when
#   the input directory uses the v0.17 layout. Legacy flat layout is
#   still supported. Optional --version=<name> selects a specific version.
#   Fixed extractdir naming for versioned layouts.
restorepar2 () {
  local oldpwd="$PWD"
  local input="" mode="verify" full_level=0
  local explicit_version=""
  local workdir archivebase par2file mode_detected manifest
  local -a parts single par2s

  # Variáveis para controle de tempo e resumo de performance
  local t_start t_end t_total
  local t_par2_dur="0s" t_blake3_dur="0s" t_structure_dur="0s" t_extract_dur="0s"
  local par2_status="PENDING" blake3_status="SKIPPED" structure_status="SKIPPED" extract_status="SKIPPED"

  set -o pipefail
  t_start=$(date +%s)

  command -v pv >/dev/null 2>&1 || { echo "ERROR: pv not installed"; return 1; }
  command -v b3sum >/dev/null 2>&1 || { echo "ERROR: b3sum not installed"; return 1; }

  cleanup() {
    rm -f /tmp/b3_current_hash_$$ 2>/dev/null
    cd "$oldpwd" >/dev/null 2>&1
  }

  function format_duration ()
  {
      local sec=$1
      printf "%02d:%02d" $((sec / 60)) $((sec % 60))
  }

  trap cleanup RETURN INT TERM

  # ------------------------------------------------------------
  # GERENCIAMENTO DINÂMICO DE ARGUMENTOS
  # ------------------------------------------------------------
  while [[ $# -gt 0 ]]; do
    local current_arg="${1^^}"
    case "$current_arg" in
      EXTRACT)   mode="extract" ;;
      --FULL)    full_level=1 ;;
      --FULL=1)  full_level=1 ;;
      --FULL=2)  full_level=2 ;;
      # v0.5: allow selecting a specific version explicitly.
      # Accepts --version=v20260114-120000 or --version v20260114-120000.
      --VERSION=*)
        explicit_version="${1#*=}"
        ;;
      --VERSION)
        shift
        if [[ -z "${1:-}" ]]; then
          echo "ERROR: --version requires a value"; return 1
        fi
        explicit_version="$1"
        ;;
      --*)       echo "ERROR: unknown argument: $1"; return 1 ;;
      *)
        if [[ -z "$input" ]]; then input="$1"; else
          echo "ERROR: invalid or duplicate argument: $1"; return 1
        fi
        ;;
    esac
    shift
  done

  if [[ -z "$input" ]]; then
    echo "Usage: restorepar2 <backup-folder> [extract] [--full=1|2] [--version=<name>]"
    return 1
  fi

  workdir="$(realpath -e "$input" 2>/dev/null)" || { echo "ERROR: backup folder not found"; return 1; }
  [[ -d "$workdir" ]] || { echo "ERROR: input is not a directory"; return 1; }

  # ------------------------------------------------------------
  # v0.5: LAYOUT RESOLUTION
  # ------------------------------------------------------------
  #
  # Resolve the directory that actually contains the archive files.
  # Three cases:
  #   1. $workdir is itself a versioned directory (contains .part-* files
  #      or a single .tar.zst directly) -> use it.
  #   2. $workdir has 'current' (symlink or dir) -> use realpath of it.
  #   3. $workdir has v<timestamp>/ subdirectories -> use the newest
  #      (lexicographic sort works with the YYYYMMDD-HHMMSS format).
  # An explicit --version=<name> overrides 2 and 3.
  #
  local active_dir=""
  local layout_detected=""

  # Case 1: is $workdir already a version directory or legacy flat?
  local probe_parts probe_single
  shopt -s nullglob
  probe_parts=( "$workdir"/*.tar.zst.part-* )
  probe_single=( "$workdir"/*.tar.zst )
  shopt -u nullglob

  if (( ${#probe_parts[@]} > 0 )) || (( ${#probe_single[@]} > 0 )); then
    active_dir="$workdir"
    # Distinguish "flat legacy" from "already a version dir" by
    # checking whether $workdir's basename looks like a version.
    local wb
    wb=$(basename "$workdir")
    if [[ "$wb" =~ ^v[0-9]{8}-[0-9]{6}(-[0-9]+)?$ ]]; then
      layout_detected="versioned (explicit version dir)"
    else
      layout_detected="legacy (flat)"
    fi
  fi

  # Case 2/3: if not resolved yet, look for 'current' or v* subdirs.
  if [[ -z "$active_dir" ]]; then
    if [[ -n "$explicit_version" ]]; then
      local candidate="$workdir/$explicit_version"
      if [[ -d "$candidate" ]]; then
        active_dir=$(realpath -e "$candidate" 2>/dev/null) || active_dir="$candidate"
        layout_detected="versioned (explicit --version=$explicit_version)"
      else
        echo "ERROR: --version=$explicit_version not found in $workdir"
        return 1
      fi
    elif [[ -L "$workdir/current" ]] || [[ -d "$workdir/current" ]]; then
      active_dir=$(realpath -e "$workdir/current" 2>/dev/null) || active_dir="$workdir/current"
      layout_detected="versioned (current symlink)"
    else
      # Try newest v<timestamp>/
      local -a version_dirs
      shopt -s nullglob
      version_dirs=( "$workdir"/v[0-9]*-[0-9]* )
      shopt -u nullglob

      if (( ${#version_dirs[@]} > 0 )); then
        local newest=""
        local v
        while IFS= read -r v; do
          [[ -n "$v" ]] && newest="$v"
        done < <(printf '%s\n' "${version_dirs[@]}" | sort)
        if [[ -n "$newest" ]]; then
          active_dir=$(realpath -e "$newest" 2>/dev/null) || active_dir="$newest"
          layout_detected="versioned (newest v*: $(basename "$newest"))"
        fi
      fi
    fi
  fi

  if [[ -z "$active_dir" ]]; then
    echo "ERROR: no archive files found in $workdir (no current/, no v*/, no flat files)"
    return 1
  fi

  echo "[LAYOUT] $layout_detected"
  echo "[LAYOUT] Active directory: $active_dir"

  cd "$active_dir" || return 1

  # ------------------------------------------------------------
  # DETECT ARCHIVE MODE & MANIFEST
  # ------------------------------------------------------------
  shopt -s nullglob
  parts=(./*.tar.zst.part-*)
  single=(./*.tar.zst)
  par2s=(./*.par2)
  shopt -u nullglob

  [[ ${#par2s[@]} -gt 0 ]] || { echo "ERROR: no PAR2 files found in $active_dir"; return 1; }
  par2file="${par2s[0]}"

  if [[ ${#parts[@]} -gt 0 ]]; then
    archivebase="$(basename "${parts[0]}")"
    archivebase="${archivebase%.tar.zst.part-*}"
    mode_detected="split"
  elif [[ ${#single[@]} -gt 0 ]]; then
    archivebase="$(basename "${single[0]}" .tar.zst)"
    mode_detected="single"
  else
    echo "ERROR: no archive files found"; return 1
  fi

  manifest="${archivebase}.blake3"

  archive_stream() {
    if [[ "$mode_detected" == "split" ]]; then pv "${parts[@]}"; else pv "${single[0]}"; fi
  }

  echo "=============================="
  echo "Restore/Test Session | Mode: ${mode^^}"
  echo "Archive: $archivebase ($mode_detected)"
  echo "Active dir: $active_dir"
  echo "=============================="

  # ------------------------------------------------------------
  # [FASE 1] PAR2 VERIFY / REPAIR
  # ------------------------------------------------------------
  local par2_start par2_end
  par2_start=$(date +%s)
  echo -e "\n[1] Executing PAR2 block integrity check..."
  if ! par2 verify "$par2file"; then
    echo -e "\n[PAR2] Verification failed! Attempting to repair blocks..."
    if ! par2 repair "$par2file"; then
      echo "ERROR: Data recovery/repair failed."; return 1
    fi
    par2_status="REPAIRED"
  else
    par2_status="SUCCESS"
  fi
  par2_end=$(date +%s)
  t_par2_dur=$(format_duration $((par2_end - par2_start)))

  # ------------------------------------------------------------
  # HELPER PARA O MANIFESTO MULTI-LINHA
  # ------------------------------------------------------------
  verify_blake3_match() {
    [[ -f "$manifest" ]] || return 1
    local stored current target_pattern

    target_pattern="${archivebase}.tar.zst"

    stored=$(grep -E " ${target_pattern}$" "$manifest" | awk '{print $1}')

    if [[ -z "$stored" ]]; then
       stored=$(awk '!/^#/ {print $1; exit}' "$manifest")
    fi

    current=$(cat /tmp/b3_current_hash_$$ 2>/dev/null)

    echo -e "\n[BLAKE3] Stored Stream : $stored"
    echo "[BLAKE3] Current Stream: $current"
    [[ "$stored" == "$current" ]]
  }

  # ------------------------------------------------------------
  # [FASE 2] EXTRACTION OU VERIFY MODE
  # ------------------------------------------------------------
  if [[ "$mode" == "extract" ]]; then
    # ==================== MODO EXTRAÇÃO ====================
    local extract_start extract_end
    # v0.5: compute extractdir based on the backup root, not the
    # resolved active_dir, so the name is stable and predictable.
    # If $workdir is /path/to/mydata-bak, extractdir is /path/to/mydata-restored.
    local backup_root="$workdir"
    # If user passed a version dir directly, strip it back to the -bak parent.
    if [[ "$(basename "$backup_root")" =~ ^v[0-9]{8}-[0-9]{6}(-[0-9]+)?$ ]]; then
      backup_root="$(dirname "$backup_root")"
    fi
    local extractdir="${backup_root%-bak}-restored"
    # v0.5: include the version name in the extract dir when restoring
    # a non-current version, to avoid overwriting a previous extraction.
    local active_basename
    active_basename="$(basename "$active_dir")"
    if [[ "$active_basename" =~ ^v[0-9]{8}-[0-9]{6}(-[0-9]+)?$ ]]; then
      if [[ -L "$backup_root/current" ]] && [[ "$(readlink "$backup_root/current" 2>/dev/null)" != "$active_basename" ]]; then
        extractdir="${extractdir}.${active_basename}"
      fi
    fi

    echo -e "\n[2] Extracting archive with real-time BLAKE3 hashing..."
    mkdir -p "$extractdir" || return 1

    extract_start=$(date +%s)
    if ! archive_stream \
        | tee >(b3sum | awk '{print $1}' > /tmp/b3_current_hash_$$) \
        | zstd -dc \
        | tar -xf - -C "$extractdir"; then
      echo "ERROR: extraction pipeline failed"; return 1
    fi
    extract_end=$(date +%s)
    t_extract_dur=$(format_duration $((extract_end - extract_start)))
    extract_status="SUCCESS"

    if [[ -f "$manifest" ]]; then
      if verify_blake3_match; then
        blake3_status="SUCCESS"
      else
        echo "CRITICAL ERROR: Extracted data bit-mismatch against BLAKE3 manifest!"; return 1
      fi
    else
      blake3_status="NO MANIFEST"
    fi

  else
    # ==================== MODO VERIFICAÇÃO ====================
    if (( full_level > 0 )); then
      local struct_start struct_end
      struct_start=$(date +%s)

      if [[ -f "$manifest" ]]; then
        echo -e "\n[2] [--FULL=1] Testing Zstd Integrity + Real-time BLAKE3 verification..."
        if ! archive_stream \
            | tee >(b3sum | awk '{print $1}' > /tmp/b3_current_hash_$$) \
            | zstd -t; then
          echo "ERROR: zstd stream is broken"; return 1
        fi

        if verify_blake3_match; then
          blake3_status="SUCCESS"
          structure_status="PASSED (BY BLAKE3)"
        else
          echo "ERROR: BLAKE3 cryptographic mismatch!"; return 1
        fi

        if (( full_level == 2 )); then
          echo -e "\n[3] [--FULL=2] Executing exhaustive TAR structure verification..."
          if ! archive_stream | zstd -dc | tar -tf - >/dev/null; then
            echo "ERROR: tar structure is invalid"; return 1
          fi
          structure_status="SUCCESS (FULL TEST)"
        fi
      else
        echo -e "\n[WARN] BLAKE3 manifest not found. Engaging automatic fallback to TAR check."
        blake3_status="NOT FOUND"

        echo -e "\n[2] Testing zstd compression integrity..."
        if ! archive_stream | zstd -t; then echo "ERROR: zstd failed"; return 1; fi

        echo -e "\n[3] Testing tar internal structure..."
        if ! archive_stream | zstd -dc | tar -tf - >/dev/null; then echo "ERROR: tar failed"; return 1; fi
        structure_status="SUCCESS (TAR FALLBACK)"
      fi

      struct_end=$(date +%s)
      t_structure_dur=$(format_duration $((struct_end - struct_start)))
    else
      echo -e "\n[INFO] Skipping structural tests (Files are physically healthy)."
    fi
  fi

  # ------------------------------------------------------------
  # EXIBIÇÃO DO RESUMO DE PERFORMANCE FINAL
  # ------------------------------------------------------------
  t_end=$(date +%s)
  t_total=$(format_duration $((t_end - t_start)))

  echo -e "\n=================================================="
  echo "                PERFORMANCE SUMMARY"
  echo "=================================================="
  echo "• [PAR2 CHECK]  : $t_par2_dur | Status: $par2_status"
  echo "• [BLAKE3 CHECK]: ${t_structure_dur:-00:00} | Status: $blake3_status"
  echo "• [STRUCT CHECK]: ${t_structure_dur:-00:00} | Status: $structure_status"
  echo "• [EXTRACTION]  : $t_extract_dur | Status: $extract_status"
  echo "--------------------------------------------------"
  echo "TOTAL ELAPSED TIME: $t_total"
  echo "=================================================="
  echo -e "SESSION SUCCESSFUL\n=================================================="
}