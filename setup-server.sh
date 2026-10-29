#!/usr/bin/env bash
# Универсальная настройка VPS под self-hosted Tailscale-совместимую сеть:
#   Headscale (control plane) + Headplane (web-админка) + dnsmasq (split-DNS) + nginx (TLS).
#
# Запуск:  sudo bash setup-server.sh
# Скрипт интерактивный и идемпотентный:
#   - все параметры спрашивает с объяснением (значения по умолчанию — из прошлой конфигурации);
#   - при повторном запуске видит, что уже установлено, и предлагает только перенастройку.

set -euo pipefail
umask 077  # секреты (api_key, cookie_secret, htpasswd, state) не должны быть читаемы всеми

HS_DIR=/opt/headscale
STATE_FILE="$HS_DIR/.setup-state"
log()  { echo -e "\e[32m[setup]\e[0m $*"; }
warn() { echo -e "\e[33m[setup]\e[0m $*"; }

[ "$(id -u)" = 0 ] || { echo "Запусти от root: sudo bash $0"; exit 1; }

# ---------- читаем прошлое состояние (идемпотентность) ----------
HOSTNAME_FQDN=""; BASE_DOMAIN=""; EMAIL=""; TAILNET_IP=""; HS_USER="tailadmin"
# shellcheck disable=SC1091 # путь фиксирован, файл создаётся этим же скриптом под root с правами 600
[ -f "$STATE_FILE" ] && source "$STATE_FILE"
FIRST_RUN=0; [ -z "$HOSTNAME_FQDN" ] && FIRST_RUN=1

# ---------- хелперы диалога ----------
ask() { # ask "пояснение" "переменная" "default"
  local prompt="$1" var="$2" def="$3" val
  if [ -n "$def" ]; then read -r -p "$prompt [$def]: " val; val="${val:-$def}"
  else read -r -p "$prompt: " val; fi
  printf -v "$var" '%s' "$val"
}
ask_ip() { # IP с проверкой на octets
  local val
  while :; do
    ask "$1" val "$2"
    if [[ "$val" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then break; fi
    warn "Не похоже на IPv4, попробуй ещё раз"
  done
  printf -v "$3" '%s' "$val"
}

echo "=============================================="
echo " Настройка tailnet-сервера (Headscale+Headplane)"
echo "=============================================="

if [ "$FIRST_RUN" = 1 ]; then
  log "Первый запуск: спрошу базовые параметры."
else
  log "Найдена конфигурация: host=$HOSTNAME_FQDN ip=$TAILNET_IP домен=$BASE_DOMAIN"
  read -r -p "Перенастроить базовые параметры (домены/IP)? [y/N]: " reconf
  reconf="${reconf:-N}"
fi

if [ "$FIRST_RUN" = 1 ] || [ "$reconf" = "y" ] || [ "$reconf" = "Y" ]; then
  echo
  echo "1) Полное DNS-имя этого сервера (FQDN)."
  echo "   Требуется A-запись, указывающая на публичный IP этого VPS."
  echo "   По этому имени клиенты будут находить control plane, а на нём же будет админка."
  ask "   Имя сервера (например lan.example.com)" HOSTNAME_FQDN "$HOSTNAME_FQDN"

  echo
  echo "2) Базовая зона DNS, которую tailnet будет резолвить сам (split-DNS)."
  echo "   Обычно это домен, где живёт имя сервера: для lan.example.com — example.com."
  BASE_DOMAIN_GUESS="${BASE_DOMAIN:-${HOSTNAME_FQDN#*.}}"
  ask "   Базовая зона" BASE_DOMAIN "$BASE_DOMAIN_GUESS"

  echo
  echo "3) Email для Let's Encrypt (уведомления о сертификатах)."
  ask "   Email" EMAIL "$EMAIL"

  echo
  echo "4) IP этого сервера ВНУТРИ tailnet (из подсети 100.64.0.0/10)."
  echo "   Headscale раздаёт адреса последовательно с 100.64.0.1; чтобы сервер не менял адрес"
  echo "   при добавлении устройств, удобно закрепить за ним высокий адрес, например 100.64.0.4."
  echo "   (Именно этот IP будет DNS-резолвером tailnet.)"
  ask_ip "   Tailnet-IP сервера" "100.64.0.4" TAILNET_IP

  echo
  echo "5) Имя пользователя Headscale (владелец всех устройств, по умолчанию tailadmin)."
  ask "   Пользователь" HS_USER "$HS_USER"
fi

# ---------- basic auth ----------
echo
echo "6) Админка (/admin) дополнительно защищается HTTP basic-auth."
NEED_AUTH="yes"; [ -f /etc/nginx/.htpasswd_headplane ] && NEED_AUTH="no"
read -r -p "   Использовать basic-auth для админки? [Y/n]: " answ
case "${answ:-$NEED_AUTH}" in
  n|N|no|NO) NEED_AUTH="no" ;;
  *) NEED_AUTH="yes" ;;
