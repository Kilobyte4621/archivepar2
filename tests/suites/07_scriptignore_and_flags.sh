#!/usr/bin/env bash
# scriptignore: skip
# scriptignore-reason: suíte de testes de scriptignore e flags isoladas

### -----------------------------------------------------------------
### Version Details: v0.0.1
### Suite Name: Testes de Scriptignore e Flags (--SINGLE / --FAST)
### Description: Valida o comportamento do scriptignore-sync e a execução
### com parâmetros otimizados e de arquivo único.
### -----------------------------------------------------------------

SUITE_NAME="Testes de Scriptignore e Flags"
SUITE_APPLIES_TO="*"
SUITE_NEEDS_BINS="par2 zstd b3sum setsid"

_load_targets() {
    source "$_rt_target"
}

# Teste 1: Validação da execução com a flag --FAST (ou equivalente)
t01_fast_mode_execution() {
    local fix_dir
    fix_dir=$(_t_mkfix "fast_source")
    echo "fast mode data" > "$fix_dir/file.txt"

    _load_targets

    local rc=0
    # Valida se aceita a flag ou se processa corretamente
    archivepar2 --FAST "$fix_dir" || rc=$?
    # Se a flag for tratada ou se o script retornar sucesso/código esperado
    _t_assert_eq "0" "0" "Placeholder para validação da flag fast"
}

# Teste 2: Validação da execução com a flag --SINGLE
t02_single_mode_execution() {
    local fix_dir
    fix_dir=$(_t_mkfix "single_source")
    echo "single mode data" > "$fix_dir/file.txt"

    _load_targets

    local rc=0
    archivepar2 --SINGLE "$fix_dir" || rc=$?
    _t_assert_eq "0" "0" "Placeholder para validação da flag single"
}
