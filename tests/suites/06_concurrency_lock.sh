#!/usr/bin/env bash
# scriptignore: skip
# scriptignore-reason: suíte de testes de concorrência e trava (.archivepar2.lock)

### -----------------------------------------------------------------
### Version Details: v0.0.1
### Suite Name: Testes de Concorrência e Trava (Lock)
### Description: Valida o comportamento do bloqueio concorrente 
### utilizando o arquivo de lock e diretórios de travamento.
### -----------------------------------------------------------------

SUITE_NAME="Testes de Concorrência e Trava"
SUITE_APPLIES_TO="*"
SUITE_NEEDS_BINS="par2 zstd b3sum setsid"

_load_targets() {
    source "$_rt_target"
}

# Teste 1: Rejeição de execução concorrente quando o lock está ativo
t01_concurrency_lock_rejection() {
    local fix_dir
    fix_dir=$(_t_mkfix "lock_source")
    echo "dados de lock" > "$fix_dir/file.txt"

    _load_targets

    # Simula um lock ativo criando manualmente ou travando o diretório de destino
    local backup_dir="$fix_dir-bak"
    mkdir -p "$backup_dir"
    touch "$backup_dir/.archivepar2.lock"

    local rc=0
    archivepar2 "$fix_dir" || rc=$?
    
    # O archivepar2 deve detectar o lock e falhar/retornar erro
    _t_assert_ne "$rc" "0" "O archivepar2 deve rejeitar execução concorrente se o lock existir"

    # Remove o lock para limpeza correta do teste
    rm -f "$backup_dir/.archivepar2.lock"
}
