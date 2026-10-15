#!/usr/bin/env bash
# scriptignore: skip
# scriptignore-reason: suíte abrangente de testes para restorepar2 e layouts versionados

### -----------------------------------------------------------------
### Version Details: v0.0.1
### Suite Name: Testes Abrangentes do restorepar2 (v0.5)
### Description: Valida layouts versionados com 'current', fallback sem 
### 'current', seleção de versão específica (--version), extração com 
### sufixos e tratamento de erros para versões inexistentes.
### -----------------------------------------------------------------

SUITE_NAME="Testes Abrangentes do restorepar2"
SUITE_APPLIES_TO="*"
SUITE_NEEDS_BINS="par2 zstd b3sum setsid"

# Helper interno para carregar ambos os alvos
_load_targets() {
    source "$_rt_target"
    source "$(dirname "$_rt_target")/restorepar2.sh"
}

# Teste A2 & B2: Layout versionado (current) e Extração padrão
t01_versioned_current_and_extract() {
    local fix_dir
    fix_dir=$(_t_mkfix "mydata")

    # Cria arquivo inicial
    echo "mod 0" > "$fix_dir/file.txt"

    _load_targets

    # Execuções iterativas para gerar o versionamento e o current
    for i in 1 2 3; do
        echo "mod $i" >> "$fix_dir/file.txt"
        archivepar2 "$fix_dir"
        sleep 1
    done

    local backup_dir="$fix_dir-bak"

    _t_assert_dir_exists "$backup_dir/current" "O link current deve existir"

    # Teste A2: Verify no layout versionado
    local rc=0
    restorepar2 "$backup_dir" || rc=$?
    _t_assert_eq "$rc" "0" "Restorepar2 verify deve suceder no layout versionado"

    # Teste B2: Extract do layout versionado
    restorepar2 "$backup_dir" extract || rc=$?
    _t_assert_eq "$rc" "0" "Restorepar2 extract deve suceder"

    _t_assert_dir_exists "$fix_dir-restored" "O diretório extraído padrão deve existir"
}

# Teste C2 & D2: Seleção explícita de versão específica (--version)
t02_explicit_version_selection() {
    local fix_dir
    fix_dir=$(_t_mkfix "mydata_v")
    echo "v_init" > "$fix_dir/file.txt"

    _load_targets

    for i in 1 2 3; do
        echo "v_mod $i" >> "$fix_dir/file.txt"
        archivepar2 "$fix_dir"
        sleep 1
    done

    local backup_dir="$fix_dir-bak"
    local v_old
    v_old=$(find "$backup_dir" -mindepth 1 -maxdepth 1 -type d -name "v*" | sort | head -1 | xargs basename)

    local rc=0
    # Teste C2: Extract com --version explícita
    restorepar2 "$backup_dir" --version="$v_old" extract || rc=$?
    _t_assert_eq "$rc" "0" "Extração de versão específica deve suceder"

    # Teste D2: Verify com --version separada
    restorepar2 "$backup_dir" --version "$v_old" || rc=$?
    _t_assert_eq "$rc" "0" "Verify com --version explícita deve suceder"
}

# Teste E2: Layout versionado sem 'current' (fallback para o v* mais recente)
t03_versioned_missing_current_fallback() {
    local fix_dir
    fix_dir=$(_t_mkfix "mydata_noc")
    local abs_fix
    abs_fix=$(realpath "$fix_dir")

    _load_targets

    echo "content" > "$abs_fix/file.txt"
    archivepar2 "$abs_fix"

    local base_name
    base_name=$(basename "$abs_fix")
    local backup_dir="$PWD/${base_name}-bak"

    # Remove o link simbólico current para simular ausência
    rm -f "$backup_dir/current"

    local rc=0
    restorepar2 "$backup_dir" || rc=$?
    _t_assert_eq "$rc" "0" "Restorepar2 deve fazer fallback para o v* mais recente se o current faltar"
}

# Teste F2: Erro ao informar versão inexistente
t04_nonexistent_version_error() {
    local fix_dir
    fix_dir=$(_t_mkfix "mydata_err")
    local abs_fix
    abs_fix=$(realpath "$fix_dir")

    _load_targets

    echo "content" > "$abs_fix/file.txt"
    archivepar2 "$abs_fix"

    local base_name
    base_name=$(basename "$abs_fix")
    local backup_dir="$PWD/${base_name}-bak"

    local rc=0
    restorepar2 "$backup_dir" --version=v99999999-999999 || rc=$?
    _t_assert_ne "$rc" "0" "Restorepar2 deve falhar ao buscar uma versão inexistente"
}
