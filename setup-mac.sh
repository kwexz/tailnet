#!/usr/bin/env bash
# Настройка Mac-клиента tailnet: Tailscale.app (GUI из меню-бара) -> свой Headscale.
#
# Запуск:  bash setup-mac.sh [preauthkey]
#   preauthkey (опционально): создать на сервере:
#     docker exec headscale headscale preauthkeys create --user 1 --reusable --expiration 1h
#   Без ключа скрипт покажет URL — открой его и approves узел в админке.
#
# Важно:
#  - нужна версия Tailscale НЕ из App Store (standalone): App Store-клиент заперт на облако Tailscale
#    и не принимает адрес своего сервера. Ставим через brew cask.
#  - единственный ручной шаг: разрешить сетевое расширение Tailscale (мак сам покажет диалог).
#  - по SSH: сессия не должна идти через Tailscale (скрипт может перезапускать tailscaled).

set -euo pipefail
SERVER_URL="${TS_SERVER_URL:-}"
AUTHKEY="${1:-}"
TS_APP=/Applications/Tailscale.app/Contents/MacOS/Tailscale

echo "=== Настройка Mac-клиента tailnet ==="
[ -z "$SERVER_URL" ] && read -r -p "1) Адрес сервера (например https://lan.example.com): " SERVER_URL
case "$SERVER_URL" in http*) ;; *) SERVER_URL="https://$SERVER_URL";; esac
HOST_FQDN="${SERVER_URL#*://}"
HOST_FQDN="${HOST_FQDN%%/*}"
HOST_FQDN="${HOST_FQDN%%:*}"

echo "[1/4] Tailscale.app (standalone)..."
if [ ! -d /Applications/Tailscale.app ]; then
  if command -v brew >/dev/null; then brew install --cask tailscale
  else
    echo "  brew не найден. Скачай standalone-клиент: https://tailscale.com/download/mac"
    read -r -p "  Установил вручную? [y/N] " ok; [ "${ok:-N}" = "y" ] || exit 1
  fi
else
  echo "  уже установлена"
fi

echo "[2/4] Направляю на $SERVER_URL ..."
defaults write io.tailscale.ipn.macos ControlURL "$SERVER_URL"

echo "[3/4] Запускаю приложение (если попап сетевого расширения — разреши в Системных настройках)..."
osascript -e 'tell application "Tailscale" to activate' 2>/dev/null || open -a Tailscale
sleep 3

echo "[4/4] Подключение..."
if [ -n "$AUTHKEY" ]; then
  sudo "$TS_APP" up --login-server="$SERVER_URL" --authkey="$AUTHKEY"
else
  sudo "$TS_APP" up --login-server="$SERVER_URL"
fi

echo
echo "=== Статус ==="
"$TS_APP" status || true
echo
echo "Готово. Управление — иконка Tailscale в меню-баре (статус, IP, exit node)."
echo "Если имя $HOST_FQDN не резолвится при включённом VPN — добавь 100.64.0.0/10 в исключения VPN (split tunneling)."
