#!/usr/bin/env bash
# First-run setup for infra/group_vars/production.yml.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_file="${script_dir}/../group_vars/production.yml"

if [[ ! -f "$config_file" ]]; then
    printf '找不到 %s\n' "$config_file" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    printf '請先安裝 Python 3 再執行。\n' >&2
    exit 1
fi
if [[ ! -t 0 ]]; then
    printf '請在互動式終端機執行此腳本。\n' >&2
    exit 1
fi
if grep -Eq '^mariadb_enabled: false([[:space:]]|$)' "$config_file" || ! grep -Eq '^mariadb_root_password: "?CHANGE_ME"?$' "$config_file"; then
    printf '設定檔已選用外部資料庫或 MariaDB 密碼已不是預設值；為避免覆蓋現有設定，請直接編輯 %s。\n' "$config_file" >&2
    exit 1
fi

umask 077
tmp_file="$(mktemp "${config_file}.tmp.XXXXXX")"
trap 'rm -f "$tmp_file"' EXIT

prompt_default() {
    local label="$1" default="$2" answer
    read -r -p "$label [$default]：" answer
    reply="${answer:-$default}"
}

prompt_bool() {
    local label="$1" default="$2" answer
    while true; do
        read -r -p "$label [$default]（true／false）：" answer
        answer="${answer:-$default}"
        case "$answer" in
            true|false) reply="$answer"; return ;;
            *) printf '請輸入 true 或 false。\n' >&2 ;;
        esac
    done
}

