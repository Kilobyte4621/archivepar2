#!/usr/bin/env bash
# scriptignore: skip
# scriptignore-reason: suíte de testes avançados de restorepar2, retenção e legado

### -----------------------------------------------------------------
### Version Details: v0.0.1
### Suite Name: Testes Avançados e Restauração (restorepar2)
### Description: Valida o fluxo e2e, restauração, extração BLAKE3, 
### retenção com loops e compatibilidade com layouts legados.
### -----------------------------------------------------------------

SUITE_NAME="Testes Avançados e Restauração"
SUITE_APPLIES_TO="*"
SUITE_NEEDS_BINS="par2 zstd b3sum setsid"

# Teste 1: End-to-end do zero (versão ativa e sem .staging residual)
t01_e2e_clean_creation() {
    local fix_dir
    fix_dir=$(_t_mkfix "mydata")
    echo "release v0.17" > "$fix_dir/file.txt"
    local abs_fix
    abs_fix=$(realpath "$fix_dir")

    source "$_rt_target"
    archivepar2 "$abs_fix"

    local base_name
    base_name=$(basename "$abs_fix")
    local backup_dir="$PWD/${base_name}-bak"

    _t_assert_dir_exists "$backup_dir" "O diretório de backup deve existir"
    _t_assert_file_exists "$backup_dir/current" "O link current deve existir"
    
    # Valida ausência de arquivos residuais .staging
    local staging_count
    staging_count=$(find "$backup_dir" -name ".staging.*" | wc -l)
    _t_assert_eq "$staging_count" "0" "Não deve haver arquivos residuais .staging"
}

# Teste 2 e 3: Restore, validação e extração com BLAKE3
t02_restore_and_extraction() {
    local fix_dir
    fix_dir=$(_t_mkfix "mydata_ext")
    echo "release v0.17 content" > "$fix_dir/file.txt"
    local abs_fix
    abs_fix=$(realpath "$fix_dir")

    # Carrega ambos os scripts alvo no subshell de teste
    source "$_rt_target"
    source "$(dirname "$_rt_target")/restorepar2.sh"

    archivepar2 "$abs_fix"

    local base_name
    base_name=$(basename "$abs_fix")
    local backup_dir="$PWD/${base_name}-bak"

    local rc=0
    restorepar2 "$backup_dir" extract || rc=$?
    _t_assert_eq "$rc" "0" "A extração pelo restorepar2 deve suceder"
}

# Teste 4: Retenção iterativa com --keep 2
t03_iterative_keep_retention() {
    local fix_dir
    fix_dir=$(_t_mkfix "mydata_keep")
    echo "init" > "$fix_dir/file.txt"
    local abs_fix
    abs_fix=$(realpath "$fix_dir")

    source "$_rt_target"

    for i in 1 2 3 4 5; do
        echo "mod $i" >> "$fix_dir/file.txt"
        archivepar2 --keep 2 "$abs_fix"
    done

    local base_name
    base_name=$(basename "$abs_fix")
    local backup_dir="$PWD/${base_name}-bak"

    # Contagem de versões (ativa + 2 retidas = máximo 3)
    local version_count
    version_count=$(find "$backup_dir" -mindepth 1 -maxdepth 1 -type d -name "v*" | wc -l)
    
    [[ "$version_count" -le 3 ]]
    _t_assert_eq "$?" "0" "Com --keep 2, deve manter no máximo 3 diretórios de versão"
}

# Teste 5: Suporte a layout legado (--no-migrate)
t04_legacy_layout_compatibility() {
    local fix_dir
    fix_dir=$(_t_mkfix "legacy_data")
    echo "legacy compat" > "$fix_dir/legacy.txt"
    local abs_fix
    abs_fix=$(realpath "$fix_dir")

    source "$_rt_target"
    archivepar2 --no-migrate "$abs_fix"

    local base_name
    base_name=$(basename "$abs_fix")
    local backup_dir="$PWD/${base_name}-bak"

    # Layout legado não deve ter subdiretórios 'v*' nem 'current'
    local v_count
    v_count=$(find "$backup_dir" -mindepth 1 -maxdepth 1 -type d -name "v*" | wc -l)
    
    _t_assert_eq "$v_count" "0" "Layout legado não deve conter diretórios versionados v*"
}
