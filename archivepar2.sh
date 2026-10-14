# Version Details: v0.16
# Fix: Post-SIGKILL group confirmation in _a2_launch_job failure path; orphaned PGIDs registered in _a2_orphan_pgids array so _a2_cleanup can retry termination.
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

  local _a2_orig_pipefail=0
  [[ -o pipefail ]] && _a2_orig_pipefail=1
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
          echo "ERROR: invalid argument: $1" >&2
          (( _a2_orig_pipefail )) || set +o pipefail
          return 1
        fi
        ;;
    esac
    shift
  done

  _a2_init_fail() {
    (( _a2_orig_pipefail )) || set +o pipefail
    cd "$oldpwd" >/dev/null 2>&1
    return 1
  }

  local status_file
  status_file=$(mktemp /tmp/archivepar2_status_XXX.dat) || {
    echo "ERROR: failed to create temporary status file" >&2
    _a2_init_fail
    return 1
  }

  local fifo_dir
  fifo_dir=$(mktemp -d /tmp/archivepar2_fifo_dir_XXX) || {
    echo "ERROR: failed to create temporary FIFO directory" >&2
    rm -f "$status_file"
    _a2_init_fail
    return 1
  }

  local hash_fifo="$fifo_dir/hash.fifo"
  mkfifo "$hash_fifo" || {
    echo "ERROR: failed to create FIFO" >&2
    rm -rf "$fifo_dir" "$status_file"
    _a2_init_fail
    return 1
  }

  local zstd_err_file
  zstd_err_file=$(mktemp /tmp/archivepar2_zstd_err_XXX.log) || {
    echo "ERROR: failed to create zstd error temp file" >&2
    rm -rf "$fifo_dir" "$status_file"
    _a2_init_fail
    return 1
  }

  local par2_tty_file
  par2_tty_file=$(mktemp /tmp/archivepar2_par2_tty_XXX.log) || {
    echo "ERROR: failed to create par2 tty temp file" >&2
    rm -f "$zstd_err_file"
    rm -rf "$fifo_dir" "$status_file"
    _a2_init_fail
    return 1
  }

  local resume_out_file
  resume_out_file=$(mktemp /tmp/archivepar2_resume_out_XXX.dat) || {
    echo "ERROR: failed to create resume output temp file" >&2
    rm -f "$zstd_err_file" "$par2_tty_file" "$status_file"
    rm -rf "$fifo_dir"
    _a2_init_fail
    return 1
  }

  local abort_flag=0
  local pgid_b3sum="" pid_b3sum=""
  local pgid_main_pipeline="" pid_main_pipeline=""
  local pgid_par2="" pid_par2=""
  local pgid_helper="" pid_helper=""
  local pgid_check="" pid_check=""
  local pgid_resume="" pid_resume=""
  local _a2_cleaned=0
  local -a _a2_orphan_pgids=()

  local _a2_old_trap_int _a2_old_trap_term
  _a2_old_trap_int=$(trap -p INT)
  _a2_old_trap_term=$(trap -p TERM)

  _a2_restore_traps() {
    if [[ -n "$_a2_old_trap_int" ]]; then eval "$_a2_old_trap_int"; else trap - INT; fi
    if [[ -n "$_a2_old_trap_term" ]]; then eval "$_a2_old_trap_term"; else trap - TERM; fi
  }

  _a2_cleanup() {
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

    # Processos cujo grupo não pôde ser confirmado encerrado durante _a2_launch_job (falha de lançamento)
    # são registrados em _a2_orphan_pgids e tentados aqui com o mesmo protocolo TERM→poll→KILL.
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
            sleep 0.1
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
      _a2_handle_signal _a2_init_fail _a2_restore_traps _a2_launch_job _a2_reap_job 2>/dev/null || true
    else
      return 1
    fi
  }

  _a2_handle_signal() {
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

  echo "==================================================" > "$logfile"
  echo "             ARCHIVEPAR2 SESSION LOG             " >> "$logfile"
  echo "==================================================" >> "$logfile"
  echo "Start Timestamp : $(date '+%Y-%m-%d %H:%M:%S')" >> "$logfile"
  echo "Source Path     : $arch" >> "$logfile"
  echo "Output Base Name: $out" >> "$logfile"
  echo "Target Directory: $backup_dir" >> "$logfile"
  echo "Arguments Used  : Single Mode=$single_mode | Fast Mode=$fast_mode | Max Size=$maxsize" >> "$logfile"
  echo "--------------------------------------------------" >> "$logfile"

  _a2_print_log() {
    echo -e "$@" | tee -a "$logfile"
  }

  _a2_format_duration() {
    local sec=$1
    printf "%02d:%02d" $((sec / 60)) $((sec % 60))
  }

  # Lançamento atômico com protocolo de handshake bidirecional (ACK), pré-validação estrita de PGID ativo e limpeza com espera limitada
  _a2_launch_job() {
    local _a2_target_pid="$1"
    local _a2_target_pgid="$2"
    shift 2

    local _a2_pgid_file _a2_ack_file
    _a2_pgid_file=$(mktemp "$fifo_dir/pgid_XXX.dat") || return 1
    _a2_ack_file=$(mktemp -u "$fifo_dir/ack_XXX.dat") || { rm -f "$_a2_pgid_file"; return 1; }

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

    # Validação estrita sem sanitização: o valor deve ser não-vazio, puramente numérico e pertencer a um grupo ativo.
    # Defesa em profundidade: a checagem kill -0 mitiga (embora não elimine teoricamente o risco POSIX de TOCTOU)
    # o disparo acidental de sinais para grupos reciclados.
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
      # Limpeza simétrica e com espera limitada para qualquer falha de lançamento:
      # - Remove o arquivo ACK, impedindo que o processo interno chegue a executar o payload.
      # - Envia SIGTERM ao wrapper child_pid e, somente se o grupo tiver sido previamente validado, ao grupo.
      # - Executa espera limitada de até 20 iterações (1s) e escala para SIGKILL se necessário.
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

      # Confirmação pós-SIGKILL: verificar se o grupo também terminou.
      # Se o PGID foi validado e o grupo ainda está ativo após o SIGKILL ao wrapper,
      # aguardamos um intervalo limitado antes de registrar como órfão.
      if (( _a2_g_active )); then
        local _a2_conf_c=0
        while kill -0 -- -"${_a2_captured_pgid}" 2>/dev/null && (( _a2_conf_c < 10 )); do
          sleep 0.05
          (( ++_a2_conf_c ))
        done
        if kill -0 -- -"${_a2_captured_pgid}" 2>/dev/null; then
          # Grupo ainda ativo após SIGKILL e período de tolerância.
          # Registra o PGID para que _a2_cleanup possa tentar encerrar o grupo na limpeza geral.
          _a2_orphan_pgids+=("${_a2_captured_pgid}")
          echo "WARNING: process group ${_a2_captured_pgid} may still be active after launch failure cleanup" >&2
        fi
      fi
      return 1
    fi

    eval "$_a2_target_pid=$_a2_child_pid"
    eval "$_a2_target_pgid=$_a2_captured_pgid"
    return 0
  }

  # Helper estrito com separação de interrupção de wait e validação fail-closed
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
          # Processo não é filho deste shell ou o status já foi perdido.
          # Fail-closed: não é possível confirmar o recolhimento seguro.
          _a2_reap_confirmed=0
          break
        fi

        # Distinção crítica: verificar se o processo ainda está vivo.
        # Se _a2_r_pid ainda estiver em execução, o wait foi apenas interrompido por um sinal.
        if kill -0 "$_a2_r_pid" 2>/dev/null; then
          if (( abort_flag == 1 )); then
            # Se a operação estiver em aborto, assegura que o sinal de término foi emitido ao grupo ativo
            if kill -0 -- -"${_a2_r_pgid}" 2>/dev/null; then
              kill -TERM -- -"${_a2_r_pgid}" 2>/dev/null || true
            fi
          fi
          (( ++_a2_retry_count ))
          sleep 0.05
          continue
        fi

        # Processo _a2_r_pid terminou e não está mais ativo:
        # _a2_r_st reflete o status final real obtido por wait (ex: código de saída ou 128+SIG).
        _a2_reap_confirmed=1
        break
      fi
    done

    # Verificação e encerramento seguro de quaisquer processos remanescentes no grupo
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
        # Grupo não encerrou nem após SIGKILL; falha grave no recolhimento
        _a2_reap_confirmed=0
      fi
    fi

    # Se foi necessário recorrer a SIGKILL para exterminar processos remanescentes que não encerraram
    # dentro do prazo de tolerância, isso representa uma falha operacional / anomalia no pipeline.
    # Por consistência de contrato fail-closed, falha é retornada.
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

    local status=0
    if (( single_mode )); then
        _a2_launch_job pid_check pgid_check bash -c '
          set -o pipefail
          cd "$1" || exit 1
          zstd -dc --progress "$2/$3.tar.zst" | tar --diff -f -
        ' _ "$parent_dir" "$backup_dir" "$out"
    else
        _a2_launch_job pid_check pgid_check bash -c '
          set -o pipefail
          cd "$1" || exit 1
          cat "${@:3}" | zstd -dc --progress | tar --diff -f -
        ' _ "$parent_dir" "$backup_dir" "${parts[@]/#/$backup_dir/}"
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
    local orig_nullglob=0
    [[ -o nullglob ]] && orig_nullglob=1
    shopt -s nullglob
    parts=( "${out}.tar.zst.part-"* )
    (( orig_nullglob )) || shopt -u nullglob
  }

  _a2_show_manifest() {
    [[ -f "$manifest" ]] || return
    _a2_print_log "[BLAKE3 MANIFEST CONTENT]"
    cat "$manifest" >> "$logfile"
    cat "$manifest"
  }

  _a2_verify_manifest_single() {
    local stored current
    [[ -f "$manifest" ]] || return 10

    stored=$(awk -v target="${out}.tar.zst" '
      BEGIN { count = 0; malformed_pos = 0; invalid = 0; valid_hash = "" }
      $0 ~ /^#/ { next }
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
        if (malformed_pos) exit 11;
        if (count == 0) exit 10;
        if (count > 1 || invalid) exit 11;
        print valid_hash;
        exit 0;
      }
    ' "$manifest")
    local awk_status=$?
    
    if (( awk_status == 10 )); then
      return 10
    elif (( awk_status == 11 )); then
      _a2_print_log "ERROR: Manifest contains duplicate, malformed, or misplaced global entry for target."
      return 3
    elif (( awk_status != 0 )); then
      _a2_print_log "ERROR: Failed to read or parse manifest file due to I/O or syntax error."
      return 4
    fi
    [[ -z "$stored" ]] && return 10

    : > "$resume_out_file"
    if ! _a2_launch_job pid_resume pgid_resume bash -c '
      set -o pipefail
      b3sum "$1" | awk '\''{print $1}'\'' > "$2"
    ' _ "${out}.tar.zst" "$resume_out_file"; then
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

    current=$(< "$resume_out_file")
    [[ -n "$current" ]] || return 4

    _a2_print_log "[BLAKE3] Stored Global : $stored"
    _a2_print_log "[BLAKE3] Current Stream: $current"
    [[ "$stored" == "$current" ]]
  }

  _a2_verify_manifest_split() {
    local stored current
    [[ -f "$manifest" ]] || return 10

    stored=$(awk -v target="${out}.tar.zst" '
      BEGIN { count = 0; malformed_pos = 0; invalid = 0; valid_hash = "" }
      $0 ~ /^#/ { next }
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
        if (malformed_pos) exit 11;
        if (count == 0) exit 10;
        if (count > 1 || invalid) exit 11;
        print valid_hash;
        exit 0;
      }
    ' "$manifest")
    local awk_status=$?

    if (( awk_status == 10 )); then
      return 10
    elif (( awk_status == 11 )); then
      _a2_print_log "ERROR: Manifest contains duplicate, malformed, or misplaced global entry for target."
      return 3
    elif (( awk_status != 0 )); then
      _a2_print_log "ERROR: Failed to read or parse manifest file due to I/O or syntax error."
      return 4
    fi
    [[ -z "$stored" ]] && return 10

    : > "$resume_out_file"
    if command -v pv >/dev/null 2>&1; then
      if ! _a2_launch_job pid_resume pgid_resume bash -c '
        set -o pipefail
        out_file="${@: -1}"
        parts_list=("${@:1:$#-1}")
        cat -- "${parts_list[@]}" | pv -N "Validating Split Files" -p -t -e -r -b | b3sum | awk '\''{print $1}'\'' > "$out_file"
      ' _ "${parts[@]}" "$resume_out_file"; then
        _a2_print_log "ERROR: Failed to launch split resume hash job."
        return 4
      fi
    else
      if ! _a2_launch_job pid_resume pgid_resume bash -c '
        set -o pipefail
        out_file="${@: -1}"
        parts_list=("${@:1:$#-1}")
        cat -- "${parts_list[@]}" | b3sum | awk '\''{print $1}'\'' > "$out_file"
      ' _ "${parts[@]}" "$resume_out_file"; then
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

    current=$(< "$resume_out_file")
    [[ -n "$current" ]] || return 4

    _a2_print_log "[BLAKE3] Stored Global : $stored"
    _a2_print_log "[BLAKE3] Current Stream: $current"
    [[ "$stored" == "$current" ]]
  }

  _a2_validate_global_manifest() {
    local m_file="$manifest"
    local target_name="${out}.tar.zst"
    
    [[ -f "$m_file" ]] || return 1

    awk -v target="$target_name" '
      BEGIN { count = 0; malformed_pos = 0; invalid = 0 }
      $0 ~ /^#/ { next }
      NF == 0 { next }
      {
        if ($2 == target) {
          count++
          if (NF != 2 || length($1) != 64 || $1 !~ /^[0-9a-fA-F]+$/) {
            invalid = 1
          }
        } else {
          for (i = 1; i <= NF; i++) {
            if ($i == target) malformed_pos = 1
          }
        }
      }
      END {
        if (count == 1 && !invalid && !malformed_pos) exit 0
        exit 1
      }
    ' "$m_file"
  }

  # ------------------------------------------------------------
  # EXECUÇÃO DO FLUXO (SPLIT MODE OU SINGLE MODE)
  # ------------------------------------------------------------
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
          _a2_show_manifest
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
      if compgen -G "${out}.tar.zst.part-*" > /dev/null; then
        if ! rm -f "${out}.tar.zst.part-"*; then
          _a2_print_log "ERROR: Failed to remove stale split parts prior to compression."
          _a2_cleanup
          return 1
        fi
      fi
      _a2_update_parts_array
      if [[ ${#parts[@]} -gt 0 ]]; then
        _a2_print_log "ERROR: Stale split parts remain present after cleanup attempt."
        _a2_cleanup
        return 1
      fi

      comp_start=$(date +%s)
      echo "# Created: $(date '+%Y-%m-%d %H:%M:%S')" > "$manifest"
      echo "1" > "$status_file"

      if ! _a2_launch_job pid_b3sum pgid_b3sum bash -c '
        set -o pipefail
        if b3sum < "$1" | awk -v target="$2" '\''{print $1 "  " target}'\'' >> "$3"; then
          echo "0" > "$4"
        else
          echo "1" > "$4"
        fi
      ' _ "$hash_fifo" "${out}.tar.zst" "$manifest" "$status_file"; then
        _a2_print_log "ERROR: Failed to launch b3sum job."
        _a2_cleanup
        return 1
      fi

      (( abort_flag )) && { _a2_cleanup; return 1; }

      if ! _a2_launch_job pid_main_pipeline pgid_main_pipeline bash -c '
        set -o pipefail
        tar -cf - -C "$1" "$2" \
        | zstd -T0 -10 --long=27 -v --progress 2> "$3" \
        | tee "$4" \
        | split -d -a 3 -b "$5" - "$6.tar.zst.part-"
      ' _ "$parent_dir" "$base" "$zstd_err_file" "$hash_fifo" "$maxsize" "$out"; then
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
      [[ -f "$status_file" ]] && b3sum_file_status=$(< "$status_file")

      if [[ $b3sum_wait_status -ne 0 || "$b3sum_file_status" != "0" ]]; then
        _a2_print_log "ERROR: global BLAKE3 hashing process failed or did not complete successfully"
        _a2_cleanup
        return 1
      fi

      if ! _a2_validate_global_manifest; then
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
      _a2_update_parts_array
      [[ ${#parts[@]} -gt 0 ]] || { _a2_print_log "ERROR: no split parts found"; _a2_cleanup; return 1; }

      if ! _a2_launch_job pid_helper pgid_helper bash -c '
        for part in "$@"; do
          p_size=$(stat -c%s "$part") || exit 1
          if command -v pv >/dev/null 2>&1; then
            hash=$(set -o pipefail; pv -N "Hashing $part" -s "$p_size" -p -t -e -r "$part" | b3sum | awk '\''{print $1}'\'') || exit 1
          else
            hash=$(set -o pipefail; b3sum "$part" | awk '\''{print $1}'\'') || exit 1
          fi
          [[ -n "$hash" ]] || exit 1
          echo "$hash  $part" >> "'"$manifest"'" || exit 1
        done
      ' _ "${parts[@]}"; then
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

      _a2_show_manifest

      comp_end=$(date +%s)
      t_compress_dur=$(_a2_format_duration $((comp_end - comp_start)))
      compress_status="SUCCESS"

      _a2_check_content_integrity || {
        _a2_cleanup
        return 1
      }
    fi

    (( abort_flag )) && { _a2_cleanup; return 1; }

    local par2_start par2_end
    par2_start=$(date +%s)
    _a2_print_log "[PAR2] Creating recovery files..."

    local par2_cmd
    par2_cmd=$(printf "par2 create -r10 %q " "${out}.par2"; printf "%q " "${parts[@]}"; printf "%q" "$manifest")
    
    if ! _a2_launch_job pid_par2 pgid_par2 bash -c 'script -q -f "$1" -c "$2"' _ "$par2_tty_file" "$par2_cmd"; then
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

    (( abort_flag )) && { _a2_cleanup; return 1; }

    if (( par2_exit_status != 0 )); then
      par2_status="FAILED"
      _a2_cleanup
      return 1
    fi

    tr -d '\r' < "$par2_tty_file" | grep -v -E '[0-9]+\.[0-9]%|Opening:|Processing:|Constructing:' >> "$logfile"

    par2_end=$(date +%s)
    t_par2_dur=$(_a2_format_duration $((par2_end - par2_start)))
    par2_status="SUCCESS"

  else
    # ==================== MODO SINGLE FILE ====================
    _a2_print_log "[MODE] Single file"

    (( abort_flag )) && { _a2_cleanup; return 1; }

    if [[ -f "${out}.tar.zst" ]]; then
      _a2_print_log "[RESUME] Found existing target archive. Testing its integrity directly..."
      _a2_verify_manifest_single
      local v_status=$?
      if (( v_status == 0 )); then
        _a2_print_log "[BLAKE3] Manifest OK"
        if _a2_check_content_integrity; then
          _a2_print_log "[RESUME] Existing archive is healthy! Skipping compression stage."
          _a2_show_manifest
          run_compression=0
        fi
      elif (( v_status == 10 )); then
        _a2_print_log "[WARN] Manifest not found or missing global entry."
        read -r -p "Continue without valid BLAKE3 validation? [y/N]: " response </dev/tty
        if [[ "$response" =~ ^[yY](es)?$ ]]; then
          if _a2_check_content_integrity; then
            _a2_print_log "[RESUME] Existing archive is healthy! Skipping compression stage."
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
      comp_start=$(date +%s)
      echo "# Created: $(date '+%Y-%m-%d %H:%M:%S')" > "$manifest"
      echo "1" > "$status_file"

      if ! _a2_launch_job pid_b3sum pgid_b3sum bash -c '
        set -o pipefail
        if b3sum < "$1" | awk -v target="$2" '\''{print $1 "  " target}'\'' >> "$3"; then
          echo "0" > "$4"
        else
          echo "1" > "$4"
        fi
      ' _ "$hash_fifo" "${out}.tar.zst" "$manifest" "$status_file"; then
        _a2_print_log "ERROR: Failed to launch b3sum job."
        _a2_cleanup
        return 1
      fi

      (( abort_flag )) && { _a2_cleanup; return 1; }

      if ! _a2_launch_job pid_main_pipeline pgid_main_pipeline bash -c '
        set -o pipefail
        tar -cf - -C "$1" "$2" \
        | zstd -T0 -10 --long=27 -v --progress 2> "$3" \
        | tee "$4" \
        > "$5.tar.zst"
      ' _ "$parent_dir" "$base" "$zstd_err_file" "$hash_fifo" "$out"; then
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
      [[ -f "$status_file" ]] && b3sum_file_status=$(< "$status_file")

      if [[ $b3sum_wait_status -ne 0 || "$b3sum_file_status" != "0" ]]; then
        _a2_print_log "ERROR: global BLAKE3 hashing process failed or did not complete successfully"
        _a2_cleanup
        return 1
      fi

      if ! _a2_validate_global_manifest; then
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

      _a2_show_manifest 

      comp_end=$(date +%s)
      t_compress_dur=$(_a2_format_duration $((comp_end - comp_start)))
      compress_status="SUCCESS"

      _a2_check_content_integrity || {
        _a2_cleanup
        return 1
      }
    fi

    (( abort_flag )) && { _a2_cleanup; return 1; }

    local par2_start par2_end
    par2_start=$(date +%s)
    _a2_print_log "[PAR2] Creating recovery files..."

    if ! _a2_launch_job pid_par2 pgid_par2 bash -c 'script -q -f "$1" -c '\''par2 create -r10 "'"${out}.par2"'" "'"${out}.tar.zst"'" "'"$manifest"'"'\''' _ "$par2_tty_file"; then
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

    (( abort_flag )) && { _a2_cleanup; return 1; }

    if (( par2_exit_status != 0 )); then
      par2_status="FAILED"
      _a2_cleanup
      return 1
    fi

    tr -d '\r' < "$par2_tty_file" | grep -v -E '[0-9]+\.[0-9]%|Opening:|Processing:|Constructing:' >> "$logfile"

    par2_end=$(date +%s)
    t_par2_dur=$(_a2_format_duration $((par2_end - par2_start)))
    par2_status="SUCCESS"
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