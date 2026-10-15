#!/usr/bin/env bash
# Подключение Linux-сервера к tailnet (headless, без GUI).
#
# Запуск:  sudo bash setup-linux.sh <server-url> <preauthkey> [доп. опции tailscale up]
# Пример:  sudo bash setup-linux.sh lan.example.com hskey-auth-... --hostname build1
# Ключ:    на сервере tailnet выполнить `sudo tailnet-add` (напечатает готовые команды)
#
# По умолчанию --accept-dns=false: сервер сохраняет свой /etc/resolv.conf
# (tailnet-DNS нужен в основном десктопам). Узлы tailnet доступны по IP и tailnet-именам
# без DNS (tailscale ping <имя> работает и так).

set -euo pipefail
[ $# -ge 2 ] || { echo "Использование: sudo bash $0 <server-url> <preauthkey> [опции tailscale up]" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "Запусти от root (sudo)" >&2; exit 1; }

URL="$1"; KEY="$2"; shift 2
case "$URL" in http*) ;; *) URL="https://$URL";; esac

command -v tailscale >/dev/null || { echo "Ставлю tailscale..."; curl -fsSL https://tailscale.com/install.sh | sh; }
systemctl enable --now tailscaled

tailscale up --login-server="$URL" --authkey="$KEY" --accept-dns=false "$@"

echo; echo "=== Статус ==="; tailscale status
echo "Готово. Проверка: tailscale ping <имя-узла>"
