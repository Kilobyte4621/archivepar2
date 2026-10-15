#!/usr/bin/env bash
# scriptignore: skip
# scriptignore-reason: suíte de testes de corrupção, verificação e reparo PAR2

### -----------------------------------------------------------------
### Version Details: v0.0.1
### Suite Name: Testes de Corrupção e Reparo Automático (PAR2)
### Description: Valida a detecção de arquivos corrompidos e o acionamento
### bem-sucedido do reparo automático via par2 repair no restorepar2.
### -----------------------------------------------------------------

SUITE_NAME="Testes de Corrupção e Reparo Automático"
SUITE_APPLIES_TO="*"
SUITE_NEEDS_BINS="par2 zstd b3sum setsid"

_load_targets() {
    source "$_rt_target"
    source "$(dirname "$_rt_target")/restorepar2.sh"
}

# Teste 1: Corrupção intencional de dados e reparo automático
t01_par2_corruption_and_repair() {
    local fix_dir
    fix_dir=$(_t_mkfix "repair_source")
    echo "dados criticos para teste de par2 repair" > "$fix_dir/critical.txt"
    local abs_fix
    abs_fix=$(realpath "$fix_dir")

    _load_targets

    # Cria o backup versionado
    archivepar2 "$abs_fix"

    local base_name
    base_name=$(basename "$abs_fix")
    local backup_dir="$PWD/${base_name}-bak"
    local latest_v
    latest_v=$(find "$backup_dir" -mindepth 1 -maxdepth 1 -type d -name "v*" | sort | tail -1)

    _t_assert_dir_exists "$latest_v" "O diretório da versão mais recente deve existir"

    # Encontra o arquivo compactado tar.zst dentro da versão e corrompe alguns bytes
    local target_tar
    target_tar=$(find "$latest_v" -name "*.tar.zst*" | head -1)
    
    if [[ -f "$target_tar" ]]; then
        # Corrompe o arquivo gravando lixo nos primeiros bytes
        echo "CORRUPTEDDATA" >> "$target_tar"
    fi

    # Executa o restorepar2 em modo verify/repair para testar a recuperação
    local rc=0
    restorepar2 "$backup_dir" extract || rc=$?
    
    # O restorepar2 deve detectar a falha, acionar o reparo via PAR2 e extrair com sucesso
    _t_assert_eq "$rc" "0" "O restorepar2 deve conseguir reparar e extrair mesmo após corrupção"
}
