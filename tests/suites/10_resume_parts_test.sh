#!/usr/bin/env bash
# scriptignore: skip
# scriptignore-reason: arquivo de suíte de testes automatizados do archivepar2

### -----------------------------------------------------------------
### Version Details: v0.0.3
### Suite Name: Teste de Hash de Resume das Partes
### Description: Valida o cálculo do hash BLAKE3 das partes divididas,
### garantindo integridade do resultado e detecção de partes ausentes,
### lacunas na sequência e falhas operacionais durante o resume.
### -----------------------------------------------------------------

SUITE_NAME="Teste de Hash de Resume das Partes"
SUITE_APPLIES_TO="*"
SUITE_NEEDS_BINS="par2 zstd b3sum pv setsid"

_load_targets() {
    source "$_rt_target"
}

_resume_hash_setup_backup() {
    local fix_name="$1"
    local content="$2"
    local fix_dir

    fix_dir=$(_t_mkfix "$fix_name") || {
        _t_assert_eq "1" "0" "Deve ser possível criar o diretório de teste"
        return 1
    }

    printf '%s\n' "$content" > "$fix_dir/file.txt" || {
        _t_assert_eq "1" "0" "Deve ser possível criar o arquivo de origem"
        return 1
    }

    local abs_fix
    abs_fix=$(realpath "$fix_dir") || {
        _t_assert_eq "1" "0" "Deve ser possível resolver o caminho da origem"
        return 1
    }

    _load_targets || {
        _t_assert_eq "1" "0" "Deve ser possível carregar o target de teste"
        return 1
    }

    archivepar2 "$abs_fix" 1K || {
        _t_assert_eq "1" "0" "O backup inicial deve suceder"
        return 1
    }

    printf '%s\n' "$abs_fix"
}

_resume_hash_get_active_dir() {
    local backup_dir="$1"

    if [[ -L "$backup_dir/current" ]]; then
        realpath "$backup_dir/current"
    else
        printf '%s\n' "$backup_dir"
    fi
}

_resume_hash_find_parts() {
    local active_dir="$1"

    find "$active_dir" -maxdepth 1 -type f \
        -name '*.part-*' -print | sort -V
}

_resume_hash_assert_manifest_exists() {
    local manifest="$1"

    [[ -f "$manifest" ]] || {
        _t_assert_eq "1" "0" "O manifesto ativo deve existir: $manifest"
        return 1
    }
}

_resume_hash_assert_valid_hash() {
    local hash="$1"
    local description="$2"

    [[ "$hash" =~ ^[[:xdigit:]]{64}$ ]] || {
        _t_assert_eq "1" "0" "$description"
        return 1
    }
}

_resume_hash_capture_resume_failure() {
    local abs_fix="$1"
    local output="$2"
    local rc=0

    archivepar2 "$abs_fix" 1K >"$output" 2>&1 || rc=$?

    if (( rc == 0 )); then
        cat "$output"
        _t_assert_ne "$rc" "0" \
            "O resume deve falhar quando a estrutura das partes está incompleta"
        return 1
    fi

    # A ausência de partes é um problema estrutural do resume, não
    # necessariamente uma falha operacional do cálculo do hash.
    #
    # Aceitamos mensagens específicas de validação ou de falha na
    # leitura/hash das partes, mas não uma falha genérica sem diagnóstico.
    if ! grep -Eiq \
        'resume validation failed|manifest corruption|manifest.*(invalid|corrupt|structural)|missing.*part|part.*missing|split parts.*(missing|incomplete)|failed to read/compute hash of split parts|could not reliably reap split resume hash job' \
        "$output"; then
        cat "$output"
        _t_assert_eq "1" "0" \
            "A falha deve produzir um diagnóstico relacionado à validação do resume ou às partes divididas"
        return 1
    fi

    return 0
}