esac
if [ "$NEED_AUTH" = "yes" ]; then
  ask "   Логин" AUTH_USER "admin"
  while :; do
    read -r -s -p "   Пароль (или Enter = сгенерировать): " pw1; echo
    [ -z "$pw1" ] && { PW=$(openssl rand -base64 18 | tr -d '/+='; ); break; }
    read -r -s -p "   Повтори пароль: " pw2; echo
    [ "$pw1" = "$pw2" ] && { PW="$pw1"; break; }
    warn "Пароли не совпали"
  done
  printf '%s:%s\n' "$AUTH_USER" "$(openssl passwd -6 "$PW")" > /etc/nginx/.htpasswd_headplane
  chmod 640 /etc/nginx/.htpasswd_headplane; chown root:www-data /etc/nginx/.htpasswd_headplane
  log "basic-auth записан ($AUTH_USER)"
elif [ -f /etc/nginx/.htpasswd_headplane ]; then
  read -r -p "   basic-auth уже настроен — отключить (убрать защиту)? [y/N]: " da
  [ "${da:-N}" = "y" ] && rm -f /etc/nginx/.htpasswd_headplane && log "basic-auth отключён"
fi

mkdir -p "$HS_DIR"/{config,data,headplane-data,backups}

# ---------- 1. пакеты ----------
command -v docker >/dev/null || {
  log "ставлю docker..."
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq && apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
}
apt-get install -y -qq nginx dnsmasq certbot python3-certbot-nginx 2>/dev/null || \
  { apt-get update -qq; apt-get install -y -qq nginx dnsmasq certbot python3-certbot-nginx; }
command -v tailscaled >/dev/null || { log "ставлю tailscale (хост как узел tailnet)"; curl -fsSL https://tailscale.com/install.sh | sh; }

# ---------- 2. конфиг headscale ----------
if [ ! -f "$HS_DIR/config/config.yaml" ]; then
  log "пишу config.yaml"
  cat > "$HS_DIR/config/config.yaml" <<EOF
server_url: https://${HOSTNAME_FQDN}
listen_addr: 0.0.0.0:8080
metrics_listen_addr: 127.0.0.1:9090
trusted_proxies:
  - 172.30.0.0/24
noise:
  private_key_path: /var/lib/headscale/noise_private.key
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential
derp:
  server:
    enabled: true
    region_id: 900
    region_code: main
    region_name: Main VPS
    verify_clients: true
    stun_listen_addr: 0.0.0.0:3478
    private_key_path: /var/lib/headscale/derp_server_private.key
    automatically_add_embedded_derp_region: true
  paths: []
  auto_update_enabled: false
database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite
dns:
  magic_dns: true
  base_domain: tail.${BASE_DOMAIN}
  override_local_dns: false
  nameservers:
    global: []
    split:
      "${BASE_DOMAIN}":
        - ${TAILNET_IP}
  search_domains: []
  extra_records:
    - name: "${HOSTNAME_FQDN}"
      type: A
      value: "${TAILNET_IP}"
policy:
  mode: file
  path: /etc/headscale/policy.hujson
log:
  level: info
EOF
  echo '{
  "acls": [{"action": "accept", "src": ["*"], "dst": ["*:*"]}],
  "tagOwners": {},
  "autoApprovers": {}
}' > "$HS_DIR/config/policy.hujson"
  chmod 600 "$HS_DIR/config/config.yaml" "$HS_DIR/config/policy.hujson"
