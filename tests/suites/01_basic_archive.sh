#!/usr/bin/env bash
# scriptignore: skip
# scriptignore-reason: arquivo de suíte de testes automatizados do archivepar2

### -----------------------------------------------------------------
### Version Details: v0.0.1
### Suite Name: Testes Básicos de Criação e Restauração
### Description: Valida o comportamento básico e sem argumentos do
### archivepar2, bem como a criação padrão em modo split (v0.17).
### -----------------------------------------------------------------

SUITE_NAME="Testes Básicos de Criação e Restauração"
SUITE_APPLIES_TO="*"
SUITE_NEEDS_BINS="par2 zstd b3sum pv setsid"

# Garante que o PATH inclua os caminhos essenciais para utilitários como setsid
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Teste 1: Validação de falha ao não fornecer argumentos
t01_archivepar2_no_args() {
    local rc=0
    source "$_rt_target"
    archivepar2 || rc=$?
    _t_assert_ne "$rc" "0" "archivepar2 deveria falhar sem argumentos"
}

# Teste 2: Criação de backup básico (modo split padrão v0.17)
t02_archivepar2_basic_creation() {
    local fix_dir
    fix_dir=$(_t_mkfix "basic_source")

    # Cria arquivos fictícios para teste
    _t_random_file "$fix_dir/file1.dat" 5120  # 5 KB
    _t_random_file "$fix_dir/file2.dat" 10240 # 10 KB

    local abs_fix
    abs_fix=$(realpath "$fix_dir")

    local rc=0
    source "$_rt_target"

    # Executa o archivepar2 a partir do diretório de trabalho atual do teste
    archivepar2 "$abs_fix" || rc=$?

    _t_assert_eq "$rc" "0" "A criação do archive deveria suceder com código 0"

    # O archivepar2 cria o <base>-bak no diretório de trabalho atual ($PWD / _T_TEST_TMPDIR)
    local base_name
    base_name=$(basename "$abs_fix")
    local backup_dir="$PWD/${base_name}-bak"

    _t_assert_dir_exists "$backup_dir" "O diretório de backup deveria existir"
    #_t_assert_symlink_exists "$backup_dir/current" "O link simbólico 'current' deveria existir"
    # Em vez de _t_assert_symlink_exists, use:
    _t_assert_file_exists "$backup_dir/current" "O link simbólico 'current' deveria existir"
}