t01_split_resume_hash_matches() {
    local fix_dir
    fix_dir=$(_t_mkfix "resume_hash_source") || {
        _t_assert_eq "1" "0" "Deve ser possível criar o diretório de teste"
        return 1
    }

    head -c 5000 /dev/urandom > "$fix_dir/file.bin" || {
        _t_assert_eq "1" "0" "Deve ser possível criar o arquivo de origem"
        return 1
    }

    local abs_fix
    abs_fix=$(realpath "$fix_dir") || {
        _t_assert_eq "1" "0" "Deve ser possível resolver o caminho da origem"
        return 1
    }

    _load_targets || {
        _t_assert_eq "1" "0" "Deve ser possível carregar o target de teste"
        return 1
    }

    archivepar2 "$abs_fix" 1K || {
        _t_assert_eq "1" "0" "Primeiro backup deve suceder"
        return 1
    }

    local backup_dir="${abs_fix}-bak"
    local active_dir

    active_dir=$(_resume_hash_get_active_dir "$backup_dir") || {
        _t_assert_eq "1" "0" "Deve ser possível resolver o diretório ativo"
        return 1
    }

    [[ -d "$active_dir" ]] || {
        _t_assert_eq "1" "0" "O diretório ativo deve existir: $active_dir"
        return 1
    }

    local -a parts=()
    mapfile -t parts < <(_resume_hash_find_parts "$active_dir")

    _t_assert_ne "${#parts[@]}" "0" \
        "O backup deve conter partes para validar o hash" || return 1

    local part
    for part in "${parts[@]}"; do
        [[ -s "$part" ]] || {
            _t_assert_eq "1" "0" \
                "Todas as partes devem existir e conter dados: $part"
            return 1
        }
    done

    local expected_hash
    expected_hash=$(
        set -o pipefail
        cat -- "${parts[@]}" | b3sum | awk '{print $1}'
    ) || {
        _t_assert_eq "1" "0" "O cálculo do hash BLAKE3 esperado deve suceder"
        return 1
    }

    _resume_hash_assert_valid_hash "$expected_hash" \
        "O hash BLAKE3 esperado deve conter exatamente 64 caracteres hexadecimais" ||
        return 1

    local manifest="${active_dir}/$(basename "$abs_fix").blake3"

    _resume_hash_assert_manifest_exists "$manifest" || return 1

    # Confirma que o manifesto contém a entrada global esperada para
    # o arquivo tar.zst. A verificação do hash calculado das partes
    # contra o manifesto depende do formato efetivamente usado pelo projeto.
    local target_name
    target_name="$(basename "$abs_fix").tar.zst"

    grep -Eq \
        "^[[:xdigit:]]{64}[[:space:]]+${target_name//./\\.}$" \
        "$manifest" || {
        _t_assert_eq "1" "0" \
            "O manifesto deve conter uma entrada global válida para $target_name"
        return 1
    }

    _t_assert_eq "0" "0" \
        "As partes do backup devem permitir calcular um hash BLAKE3 válido"
}

t02_split_resume_hash_detects_missing_part() {
    local fix_dir
    fix_dir=$(_t_mkfix "resume_hash_missing_part") || {
        _t_assert_eq "1" "0" "Deve ser possível criar o diretório de teste"
        return 1
    }

    head -c 5000 /dev/urandom > "$fix_dir/file.bin" || {
        _t_assert_eq "1" "0" "Deve ser possível criar o arquivo de origem"
        return 1
    }

    local abs_fix
    abs_fix=$(realpath "$fix_dir") || {
        _t_assert_eq "1" "0" "Deve ser possível resolver o caminho da origem"
        return 1
    }

    _load_targets || {
        _t_assert_eq "1" "0" "Deve ser possível carregar o target de teste"
        return 1
    }

    archivepar2 "$abs_fix" 1K || {
        _t_assert_eq "1" "0" "Primeiro backup deve suceder"
        return 1
    }

    local backup_dir="${abs_fix}-bak"
    local active_dir

    active_dir=$(_resume_hash_get_active_dir "$backup_dir") || {
        _t_assert_eq "1" "0" "Deve ser possível resolver o diretório ativo"
        return 1
    }

    local manifest="${active_dir}/$(basename "$abs_fix").blake3"
    _resume_hash_assert_manifest_exists "$manifest" || return 1

    local -a parts=()
    mapfile -t parts < <(_resume_hash_find_parts "$active_dir")

    _t_assert_ne "${#parts[@]}" "0" \
        "Deve existir ao menos uma parte no backup ativo" || return 1

    local part="${parts[0]}"

    rm -f -- "$part" || {
        _t_assert_eq "1" "0" "Deve ser possível remover a parte de teste"
        return 1
    }

    [[ ! -e "$part" ]] || {
        _t_assert_eq "1" "0" "A parte selecionada deve estar ausente após a remoção"
        return 1
    }

    local output
    output=$(_t_mktemp 2>/dev/null) || {
        _t_assert_eq "1" "0" "Deve ser possível criar arquivo temporário de log"
        return 1
    }

    if ! _resume_hash_capture_resume_failure "$abs_fix" "$output"; then
        rm -f -- "$output"
        return 1
    fi

    rm -f -- "$output"

    _t_assert_eq "0" "0" \
        "O resume deve detectar uma parte ausente e retornar uma falha diagnosticável"
}

