# Version Details: v0.15
# Fix: Asynchronous BLAKE3 manifest generation synchronized without arbitrary sleep.
archivepar2 () {
  local oldpwd="$PWD"
  local arch="$1"; shift

  local maxsize="2G" single_mode=0 fast_mode=0 out base dir parent_dir manifest logfile
  local -a parts

  # Variáveis para controle de tempo e resumo
  local t_start t_end t_total
  local t_compress_dur="0s" t_check_dur="0s" t_par2_dur="0s"
  local compress_status="SKIPPED" check_status="SKIPPED" par2_status="PENDING"
  local zstd_golden_line=""

  set -o pipefail

  t_start=$(date +%s)

  while [[ $# -gt 0 ]]; do
    local current_arg="${1^^}"
    case "$current_arg" in
      --SINGLE) single_mode=1 ;;
      --FAST)    fast_mode=1 ;;
      *)
        if [[ "$current_arg" =~ ^[1-9]+[0-9]*[KMGTP]$ ]]; then
          maxsize="$current_arg"
        else
          echo "ERROR: invalid argument: $1"
          return 1
        fi
        ;;
    esac
    shift
  done

  cleanup() {
    rm -f /tmp/zstd_err_$$ /tmp/par2_tty_$$ /tmp/b3sum_status_$$ 2>/dev/null
    cd "$oldpwd" >/dev/null 2>&1
  }
  trap cleanup RETURN INT TERM

  if [[ -z "$arch" ]]; then
    echo "Error: no input folder provided"
    return 1
  fi

  arch="$(realpath -e "$arch")" || {
    echo "Error: path not found"
    return 1
  }

  base="$(basename "$arch")"
  parent_dir="$(dirname "$arch")"

  out=$(printf "%s" "$base" \
    | tr '[:upper:]' '[:lower:]' \
    | tr ' ' '_' \
    | sed 's/[^a-z0-9_-]//g')

  dir="${out}-bak"
  manifest="${out}.blake3"
  logfile="${out}.log"

  mkdir -p "$dir" || return 1

  local backup_dir="$(realpath "$dir")"
  cd "$backup_dir" || return 1

  # Inicializa o arquivo de log de forma limpa
  echo "==================================================" > "$logfile"
  echo "             ARCHIVEPAR2 SESSION LOG             " >> "$logfile"
  echo "==================================================" >> "$logfile"
  echo "Start Timestamp : $(date '+%Y-%m-%d %H:%M:%S')" >> "$logfile"
  echo "Source Path     : $arch" >> "$logfile"
  echo "Output Base Name: $out" >> "$logfile"
  echo "Target Directory: $backup_dir" >> "$logfile"
  echo "Arguments Used  : Single Mode=$single_mode | Fast Mode=$fast_mode | Max Size=$maxsize" >> "$logfile"
  echo "--------------------------------------------------" >> "$logfile"

  print_log() {
    echo -e "$@" | tee -a "$logfile"
  }

  print_log "=============================="
  print_log "Archiving: $arch"
  print_log "Working dir: $PWD"
  print_log "Output base: $out"
  print_log "=============================="

  format_duration() {
    local sec=$1
    printf "%02d:%02d" $((sec / 60)) $((sec % 60))
  }

  check_content_integrity() {
    if (( fast_mode )); then
      check_status="PASSED (FAST MODE)"
      return 0
    fi

    local chk_start chk_end
    chk_start=$(date +%s)

    print_log "=============================="
    print_log "[TAR CHECK] Checking content integrity against origin..."

    if (( single_mode )); then
        ( cd "$parent_dir" && zstd -dc --progress "$backup_dir/$out.tar.zst" | tar --diff -f - )
    else
        ( cd "$parent_dir" && cat "${parts[@]/#/$backup_dir/}" | zstd -dc --progress | tar --diff -f - )
    fi

    local status=$?
    chk_end=$(date +%s)
    t_check_dur=$(format_duration $((chk_end - chk_start)))

    if [ $status -eq 0 ]; then
        print_log "[TAR CHECK] Content Successfully Validated (100% Identical)."
        print_log "=============================="
        check_status="SUCCESS"
    else
        print_log "ERROR: Content verification failed!"
        check_status="FAILED"
    fi
    return $status
  }

  update_parts_array() {
    shopt -s nullglob
    parts=( "${out}.tar.zst.part-"* )
    shopt -u nullglob
  }

  show_manifest() {
    [[ -f "$manifest" ]] || return
    print_log "[BLAKE3 MANIFEST CONTENT]"
    cat "$manifest" >> "$logfile"
    cat "$manifest"
  }

  verify_manifest_single() {
    local stored current
    [[ -f "$manifest" ]] || return 2

    stored=$(grep " ${out}.tar.zst$" "$manifest" | awk '{print $1}')
    [[ -z "$stored" ]] && stored=$(awk '!/^#/ {print $1; exit}' "$manifest")

    current=$(b3sum "${out}.tar.zst" | awk '{print $1}')

    print_log "[BLAKE3] Stored Global : $stored"
    print_log "[BLAKE3] Current Stream: $current"
    [[ "$stored" == "$current" ]]
  }

  verify_manifest_split() {
    local stored current
    [[ -f "$manifest" ]] || return 2

    stored=$(grep " ${out}.tar.zst$" "$manifest" | awk '{print $1}')
    [[ -z "$stored" ]] && stored=$(awk '!/^#/ {print $1; exit}' "$manifest")

    if command -v pv >/dev/null 2>&1; then
      current=$(cat "${parts[@]}" | pv -N "Validating Split Files" -p -t -e -r -b | b3sum | awk '{print $1}')
    else
      current=$(cat "${parts[@]}" | b3sum | awk '{print $1}')
    fi

    print_log "[BLAKE3] Stored Global : $stored"
    print_log "[BLAKE3] Current Stream: $current"
    [[ "$stored" == "$current" ]]
  }

  # ------------------------------------------------------------
  # EXECUÇÃO DO FLUXO (SPLIT MODE OU SINGLE MODE)
  # ------------------------------------------------------------
  local run_compression=1
  local comp_start comp_end
  local response

  if [[ "$single_mode" -eq 0 && -n "$maxsize" ]]; then
    # ==================== MODO SPLIT ====================
    print_log "[MODE] Split mode ($maxsize)"
    update_parts_array

    if [[ ${#parts[@]} -gt 0 ]]; then
      print_log "[RESUME] Found existing split parts. Testing their integrity directly..."
      if verify_manifest_split; then
        print_log "[BLAKE3] Manifest OK"
        if check_content_integrity; then
          print_log "[RESUME] Existing parts are healthy! Skipping compression stage."
          show_manifest
          run_compression=0
        fi
      elif [[ $? -eq 2 ]]; then
        print_log "[WARN] Manifest not found."
        read -r -p "Continue without BLAKE3 validation? [y/N]: " response </dev/tty
        if [[ "$response" =~ ^[yY](es)?$ ]]; then
          if check_content_integrity; then
            print_log "[RESUME] Existing parts are healthy! Skipping compression stage."
            run_compression=0
          fi
        fi
      else
        print_log "[BLAKE3] Manifest mismatch!"
        print_log "\n[WARN] Existing parts are corrupted or outdated."
        read -r -p "Do you want to DELETE them and re-compress from scratch? [y/N]: " response </dev/tty
        if [[ "$response" =~ ^[yY](es)?$ ]]; then
          print_log "Cleaning old files..."
          rm -f "${out}.tar.zst.part-"* "${out}.par2"* "$manifest" "$logfile" 2>/dev/null
          update_parts_array
          echo "==================================================" > "$logfile"
          echo "             ARCHIVEPAR2 SESSION LOG             " >> "$logfile"
          echo "==================================================" >> "$logfile"
        else
          print_log "Operation aborted by user. Existing files were preserved."
          return 1
        fi
      fi
    fi

    if (( run_compression )); then
      comp_start=$(date +%s)
      echo "# Created: $(date '+%Y-%m-%d %H:%M:%S')" > "$manifest"

      tar -cf - -C "$parent_dir" "$base" \
      | zstd -T0 -10 --long=27 -v --progress 2> >(tee /tmp/zstd_err_$$ >&2) \
      | tee >(
          set -o pipefail
          b3sum | awk -v f="${out}.tar.zst" '{print $1 "  " f}' >> "$manifest"
          echo $? > /tmp/b3sum_status_$$
        ) \
      | split -d -a 3 -b "$maxsize" - "${out}.tar.zst.part-"

      local pipe_status=( "${PIPESTATUS[@]}" )
      local pid_b3sum=$!

      wait "$pid_b3sum"
      local b3sum_exit=0
      [[ -f /tmp/b3sum_status_$$ ]] && b3sum_exit=$(< /tmp/b3sum_status_$$)

      [[ ${pipe_status[0]} -eq 0 && ${pipe_status[1]} -eq 0 && ${pipe_status[3]} -eq 0 && $b3sum_exit -eq 0 ]] || {
        print_log "ERROR: archive pipeline or global hashing failed"
        return 1
      }
      [[ -s "$manifest" ]] || { print_log "ERROR: BLAKE3 manifest was not generated"; return 1; }

      zstd_golden_line=$(tr '\r' '\n' < /tmp/zstd_err_$$ | grep -E 'GiB|MiB|B =>' | tail -n1 | sed 's/^[ \t]*//')

      if [[ -n "$zstd_golden_line" ]]; then
        print_log "--------------------------------------------------"
        print_log "            ZSTD COMPRESSION METRICS"
        print_log "--------------------------------------------------"
        print_log "$zstd_golden_line"
      fi

      print_log "\n[SPLIT MODE] Collecting split parts and hashing individual files..."
      update_parts_array
      [[ ${#parts[@]} -gt 0 ]] || { print_log "ERROR: no split parts found"; return 1; }

      if command -v pv >/dev/null 2>&1; then
        for part in "${parts[@]}"; do
          local p_size=$(stat -c%s "$part")
          local hash=$(pv -N "Hashing $part" -s "$p_size" -p -t -e -r "$part" | b3sum | awk '{print $1}')
          echo "$hash  $part" >> "$manifest"
        done
      else
        b3sum "${parts[@]}" >> "$manifest"
      fi

      show_manifest

      comp_end=$(date +%s)
      t_compress_dur=$(format_duration $((comp_end - comp_start)))
      compress_status="SUCCESS"

      check_content_integrity || return 1
    fi

    local par2_start par2_end
    par2_start=$(date +%s)
    print_log "[PAR2] Creating recovery files..."

    local par2_cmd
    par2_cmd=$(printf "par2 create -r10 %q " "${out}.par2"; printf "%q " "${parts[@]}"; printf "%q" "$manifest")
    
    script -q -f /tmp/par2_tty_$$ -c "$par2_cmd"
    if [[ $? -ne 0 ]]; then par2_status="FAILED"; return 1; fi

    tr -d '\r' < /tmp/par2_tty_$$ | grep -v -E '[0-9]+\.[0-9]%|Opening:|Processing:|Constructing:' >> "$logfile"

    par2_end=$(date +%s)
    t_par2_dur=$(format_duration $((par2_end - par2_start)))
    par2_status="SUCCESS"

  else
    # ==================== MODO SINGLE FILE ====================
    print_log "[MODE] Single file"

    if [[ -f "${out}.tar.zst" ]]; then
      print_log "[RESUME] Found existing target archive. Testing its integrity directly..."
      if verify_manifest_single; then
        print_log "[BLAKE3] Manifest OK"
        if check_content_integrity; then
          print_log "[RESUME] Existing archive is healthy! Skipping compression stage."
          show_manifest
          run_compression=0
        fi
      elif [[ $? -eq 2 ]]; then
        print_log "[WARN] Manifest not found."
        read -r -p "Continue without BLAKE3 validation? [y/N]: " response </dev/tty
        if [[ "$response" =~ ^[yY](es)?$ ]]; then
          if check_content_integrity; then
            print_log "[RESUME] Existing archive is healthy! Skipping compression stage."
            run_compression=0
          fi
        fi
      else
        print_log "[BLAKE3] Manifest mismatch!"
        print_log "\n[WARN] Existing archive is corrupted or outdated."
        read -r -p "Do you want to DELETE it and re-compress from scratch? [y/N]: " response </dev/tty
        if [[ "$response" =~ ^[yY](es)?$ ]]; then
          print_log "Cleaning old files..."
          rm -f "${out}.tar.zst" "${out}.par2"* "$manifest" "$logfile" 2>/dev/null
          echo "==================================================" > "$logfile"
          echo "             ARCHIVEPAR2 SESSION LOG             " >> "$logfile"
          echo "==================================================" >> "$logfile"
        else
          print_log "Operation aborted by user. Existing files were preserved."
          return 1
        fi
      fi
    fi

    if (( run_compression )); then
      comp_start=$(date +%s)
      echo "# Created: $(date '+%Y-%m-%d %H:%M:%S')" > "$manifest"

      tar -cf - -C "$parent_dir" "$base" \
      | zstd -T0 -10 --long=27 -v --progress 2> >(tee /tmp/zstd_err_$$ >&2) \
      | tee >(
          set -o pipefail
          b3sum | awk -v f="${out}.tar.zst" '{print $1 "  " f}' >> "$manifest"
          echo $? > /tmp/b3sum_status_$$
        ) \
      > "${out}.tar.zst"

      local pipe_status=( "${PIPESTATUS[@]}" )
      local pid_b3sum=$!

      wait "$pid_b3sum"
      local b3sum_exit=0
      [[ -f /tmp/b3sum_status_$$ ]] && b3sum_exit=$(< /tmp/b3sum_status_$$)

      [[ ${pipe_status[0]} -eq 0 && ${pipe_status[1]} -eq 0 && $b3sum_exit -eq 0 ]] || {
        print_log "ERROR: archive creation or global hashing failed"
        return 1
      }
      [[ -s "$manifest" ]] || { print_log "ERROR: BLAKE3 manifest was not generated"; return 1; }

      zstd_golden_line=$(tr '\r' '\n' < /tmp/zstd_err_$$ | grep -E 'GiB|MiB|B =>' | tail -n1 | sed 's/^[ \t]*//')

      if [[ -n "$zstd_golden_line" ]]; then
        print_log "--------------------------------------------------"
        print_log "            ZSTD COMPRESSION METRICS"
        print_log "--------------------------------------------------"
        print_log "$zstd_golden_line"
      fi

      show_manifest 

      comp_end=$(date +%s)
      t_compress_dur=$(format_duration $((comp_end - comp_start)))
      compress_status="SUCCESS"

      check_content_integrity || return 1
    fi

    local par2_start par2_end
    par2_start=$(date +%s)
    print_log "\n[PAR2] Creating recovery files..."

    script -q -f /tmp/par2_tty_$$ -c 'par2 create -r10 "'"${out}.par2"'" "'"${out}.tar.zst"'" "'"$manifest"'"'
    if [[ $? -ne 0 ]]; then par2_status="FAILED"; return 1; fi

    tr -d '\r' < /tmp/par2_tty_$$ | grep -v -E '[0-9]+\.[0-9]%|Opening:|Processing:|Constructing:' >> "$logfile"

    par2_end=$(date +%s)
    t_par2_dur=$(format_duration $((par2_end - par2_start)))
    par2_status="SUCCESS"
  fi


  # ------------------------------------------------------------
  # EXIBIÇÃO E GRAVAÇÃO DO RESUMO DE PERFORMANCE FINAL
  # ------------------------------------------------------------
  t_end=$(date +%s)
  t_total=$(format_duration $((t_end - t_start)))

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
}