#!/usr/bin/env bash
# scriptignore: skip
# scriptignore-reason: arquivo de suíte de testes de versionamento e retenção do archivepar2

### -----------------------------------------------------------------
### Version Details: v0.0.1
### Suite Name: Testes de Versionamento e Retenção (--KEEP)
### Description: Valida a criação de múltiplos diretórios versionados 
### (v<timestamp>), a troca atômica do link 'current' e a poda (--KEEP).
### -----------------------------------------------------------------

SUITE_NAME="Testes de Versionamento e Retenção"
SUITE_APPLIES_TO="*"
SUITE_NEEDS_BINS="par2 zstd b3sum setsid"

# Teste 1: Validação da criação de múltiplas versões e do link 'current'
t01_versioned_layout_and_current() {
    local fix_dir
    fix_dir=$(_t_mkfix "version_source")
    
    _t_random_file "$fix_dir/file1.dat" 2048

    local abs_fix
    abs_fix=$(realpath "$fix_dir")

    source "$_rt_target"

    # Primeira execução
    archivepar2 "$abs_fix"
    local base_name
    base_name=$(basename "$abs_fix")
    local backup_dir="$PWD/${base_name}-bak"

    _t_assert_dir_exists "$backup_dir" "O diretório de backup versionado deve existir"
    _t_assert_file_exists "$backup_dir/current" "O link simbólico 'current' deve existir"
    
    local first_target
    first_target=$(readlink "$backup_dir/current")

    # Segunda execução (simula alteração e nova versão)
    sleep 1
    echo "novo dado" >> "$fix_dir/file1.dat"
    archivepar2 "$abs_fix"

    local second_target
    second_target=$(readlink "$backup_dir/current")

    # Garante que o target do link simbólico mudou para a nova versão
    [[ "$first_target" != "$second_target" ]]
    _t_assert_eq "$?" "0" "O link 'current' deve ser atualizado atomicamente para a nova versão"
}

# Teste 2: Validação da retenção de versões com --KEEP 1
t02_versioned_retention_keep() {
    local fix_dir
    fix_dir=$(_t_mkfix "keep_source")

    _t_random_file "$fix_dir/file1.dat" 1024
    local abs_fix
    abs_fix=$(realpath "$fix_dir")

    source "$_rt_target"

    # Execução 1
    archivepar2 "$abs_fix"
    sleep 1

    # Execução 2
    echo "update 1" >> "$fix_dir/file1.dat"
    archivepar2 "$abs_fix"
    sleep 1

    # Execução 3 com --KEEP 1 (deve manter a active + 1 antiga = 2 versões no total)
    echo "update 2" >> "$fix_dir/file1.dat"
    archivepar2 --KEEP 1 "$abs_fix"

    local base_name
    base_name=$(basename "$abs_fix")
    local backup_dir="$PWD/${base_name}-bak"

    # Conta quantas pastas de versão v* existem dentro do diretório de backup
    local version_count
    version_count=$(find "$backup_dir" -mindepth 1 -maxdepth 1 -type d -name "v*" | wc -l)

    # Com --KEEP 1, o esperado é mantermos no máximo 2 versões (1 ativa + 1 antiga)
    [[ "$version_count" -le 2 ]]
    _t_assert_eq "$?" "0" "A retenção --KEEP 1 deve limitar o número de versões antigas armazenadas"
}