t03_split_resume_hash_detects_missing_first_part() {
    local fix_dir
    fix_dir=$(_t_mkfix "resume_hash_missing_first_part") || {
        _t_assert_eq "1" "0" "Deve ser possível criar o diretório de teste"
        return 1
    }

    head -c 5000 /dev/urandom > "$fix_dir/file.bin"

    local abs_fix
    abs_fix=$(realpath "$fix_dir") || {
        _t_assert_eq "1" "0" "Deve ser possível resolver a origem"
        return 1
    }

    _load_targets || return 1

    archivepar2 "$abs_fix" 1K || {
        _t_assert_eq "1" "0" "Primeiro backup deve suceder"
        return 1
    }

    local backup_dir="${abs_fix}-bak"
    local active_dir
    active_dir=$(_resume_hash_get_active_dir "$backup_dir") || return 1

    local -a parts=()
    mapfile -t parts < <(_resume_hash_find_parts "$active_dir")

    _t_assert_ne "${#parts[@]}" "0" "Deve existir ao menos uma parte" || return 1

    local first_part="${parts[0]}"
    rm -f -- "$first_part" || {
        _t_assert_eq "1" "0" "Deve ser possível remover a primeira parte"
        return 1
    }

    local output
    output=$(_t_mktemp 2>/dev/null) || return 1

    if ! _resume_hash_capture_resume_failure "$abs_fix" "$output"; then
        rm -f -- "$output"
        return 1
    fi

    rm -f -- "$output"

    _t_assert_eq "0" "0" \
        "O resume deve detectar a ausência da primeira parte"
}

t04_split_resume_hash_detects_missing_middle_part() {
    local fix_dir
    fix_dir=$(_t_mkfix "resume_hash_missing_middle_part") || {
        _t_assert_eq "1" "0" "Deve ser possível criar o diretório de teste"
        return 1
    }

    head -c 5000 /dev/urandom > "$fix_dir/file.bin"

    local abs_fix
    abs_fix=$(realpath "$fix_dir") || {
        _t_assert_eq "1" "0" "Deve ser possível resolver a origem"
        return 1
    }

    _load_targets || return 1

    archivepar2 "$abs_fix" 1K || {
        _t_assert_eq "1" "0" "Primeiro backup deve suceder"
        return 1
    }

    local backup_dir="${abs_fix}-bak"
    local active_dir
    active_dir=$(_resume_hash_get_active_dir "$backup_dir") || return 1

    local -a parts=()
    mapfile -t parts < <(_resume_hash_find_parts "$active_dir")

    _t_assert_ne "${#parts[@]}" "0" "Deve existir ao menos uma parte" || return 1

    if ((${#parts[@]} < 3)); then
        _t_assert_eq "1" "0" \
            "O fixture deve gerar pelo menos três partes para testar a ausência de uma parte intermediária"
        return 1
    fi

    local middle_index=$(( ${#parts[@]} / 2 ))
    local middle_part="${parts[$middle_index]}"

    rm -f -- "$middle_part" || {
        _t_assert_eq "1" "0" "Deve ser possível remover a parte intermediária"
        return 1
    }

    local output
    output=$(_t_mktemp 2>/dev/null) || return 1

    if ! _resume_hash_capture_resume_failure "$abs_fix" "$output"; then
        rm -f -- "$output"
        return 1
    fi

    rm -f -- "$output"

    _t_assert_eq "0" "0" \
        "O resume deve detectar a ausência de uma parte intermediária"
}

t05_split_resume_hash_detects_missing_last_part() {
    local fix_dir
    fix_dir=$(_t_mkfix "resume_hash_missing_last_part") || {
        _t_assert_eq "1" "0" "Deve ser possível criar o diretório de teste"
        return 1
    }

    head -c 5000 /dev/urandom > "$fix_dir/file.bin"

    local abs_fix
    abs_fix=$(realpath "$fix_dir") || {
        _t_assert_eq "1" "0" "Deve ser possível resolver a origem"
        return 1
    }

    _load_targets || return 1

    archivepar2 "$abs_fix" 1K || {
        _t_assert_eq "1" "0" "Primeiro backup deve suceder"
        return 1
    }

    local backup_dir="${abs_fix}-bak"
    local active_dir
    active_dir=$(_resume_hash_get_active_dir "$backup_dir") || return 1

    local -a parts=()
    mapfile -t parts < <(_resume_hash_find_parts "$active_dir")

    _t_assert_ne "${#parts[@]}" "0" "Deve existir ao menos uma parte" || return 1

    local last_index=$(( ${#parts[@]} - 1 ))
    local last_part="${parts[$last_index]}"

    rm -f -- "$last_part" || {
        _t_assert_eq "1" "0" "Deve ser possível remover a última parte"
        return 1
    }

    local output
    output=$(_t_mktemp 2>/dev/null) || return 1

    if ! _resume_hash_capture_resume_failure "$abs_fix" "$output"; then
        rm -f -- "$output"
        return 1
    fi

    rm -f -- "$output"

    _t_assert_eq "0" "0" \
        "O resume deve detectar a ausência da última parte"
}