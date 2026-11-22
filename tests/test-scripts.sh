#!/usr/bin/env bash
# Local checks that need no server: syntax of every script, the input validators, the nginx
# config renderer, and run.sh's refusals (it must refuse BEFORE calling ssh).
#   bash tests/test-scripts.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/skills/server-ops/scripts"
fail=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fail=1; }

echo "== Syntax (bash -n), alone and as the server sees it (lib.sh + script)"
for f in "$S"/*.sh "$ROOT"/hooks/*.sh; do bash -n "$f" && ok "bash -n $(basename "$f")" || bad "bash -n $f"; done
for s in inventory provision-server create-site deploy-site issue-certificate delete-site; do
    cat "$S/lib.sh" "$S/$s.sh" | bash -n && ok "lib.sh + $s.sh" || bad "lib.sh + $s.sh"
done

echo "== Validators (a subshell per check: die() exits)"
accept() { (source "$S/lib.sh"; "$1" "$2") >/dev/null 2>&1 && ok "$1 accepts '$2'" || bad "$1 should accept '$2'"; }
reject() { (source "$S/lib.sh"; "$1" "$2") >/dev/null 2>&1 && bad "$1 should reject '$2'" || ok "$1 rejects '$2'"; }

accept validate_domain example.com
accept validate_domain app.shop-1.co.uk
reject validate_domain Example.com
reject validate_domain 'example.com;reboot'
reject validate_domain ../etc
reject validate_domain -bad.com
reject validate_domain 'a.b'
reject validate_domain 'example.com/x'
accept validate_web_dir public
accept validate_web_dir dist/public
reject validate_web_dir ../x
reject validate_web_dir public/..
reject validate_web_dir ./public
reject validate_web_dir /abs
accept validate_php 8.4
reject validate_php 8.2
reject validate_php '8.4 && reboot'
accept validate_repository git@github.com:acme/shop.git
accept validate_repository https://github.com/acme/shop
accept validate_repository https://git.example.com:8443/acme/shop.git
reject validate_repository 'git@github.com:-oProxyCommand=x'
reject validate_repository 'https://github.com/-acme/shop'
reject validate_repository 'file:///etc/passwd'
reject validate_repository 'ext::sh -c reboot'
accept validate_branch main
accept validate_branch feature/x-1
reject validate_branch -f
reject validate_branch a..b
reject validate_branch foo.lock
reject validate_branch 'a b'
reject validate_public_domain shop.test
accept validate_public_domain shop.example.com

echo "== nginx config renderer"
cfg="$(source "$S/lib.sh"; nginx_https_config shop.example.com /home/servio/shop.example.com/public 8.4)"
for want in '# Managed by Servio' 'server_name shop.example.com;' 'root /home/servio/shop.example.com/public;' \
            'fastcgi_pass unix:/run/php/php8.4-fpm.sock;' 'try_files $uri $uri/ /index.php?$query_string;' \
            'return 301 https://$host$request_uri;' 'location ~ ^/index\.php(/|$) {' \
            'fastcgi_split_path_info ^(.+\.php)(/.*)$;' 'fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;' \
            'ssl_certificate_key /etc/letsencrypt/live/shop.example.com/privkey.pem;' 'root /var/www/letsencrypt;' \
            'location ~ /\.(?!well-known).* {'; do
    printf '%s\n' "$cfg" | grep -qF -- "$want" && ok "https has: $want" || bad "https missing: $want"
done
[ "$(printf '%s\n' "$cfg" | grep -c '{')" = "$(printf '%s\n' "$cfg" | grep -c '}')" ] && ok "https braces balance" || bad "https braces don't balance"
http="$(source "$S/lib.sh"; nginx_http_config shop.example.com /home/servio/shop.example.com/public 8.4)"
printf '%s\n' "$http" | grep -q 'listen 443' && bad "http config has 443" || ok "http config has no 443"

echo "== read_site_settings reads web dir + PHP back from a rendered config"
tmp="$(mktemp -d)"
got="$(source "$S/lib.sh"; nginx_available() { echo "$tmp/$1"; }
       nginx_http_config shop.example.com /home/servio/shop.example.com/dist/public 8.3 > "$tmp/shop.example.com"
       read_site_settings shop.example.com)"
[ "$got" = "dist/public 8.3" ] && ok "read back: $got" || bad "read back '$got'"
got="$(source "$S/lib.sh"; nginx_available() { echo "$tmp/$1"; }
       echo "server { root /var/www; }" > "$tmp/hand.example.com"
       read_site_settings hand.example.com 2>&1)" && bad "hand-made config accepted" || ok "hand-made config refused"
rm -rf "$tmp"

echo "== run.sh refuses bad input before any ssh (PATH has no ssh here)"
refuse() { PATH="/nonexistent:/usr/bin:/bin" bash "$S/run.sh" "$@" >/dev/null 2>&1; [ $? = 64 ] && ok "run.sh refuses: $*" || bad "run.sh should refuse: $*"; }
refuse '-oProxyCommand=calc' inventory.sh
refuse web1 'rm.sh'
refuse web1 ../lib.sh
refuse web1 create-site.sh 'shop.com;reboot'
refuse web1 create-site.sh 'shop.com public' 8.4
refuse web1 deploy-site.sh 'shop.com' '$(reboot)'
refuse web1

[ "$fail" = 0 ] && echo "All script tests passed." || { echo "Some script tests FAILED."; exit 1; }
