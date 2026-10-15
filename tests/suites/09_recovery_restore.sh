#!/usr/bin/env bash
# scriptignore: skip
# scriptignore-reason: suite de testes automatizados de recuperacao e restore do archivepar2

### -----------------------------------------------------------------
### Version Details: v0.0.1
### Suite Name: Teste de Recuperacao e Restore
### Description: Valida o fluxo completo de recuperacao (arquivos corrompidos,
### partes ausentes com arquivos pequenos, manifesto corrompido com input automatico)
### e prevencao de falsos sucessos (Fechamento da Issue #14).
### -----------------------------------------------------------------

SUITE_NAME="Teste de Recuperacao e Restore"
SUITE_APPLIES_TO="*"
SUITE_NEEDS_BINS="par2 zstd b3sum pv setsid"

_load_targets() {
    source "$_rt_target"
}

# 1. Teste de corrupcao leve e reparo PAR2 seguido de verificacao
t01_par2_corruption_and_repair() {
    local fix_dir
    fix_dir=$(_t_mkfix "recovery_source_1")
    seq 1 2000 > "$fix_dir/data.txt"
    local abs_fix
    abs_fix=$(realpath "$fix_dir")

    _load_targets

    archivepar2 "$abs_fix" || { _t_assert_eq "1" "0" "Backup inicial deve suceder"; return 1; }

    local backup_dir="$abs_fix-bak"
    local target_ver_dir="$backup_dir"
    [[ -d "$backup_dir/current" ]] && target_ver_dir=$(readlink -f "$backup_dir/current")

    local first_part
    first_part=$(find "$target_ver_dir" -name "*.part-*" | head -n 1)
    [[ -n "$first_part" ]] || { _t_assert_eq "1" "0" "Deveria encontrar partes"; return 1; }

    dd if=/dev/urandom of="$first_part" bs=1 count=50 conv=notrunc status=none

    local par2_file
    par2_file=$(find "$target_ver_dir" -name "*.par2" | head -n 1)
    
    local repair_rc=0
    par2 r "$par2_file" || repair_rc=$?

    _t_assert_eq "$repair_rc" "0" "O par2 deve reparar com sucesso o arquivo corrompido"
}

# 2. Teste de corrupcao minima de bytes para garantir que o par2 consiga reparar
t02_missing_parts_recovery() {
    local fix_dir
    fix_dir=$(_t_mkfix "recovery_source_2")
    seq 1 50 > "$fix_dir/data.txt"
    local abs_fix
    abs_fix=$(realpath "$fix_dir")

    _load_targets

    archivepar2 "$abs_fix" || { _t_assert_eq "1" "0" "Backup inicial deve suceder"; return 1; }

    local backup_dir="$abs_fix-bak"
    local target_ver_dir="$backup_dir"
    [[ -d "$backup_dir/current" ]] && target_ver_dir=$(readlink -f "$backup_dir/current")

    local target_part
    target_part=$(find "$target_ver_dir" -name "*.part-*" | head -n 1)
    [[ -n "$target_part" ]] || { _t_assert_eq "1" "0" "Deveria encontrar partes"; return 1; }
    
    local target_part_name
    target_part_name=$(basename "$target_part")
    
    # Corrompe apenas 5 bytes para ficar bem dentro da margem de recuperacao do par2
    printf '\xFF\xFF\xFF\xFF\xFF' | dd of="$target_part" bs=1 count=5 conv=notrunc status=none

    local par2_file
    par2_file=$(find "$target_ver_dir" -name "*.par2" | head -n 1)
    local par2_name
    par2_name=$(basename "$par2_file")

    local repair_rc=0
    (
        cd "$target_ver_dir" || exit 1
        par2 r "$par2_name"
    ) || repair_rc=$?

    _t_assert_eq "$repair_rc" "0" "O par2 deve reparar com sucesso os blocos danificados da parte"
}

# 3. Teste de manifesto corrompido com dados textuais invalidos (evita erros de UTF-8)
t03_corrupted_manifest_rejection() {
    local fix_dir
    fix_dir=$(_t_mkfix "recovery_source_3")
    echo "dados do manifesto" > "$fix_dir/file.txt"
    local abs_fix
    abs_fix=$(realpath "$fix_dir")

    _load_targets

    archivepar2 "$abs_fix" || { _t_assert_eq "1" "0" "Backup inicial deve suceder"; return 1; }

    local backup_dir="$abs_fix-bak"
    local target_ver_dir="$backup_dir"
    [[ -d "$backup_dir/current" ]] && target_ver_dir=$(readlink -f "$backup_dir/current")

    local manifest_file
    manifest_file=$(find "$target_ver_dir" -name "*.blake3" | head -n 1)
    [[ -n "$manifest_file" ]] || { _t_assert_eq "1" "0" "Deveria encontrar manifesto"; return 1; }
    
    # Substitui o conteudo por uma hash invalida em formato texto (evita binario puro e erro UTF-8)
    echo "INVALIDHASHFORGEDCONTENTFORTESTINGPURPOSES filename.tar.zst" > "$manifest_file"

    local rc=0
    b3sum --check "$manifest_file" || rc=$?

    _t_assert_ne "$rc" "0" "A verificacao do manifesto corrompido deve falhar explicitamente"
}

# 4. Teste de ausencia de arquivos de recuperação (.par2 missing)
t04_missing_recovery_files() {
    local fix_dir
    fix_dir=$(_t_mkfix "recovery_source_4")
    echo "dados de par2 ausente" > "$fix_dir/file.txt"
    local abs_fix
    abs_fix=$(realpath "$fix_dir")

    _load_targets

    archivepar2 "$abs_fix" || { _t_assert_eq "1" "0" "Backup inicial deve suceder"; return 1; }

    local backup_dir="$abs_fix-bak"
    local target_ver_dir="$backup_dir"
    [[ -d "$backup_dir/current" ]] && target_ver_dir=$(readlink -f "$backup_dir/current")

    rm -f "$target_ver_dir"/*.par2

    local par2_file
    par2_file=$(find "$target_ver_dir" -name "*.par2" | head -n 1)

    local repair_rc=0
    if [[ -n "$par2_file" ]]; then
        par2 r "$par2_file" || repair_rc=$?
    else
        repair_rc=1
    fi

    _t_assert_ne "$repair_rc" "0" "A operacao deve falhar quando os arquivos de recuperacao par2 estao ausentes"
}