prompt_positive_int() {
    local label="$1" default="$2" answer
    while true; do
        read -r -p "$label [$default]：" answer
        answer="${answer:-$default}"
        if [[ "$answer" =~ ^[0-9]+$ ]] && (( 10#$answer >= 1 && 10#$answer <= 1048576 )); then
            reply="$((10#$answer))"
            return
        fi
        printf '請輸入 1 到 1048576 的整數。\n' >&2
    done
}

prompt_memory_size() {
    local label="$1" default="$2" allow_b="${3:-false}" answer
    while true; do
        read -r -p "$label [$default]：" answer
        answer="${answer:-$default}"
        if [[ "$answer" =~ ^[1-9][0-9]*[MmGg]$ ]] ||
            { [[ "$allow_b" == true ]] && [[ "$answer" =~ ^[1-9][0-9]*[MmGg][Bb]$ ]]; }; then
            reply="$answer"
            return
        fi
        printf '請輸入帶 M 或 G 單位的容量，例如 256M 或 1G。\n' >&2
    done
}

yaml_quote() {
    local value="$1"
    value=${value//\'/\'\'}
    printf "'%s'" "$value"
}

yaml_ip_list() {
    local input="$1" item result="" quoted
    local -a items
    if [[ -z "${input//[[:space:],]/}" ]]; then
        printf '[]'
        return
    fi
    IFS=',' read -r -a items <<< "$input"
    for item in "${items[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ -n "$item" ]] || continue
        if ! python3 -c 'import ipaddress,sys; ipaddress.ip_network(sys.argv[1], strict=False)' "$item" 2>/dev/null; then
            printf '無效的 IP／CIDR：%s\n' "$item" >&2
            return 1
        fi
        quoted="$(yaml_quote "$item")"
        result+="${result:+, }${quoted}"
    done
    printf '[%s]' "$result"
}

printf '首次設定 production.yml；按 Enter 使用預設值。\n'
prompt_bool '安裝本機 MariaDB（使用 RDS／外部資料庫請選 false）' true; mariadb_enabled="$reply"
if [[ "$mariadb_enabled" == true ]] && ! command -v ansible-vault >/dev/null 2>&1; then
    printf '本機 MariaDB 密碼加密需要 ansible-vault，請先安裝 Ansible。\n' >&2
    exit 1
fi
prompt_default '時區' 'Asia/Taipei'; timezone="$reply"

default_key=''
if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
    IFS= read -r default_key < "$HOME/.ssh/id_ed25519.pub" || true
fi
if [[ -n "$default_key" ]]; then
    read -r -p 'deploy SSH 公鑰（Enter 使用 ~/.ssh/id_ed25519.pub）：' deploy_key
    deploy_key="${deploy_key:-$default_key}"
else
    read -r -p 'deploy SSH 公鑰（貼上整行）：' deploy_key
fi
if [[ -z "$deploy_key" || "$deploy_key" != *' '* ]]; then
    printf '請提供有效的 SSH 公鑰。\n' >&2
    exit 1
fi

prompt_bool '啟用 UFW' true; ufw_enabled="$reply"
read -r -p '允許 SSH 的來源 IP／CIDR（逗號分隔，空白代表所有來源）：' ssh_ips
ssh_list="$(yaml_ip_list "$ssh_ips")"
read -r -p '允許抓取 Node Exporter 的 IP／CIDR（逗號分隔，可留空）：' monitoring_ips
monitoring_list="$(yaml_ip_list "$monitoring_ips")"

detected_cpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || printf '4')"
if [[ -r /proc/meminfo ]]; then
    detected_memory="$(awk '/^MemTotal:/ { print int(($2 + 1023) / 1024); exit }' /proc/meminfo)"
else
    memory_bytes="$(sysctl -n hw.memsize 2>/dev/null || printf '8589934592')"
    detected_memory="$((memory_bytes / 1024 / 1024))"
fi
[[ "$detected_cpu" =~ ^[0-9]+$ ]] || detected_cpu=4
[[ "$detected_memory" =~ ^[0-9]+$ ]] || detected_memory=8192
printf '\n偵測到 %s vCPU、%s MiB 記憶體；可輸入主機實際配額覆寫。\n' "$detected_cpu" "$detected_memory"
prompt_positive_int 'vCPU 數' "$detected_cpu"; cpu_count="$reply"
prompt_positive_int '記憶體（MiB）' "$detected_memory"; memory_mib="$reply"
if (( memory_mib < 2048 )); then
    printf '此 playbook 安裝多個共用服務，建議至少 2048 MiB。\n' >&2
fi

if (( memory_mib < 4096 )); then
    mariadb_buffer_default=256M redis_memory_default=128mb php_memory_default=128M
    opcache_default=128 fpm_memory_cap=8
elif (( memory_mib < 8192 )); then
    mariadb_buffer_default=256M redis_memory_default=256mb php_memory_default=256M
    opcache_default=128 fpm_memory_cap=12
elif (( memory_mib < 16384 )); then
    mariadb_buffer_default=1G redis_memory_default=512mb php_memory_default=256M
    opcache_default=256 fpm_memory_cap=24
else
    mariadb_buffer_mib=$((memory_mib / 8))
    redis_memory_mib=$((memory_mib / 16))
    (( mariadb_buffer_mib > 8192 )) && mariadb_buffer_mib=8192
    (( redis_memory_mib > 4096 )) && redis_memory_mib=4096
    mariadb_buffer_default="${mariadb_buffer_mib}M"
    redis_memory_default="${redis_memory_mib}mb"
    php_memory_default=256M opcache_default=256
    fpm_memory_cap=$((memory_mib / 512))
fi
fpm_children_default=$((cpu_count * 6))
(( fpm_children_default > fpm_memory_cap )) && fpm_children_default="$fpm_memory_cap"
mariadb_connections_default=$((cpu_count * 25))
(( mariadb_connections_default > 200 )) && mariadb_connections_default=200

prompt_default 'PHP 版本' '8.2'; php_version="$reply"
prompt_default 'Node.js 主版本' '22'; nodejs_version="$reply"
if [[ "$mariadb_enabled" == true ]]; then
    prompt_default 'MariaDB 版本' '10.11'; mariadb_version="$reply"
    if [[ ! "$mariadb_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        printf 'MariaDB 版本需為主版.次版。\n' >&2
        exit 1
    fi
fi
prompt_default 'Node Exporter 版本' '1.8.2'; node_exporter_version="$reply"
prompt_default 'cachetool 版本' '9.0.0'; cachetool_version="$reply"
if [[ ! "$php_version" =~ ^[0-9]+\.[0-9]+$ || ! "$nodejs_version" =~ ^[0-9]+$ || ! "$node_exporter_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$cachetool_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'PHP 版本需為主版.次版；Node.js 需為主版整數；Node Exporter／cachetool 需為主版.次版.修訂版。\n' >&2
    exit 1
fi

prompt_memory_size 'PHP 單一上傳上限' 20M; php_upload_max_filesize="$reply"
prompt_memory_size 'PHP POST 上限' 25M; php_post_max_size="$reply"
upload_mib="${php_upload_max_filesize%%[MmGg]*}"
post_mib="${php_post_max_size%%[MmGg]*}"
[[ "$php_upload_max_filesize" =~ [Gg]$ ]] && upload_mib=$((upload_mib * 1024))
[[ "$php_post_max_size" =~ [Gg]$ ]] && post_mib=$((post_mib * 1024))
if (( post_mib < upload_mib )); then
    printf 'PHP POST 上限不能小於單一上傳上限。\n' >&2
    exit 1
fi

printf '\n依主機規格建議的共用服務資源上限；按 Enter 接受，亦可逐項覆寫。\n'
if [[ "$mariadb_enabled" == true ]]; then
    prompt_memory_size 'MariaDB InnoDB buffer pool' "$mariadb_buffer_default"; mariadb_buffer_pool="$reply"
    prompt_positive_int 'MariaDB 最大連線數' "$mariadb_connections_default"; mariadb_max_connections="$reply"
fi
prompt_memory_size 'Redis maxmemory' "$redis_memory_default" true; redis_maxmemory="$reply"
prompt_memory_size 'PHP memory_limit' "$php_memory_default"; php_memory_limit="$reply"
prompt_positive_int 'OPcache 記憶體（MiB）' "$opcache_default"; php_opcache_memory_consumption="$reply"
prompt_positive_int 'PHP-FPM max_children' "$fpm_children_default"; php_fpm_max_children="$reply"
php_fpm_start_servers="$cpu_count"
(( php_fpm_start_servers > 4 )) && php_fpm_start_servers=4
(( php_fpm_start_servers > php_fpm_max_children )) && php_fpm_start_servers="$php_fpm_max_children"
php_fpm_min_spare_servers="$php_fpm_start_servers"
php_fpm_max_spare_servers=$((php_fpm_start_servers * 2))
(( php_fpm_max_spare_servers > php_fpm_max_children )) && php_fpm_max_spare_servers="$php_fpm_max_children"

prompt_bool '啟用 Grafana Alloy' false; alloy_enabled="$reply"
loki_url=''
if [[ "$alloy_enabled" == true ]]; then
    read -r -p 'Loki push URL：' loki_url
    if [[ ! "$loki_url" =~ ^https?://[^[:space:]]+$ ]]; then
        printf '啟用 Alloy 時請提供 http(s) Loki URL。\n' >&2
        exit 1
    fi
fi

printf '\n設定摘要：%s vCPU／%s MiB；PHP-FPM=%s children；Redis=%s。\n' \
    "$cpu_count" "$memory_mib" "$php_fpm_max_children" "$redis_maxmemory"
printf 'UFW＝%s、SSH 來源＝%s、監控來源＝%s、Alloy＝%s、本機 MariaDB＝%s。\n' \
    "$ufw_enabled" "$ssh_list" "$monitoring_list" "$alloy_enabled" "$mariadb_enabled"
if [[ "$mariadb_enabled" == true ]]; then
    printf 'MariaDB buffer pool＝%s；最大連線數＝%s。\n' "$mariadb_buffer_pool" "$mariadb_max_connections"
    while true; do
        read -r -s -p 'MariaDB root 密碼：' db_password
        printf '\n'
        read -r -s -p '再輸入一次密碼：' db_password_confirm
        printf '\n'
        if [[ -n "$db_password" && "$db_password" != CHANGE_ME && "$db_password" == "$db_password_confirm" ]]; then
            break
        fi
        printf '密碼不可為空、CHANGE_ME，且兩次輸入必須相同。\n' >&2
    done
    unset db_password_confirm

    printf 'MariaDB 密碼會以 Ansible Vault 加密；接下來請輸入 Vault 密碼並妥善保存。\n'
    vault_output="$(printf '%s' "$db_password" | ansible-vault encrypt_string --ask-vault-pass --stdin-name mariadb_root_password)"
    unset db_password
    if [[ "$vault_output" != *'mariadb_root_password: !vault |'* ]]; then
        printf 'Ansible Vault 未產生預期的加密變數，設定未寫入。\n' >&2
        exit 1
    fi
    vault_entry="mariadb_root_password: !vault |${vault_output#*mariadb_root_password: !vault |}"
    unset vault_output

fi

while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$mariadb_enabled" == false && "$line" == mariadb_* && "$line" != mariadb_enabled:* ]]; then
        printf '%s\n' "$line"
        continue
    fi
    case "$line" in
        mariadb_enabled:*) printf 'mariadb_enabled: %s\n' "$mariadb_enabled" ;;
        deploy_ssh_public_key:*) printf 'deploy_ssh_public_key: %s\n' "$(yaml_quote "$deploy_key")" ;;
        timezone:*) printf 'timezone: %s\n' "$(yaml_quote "$timezone")" ;;
        ssh_hardening_enabled:*) printf 'ssh_hardening_enabled: false\n' ;;
        '# ufw_enabled: true') printf 'ufw_enabled: %s\n' "$ufw_enabled" ;;
        ufw_enabled:*) printf 'ufw_enabled: %s\n' "$ufw_enabled" ;;
        ssh_allowed_ips:*) printf 'ssh_allowed_ips: %s\n' "$ssh_list" ;;
        monitoring_allowed_ips:*) printf 'monitoring_allowed_ips: %s\n' "$monitoring_list" ;;
        php_version:*) printf 'php_version: %s\n' "$(yaml_quote "$php_version")" ;;
        cachetool_version:*) printf 'cachetool_version: %s\n' "$(yaml_quote "$cachetool_version")" ;;
        php_upload_max_filesize:*) printf 'php_upload_max_filesize: %s\n' "$(yaml_quote "$php_upload_max_filesize")" ;;
        php_post_max_size:*) printf 'php_post_max_size: %s\n' "$(yaml_quote "$php_post_max_size")" ;;
        php_memory_limit:*) printf 'php_memory_limit: %s\n' "$(yaml_quote "$php_memory_limit")" ;;
        php_opcache_memory_consumption:*) printf 'php_opcache_memory_consumption: %s\n' "$php_opcache_memory_consumption" ;;
        php_fpm_max_children:*) printf 'php_fpm_max_children: %s\n' "$php_fpm_max_children" ;;
        php_fpm_start_servers:*) printf 'php_fpm_start_servers: %s\n' "$php_fpm_start_servers" ;;
        php_fpm_min_spare_servers:*) printf 'php_fpm_min_spare_servers: %s\n' "$php_fpm_min_spare_servers" ;;
        php_fpm_max_spare_servers:*) printf 'php_fpm_max_spare_servers: %s\n' "$php_fpm_max_spare_servers" ;;
        nodejs_major_version:*) printf 'nodejs_major_version: %s\n' "$(yaml_quote "$nodejs_version")" ;;
        node_exporter_version:*) printf 'node_exporter_version: %s\n' "$(yaml_quote "$node_exporter_version")" ;;
        mariadb_version:*) printf 'mariadb_version: %s\n' "$(yaml_quote "$mariadb_version")" ;;
        mariadb_innodb_buffer_pool_size:*) printf 'mariadb_innodb_buffer_pool_size: %s\n' "$(yaml_quote "$mariadb_buffer_pool")" ;;
        mariadb_max_connections:*) printf 'mariadb_max_connections: %s\n' "$mariadb_max_connections" ;;
        redis_maxmemory:*) printf 'redis_maxmemory: %s\n' "$(yaml_quote "$redis_maxmemory")" ;;
        mariadb_root_password:*) printf '%s\n' "$vault_entry" ;;
        alloy_enabled:*) printf 'alloy_enabled: %s\n' "$alloy_enabled" ;;
        loki_push_url:*) printf 'loki_push_url: %s\n' "$(yaml_quote "$loki_url")" ;;
        *) printf '%s\n' "$line" ;;
    esac
done < "$config_file" > "$tmp_file"

chmod 600 "$tmp_file"
mv "$tmp_file" "$config_file"
printf '已寫入 %s。\n' "$config_file"
if [[ "$mariadb_enabled" == true ]]; then
    printf '執行 playbook 時請加上 --ask-vault-pass。\n'
else
    printf '本機 MariaDB 已停用；RDS／外部資料庫連線請於各專案設定，本次未產生 Vault 密碼。\n'
fi
printf '首次建置維持 ssh_hardening_enabled: false；確認 deploy 可以登入後再開啟。\n'