else
  log "config.yaml уже есть — не трогаю"
fi

# ---------- 3. compose ----------
if [ ! -f "$HS_DIR/docker-compose.yml" ]; then
  log "пишу docker-compose.yml"
  cat > "$HS_DIR/docker-compose.yml" <<'EOF'
services:
  headscale:
    image: ghcr.io/juanfont/headscale:v0.29.3
    container_name: headscale
    restart: unless-stopped
    command: serve
    volumes:
      - ./config:/etc/headscale:ro
      - ./data:/var/lib/headscale
    ports:
      - "127.0.0.1:8080:8080"
      - "3478:3478/udp"
    networks:
      headscale:
        ipv4_address: 172.30.0.2
  headplane:
    image: ghcr.io/tale/headplane:latest
    container_name: headplane
    restart: unless-stopped
    depends_on:
      - headscale
    volumes:
      - ./config/headplane.yaml:/etc/headplane/config.yaml:ro
      - ./config:/etc/headscale:ro
      - ./data:/var/lib/headscale:ro
      - ./headplane-data:/var/lib/headplane
    ports:
      - "127.0.0.1:3000:3000"
    networks:
      headscale:
        ipv4_address: 172.30.0.3
networks:
  headscale:
    name: headscale
    ipam:
      config:
        - subnet: 172.30.0.0/24
EOF
fi
docker compose -f "$HS_DIR/docker-compose.yml" up -d headscale >/dev/null 2>&1 || true
sleep 2

# ---------- 4. пользователь headscale ----------
HS_USER_ID=$(docker exec headscale headscale users list 2>/dev/null | awk -v u="$HS_USER" '$0 ~ u {print $1; exit}')
if [ -z "$HS_USER_ID" ]; then
  docker exec headscale headscale users create "$HS_USER" >/dev/null && log "создан пользователь $HS_USER"
  HS_USER_ID=$(docker exec headscale headscale users list 2>/dev/null | awk -v u="$HS_USER" '$0 ~ u {print $1; exit}')
fi

# ---------- 5. headplane + API-ключ ----------
HS_API_KEY=$(docker exec headscale headscale apikeys create --expiration 90d)
if [ ! -f "$HS_DIR/config/headplane.yaml" ]; then
  log "пишу headplane.yaml"
  SECRET=$(openssl rand -base64 24 | tr -d '/+=')
  cat > "$HS_DIR/config/headplane.yaml" <<EOF
server:
  host: "0.0.0.0"
  port: 3000
  base_url: "https://${HOSTNAME_FQDN}"
  cookie_secret: "${SECRET}"
  cookie_secure: true
  cookie_max_age: 86400
headscale:
  url: "http://172.30.0.2:8080"
  public_url: "https://${HOSTNAME_FQDN}"
  config_path: "/etc/headscale/config.yaml"
  api_key: "${HS_API_KEY}"
integration:
  docker:
    enabled: false
EOF
  chmod 600 "$HS_DIR/config/headplane.yaml"
else
  sed -i "s|api_key: .*|api_key: \"${HS_API_KEY}\"|" "$HS_DIR/config/headplane.yaml"
  log "headplane.yaml: api_key обновлён"
fi
docker compose -f "$HS_DIR/docker-compose.yml" up -d >/dev/null

# ---------- 6. dnsmasq ----------
if [ ! -f /etc/dnsmasq.d/tailnet.conf ]; then
  log "пишу /etc/dnsmasq.d/tailnet.conf"
  cat > /etc/dnsmasq.d/tailnet.conf <<EOF
