#!/usr/bin/env bash
# Regenerate the nginx real_ip list from Cloudflare's published ranges.
# Keeps the current file when the download looks wrong or nginx rejects the result.
set -euo pipefail

target=/etc/nginx/conf.d/cloudflare-realip.conf
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

v4=$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v4)
v6=$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v6)

if [[ $(grep -cE '^[0-9a-f:.]+/[0-9]+$' <<<"$v4"$'\n'"$v6") -lt 10 ]]; then
    echo "Cloudflare IP list looks wrong; keeping $target" >&2
    exit 1
fi

{
    echo "# Managed by update-cloudflare-realip.sh — generated $(date -u +%FT%TZ)"
    printf '%s\n%s\n' "$v4" "$v6" | sed '/^$/d; s/.*/set_real_ip_from &;/'
    echo "real_ip_header CF-Connecting-IP;"
} >"$tmp"

if cmp -s "$tmp" "$target" 2>/dev/null; then
    exit 0
fi

backup=""
if [[ -f "$target" ]]; then
    backup="$target.bak"
    cp "$target" "$backup"
fi
install -m 0644 "$tmp" "$target"

if nginx -t 2>/dev/null; then
    systemctl reload nginx
else
    echo "nginx rejected the new list; restoring the previous one" >&2
    if [[ -n "$backup" ]]; then
        mv "$backup" "$target"
    else
        rm -f "$target"
    fi
    exit 1
fi
