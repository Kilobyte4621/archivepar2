#!/usr/bin/env bash
# scriptignore: skip
# scriptignore-reason: arquivo de suíte de testes automatizados do archivepar2

### -----------------------------------------------------------------
### Version Details: v0.0.1
### Suite Name: Teste de Falha de Prune Obsoleta
### Description: Valida o endurecimento do _a2_prune_obsolete_parts,
### garantindo que falhas na remoção de partes obsoletas impeçam
### sucesso silencioso (Fechamento da Issue #2).
### -----------------------------------------------------------------

SUITE_NAME="Teste de Falha de Prune Obsoleta"
SUITE_APPLIES_TO="*"
SUITE_NEEDS_BINS="par2 zstd b3sum pv setsid"

_load_targets() {
    source "$_rt_target"
}

t01_prune_removal_failure() {
    local fix_dir
    fix_dir=$(_t_mkfix "prune_fail_source")
    echo "dados iniciais" > "$fix_dir/file.txt"
    local abs_fix
    abs_fix=$(realpath "$fix_dir")

    _load_targets

    # 1. Executa o primeiro backup normal para gerar partes e manifesto
    archivepar2 "$abs_fix" || { _t_assert_eq "1" "0" "Primeiro backup deve suceder"; return 1; }

    local backup_dir="$abs_fix-bak"
    
    # 2. Cria uma parte obsoleta fictícia e bloqueia a permissão do diretório para forçar falha no rm -f
    local dummy_part="$backup_dir/obsolete_test.tar.zst.part-999"
    touch "$dummy_part"
    chmod -w "$backup_dir"

    # 3. Executa um novo backup (que acionará o _a2_prune_obsolete_parts e falhará ao tentar remover a parte)
    echo "dados modificados para novo backup" > "$fix_dir/file.txt"
    local rc=0
    archivepar2 "$abs_fix" || rc=$?

    # Restaura permissão para o runner conseguir limpar o diretório ao terminar
    chmod +w "$backup_dir"

    # 4. O comando deve falhar (rc != 0) devido ao endurecimento do prune
    _t_assert_ne "$rc" "0" "O archivepar2 deve falhar caso ocorra erro na remoção de partes obsoletas"
}