# split-DNS для tailnet-клиентов
listen-address=${TAILNET_IP}
bind-interfaces
no-resolv
server=1.1.1.1
server=1.0.0.1
address=/${HOSTNAME_FQDN}/${TAILNET_IP}
cache-size=256
EOF
else
  log "dnsmasq-конфиг уже есть — не трогаю"
fi
systemctl enable --now dnsmasq >/dev/null 2>&1; systemctl restart dnsmasq

# ---------- 7. nginx + TLS ----------
if [ ! -f "/etc/nginx/sites-available/${HOSTNAME_FQDN}" ]; then
  log "пишу nginx-сайт"
  HTPASSWD_BLOCK=""
  [ "$NEED_AUTH" = "yes" ] && HTPASSWD_BLOCK=$(cat <<EOF2
        auth_basic "Admin";
        auth_basic_user_file /etc/nginx/.htpasswd_headplane;
EOF2
)
  cat > "/etc/nginx/sites-available/${HOSTNAME_FQDN}" <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${HOSTNAME_FQDN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${HOSTNAME_FQDN};

    ssl_certificate /etc/letsencrypt/live/${HOSTNAME_FQDN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${HOSTNAME_FQDN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # Админка: только из tailnet + (опц.) basic auth; чужие получают стандартный 404
    location /admin {
        allow 127.0.0.1;
        allow 100.64.0.0/10;
        deny  all;
        error_page 403 = @notfound;
${HTPASSWD_BLOCK}
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location @notfound {
        return 404 '<!DOCTYPE html><html><head><title>404 Not Found</title></head><body><hr><center>nginx</center></body></html>';
    }

    location /health {
        allow 127.0.0.1;
        allow 100.64.0.0/10;
        deny  all;
        error_page 403 = @notfound;
        proxy_pass http://127.0.0.1:3000/health;
    }

    # Всё остальное — control plane Headscale + DERP (публично)
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$connection_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }
}
EOF
  ln -sf "/etc/nginx/sites-available/${HOSTNAME_FQDN}" /etc/nginx/sites-enabled/
  rm -f /etc/nginx/sites-enabled/default
fi

if [ ! -f "/etc/letsencrypt/live/${HOSTNAME_FQDN}/fullchain.pem" ]; then
  log "получаю TLS-сертификат"
  certbot certonly --webroot -w /var/www/html -d "$HOSTNAME_FQDN" --non-interactive --agree-tos -m "$EMAIL"
fi
nginx -t 2>/dev/null && systemctl enable --now nginx >/dev/null 2>&1 && systemctl reload nginx
(crontab -l 2>/dev/null | grep -v 'certbot renew'; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -

# ---------- 8. exit node ----------
# VPS выпускает клиентский интернет-трафик через свой публичный интерфейс.
# Headscale отдельно должен одобрить объявленные маршруты, иначе клиенты его не увидят.
DEFAULT_IFACE=$(ip route show default | awk 'NR==1 {print $5}')
if [ -n "$DEFAULT_IFACE" ] && tailscale ip -4 >/dev/null 2>&1; then
  cat > /etc/sysctl.d/99-tailnet-exit-node.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
  sysctl --system >/dev/null
  tailscale set --advertise-exit-node
  VPS_NODE_ID=$(docker exec headscale headscale nodes list -o json | \
    awk -v ip="$TAILNET_IP" '/"id":/ { gsub(/[^0-9]/, "", $0); id=$0 } index($0, "\"" ip "\"") { print id; exit }')
  if [ -n "$VPS_NODE_ID" ]; then
    docker exec headscale headscale nodes approve-routes --identifier "$VPS_NODE_ID" --routes '0.0.0.0/0,::/0' >/dev/null
  else
    warn "не удалось определить ID VPS-узла: одобри 0.0.0.0/0 и ::/0 в Headplane"
  fi
else
  warn "VPS ещё не подключён к tailnet — exit node будет настроен при следующем запуске скрипта"
fi

# ---------- 9. firewall ----------
ufw allow 22/tcp  >/dev/null 2>&1 || true
ufw allow 80/tcp  >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true
ufw allow 3478/udp comment "headscale stun" >/dev/null 2>&1 || true
if ip link show tailscale0 >/dev/null 2>&1; then
  ufw allow in on tailscale0 to any port 53 proto udp comment "tailnet DNS" >/dev/null 2>&1 || true
  ufw allow in on tailscale0 to any port 53 proto tcp comment "tailnet DNS tcp" >/dev/null 2>&1 || true
  ufw route allow in on tailscale0 out on "$DEFAULT_IFACE" comment "tailnet exit node" >/dev/null 2>&1 || true
  ufw route allow in on "$DEFAULT_IFACE" out on tailscale0 comment "tailnet exit node return" >/dev/null 2>&1 || true
else
  warn "tailscale0 ещё нет — после подключения хоста к tailnet (шаг ниже) перезапусти скрипт для DNS-правил"
fi
ufw --force enable >/dev/null

# ---------- 10. хелпер tailnet-add ----------
if [ -f "$(dirname "$0")/tailnet-add" ]; then
  install -m 755 "$(dirname "$0")/tailnet-add" /usr/local/bin/tailnet-add
  log "установлен /usr/local/bin/tailnet-add (печать команд подключения устройств)"
fi

# ---------- 11. сам VPS как узел tailnet ----------
if ! tailscale status >/dev/null 2>&1 || tailscale status 2>/dev/null | grep -q 'Logged out'; then
  systemctl enable --now tailscaled >/dev/null 2>&1 || true
  log "Хост ещё не в tailnet. Подключи его (нужен для DNS ${TAILNET_IP}):"
  echo "    KEY=\$(docker exec headscale headscale preauthkeys create --user ${HS_USER_ID} --reusable --expiration 1h)"
  echo "    tailscale up --login-server=https://${HOSTNAME_FQDN} --authkey=\"\$KEY\""
  warn "после подключения: перезапусти этот скрипт (добавит UFW/DNS-правила и проверки)"
fi

# ---------- 12. бэкапы ----------
(crontab -l 2>/dev/null | grep -v "backups/headscale-"; echo "30 4 * * * tar czf ${HS_DIR}/backups/headscale-\$(date +\%F).tar.gz -C ${HS_DIR} config data headplane-data 2>/dev/null") | crontab -

# ---------- состояние ----------
cat > "$STATE_FILE" <<EOF
HOSTNAME_FQDN="$HOSTNAME_FQDN"
BASE_DOMAIN="$BASE_DOMAIN"
EMAIL="$EMAIL"
TAILNET_IP="$TAILNET_IP"
HS_USER="$HS_USER"
HS_USER_ID="$HS_USER_ID"
EOF
chmod 600 "$STATE_FILE"

# ---------- проверки + вывод ----------
log "=== Проверки ==="
docker exec headscale headscale users list >/dev/null 2>&1 && echo "OK: headscale" || echo "FAIL: headscale"
curl -sf "https://${HOSTNAME_FQDN}/key" -o /dev/null && echo "OK: control plane https://${HOSTNAME_FQDN}/key" || echo "FAIL: /key"

echo
log "==================== ВАЖНО: API-ключ Headplane ===================="
echo "  $HS_API_KEY"
echo "  Это ключ администратора Headscale (живёт 90 дней). При первом входе"
echo "  в админку ${HOSTNAME_FQDN}/admin вставь его в поле API Key."
echo "  Новый ключ, когда истечёт:  docker exec headscale headscale apikeys create --expiration 90d"
echo "  (и обновить api_key в $HS_DIR/config/headplane.yaml, потом: docker compose -f $HS_DIR/docker-compose.yml restart headplane)"
echo "==================================================================="
[ -s /etc/nginx/.htpasswd_headplane ] && log "basic-auth: пользователь задан при вводе выше"
log "Готово. Админка: https://${HOSTNAME_FQDN}/admin (только из tailnet)"

