# Развёртывание

## Предусловия

- VPS с Ubuntu и root-доступом.
- A-запись вида `lan.example.com` → публичный IP VPS (примеры в этом репозитории
  используют `lan.example.com` / `example.com` — это плейсхолдеры, замени на свои).
- Порты `22/80/443/tcp` и `3478/udp`, доступные из интернета.
- Репозиторий склонирован на VPS; скрипты **не запускать** на своей рабочей машине.

## Сервер: установка с нуля

```bash
sudo bash setup-server.sh
```

Скрипт интерактивный. Спросит:

1. FQDN сервера (например `lan.example.com`) — нужна A-запись на VPS;
2. базовую DNS-зону (обычно домен без первого компонента: для `lan.example.com` — `example.com`);
3. email для Let's Encrypt;
4. tailnet-IP сервера (по умолчанию `100.64.0.4`, диапазон `100.64.0.0/10`);
5. имя пользователя Headscale (по умолчанию `tailadmin`);
6. логин/пароль basic-auth для `/admin` (Enter = сгенерировать; хеш SHA-512 crypt).

В конце скрипт:

- выведет **API-ключ Headplane** (живёт 90 дней) — вставь его при первом входе в админку;
- если хост ещё не в tailnet, покажет команду подключения самого VPS:

```bash
KEY=$(docker exec headscale headscale preauthkeys create --user <id> --reusable --expiration 1h)
tailscale up --login-server=https://lan.example.com --authkey="$KEY"
```

После подключения хоста **перезапусти скрипт**: он доведёт UFW-правила для DNS
(`tailscale0`, порт 53) и настроит exit node. Это штатный двухэтапный процесс,
а не ошибка.

## Повторный запуск setup-server.sh

Скрипт можно безопасно перезапускать: он не удаляет данные, не пересоздаёт
конфиги и не сносит контейнеры. Проверено разбором кода (выполнение вне
изолированной среды запрещено, см. ручной чек-лист в `docs/SECURITY.md`).

Что делает повторный запуск:

| Этап | Поведение при повторе |
|---|---|
| Диалог базовых параметров | показывает сохранённые значения, меняет только при явном `y` |
| Docker / nginx / dnsmasq / certbot / tailscale | ставит только отсутствующее |
| `config.yaml`, `policy.hujson`, `docker-compose.yml`, конфиг dnsmasq, сайт nginx | **не перезаписывает**, если файл уже есть |
| `headplane.yaml` | сохраняет `cookie_secret`, обновляет `api_key` (создаёт новый ключ на 90 дней) |
| Пользователь Headscale | создаёт только при отсутствии |
| API-ключи | **создаёт новый при каждом запуске, старые не отзывает** (см. R1 в `docs/SECURITY.md` — периодически отзывай и чисти) |
| dnsmasq / nginx | `restart` / `reload` (кратковременный блип DNS, обрывов tailnet нет) |
| Exit node | повторно объявляет и одобряет `0.0.0.0/0`, `::/0` |
| UFW | добавляет правила и включает (`--force enable`); **повтор может плодить дубликаты** — проверяй `ufw status numbered` |
| cron certbot | без дублей (есть дедупликация) |
| cron бэкапа | без дублей (дедупликация исправлена, раньше плодились) |
| `tailnet-add` | переустанавливает в `/usr/local/bin` |
| Подключение хоста | только если хост не в сети |
| `.setup-state` | перезаписывает значениями текущего запуска, права `600` |

Ограничение, о котором надо знать: смена FQDN/базовой зоны/IP при перенастройке
обновляет **только** `.setup-state`, а существующие `config.yaml`, сайт nginx,
конфиг dnsmasq и `base_url`/`public_url` в `headplane.yaml` **остаются старыми**.
Это сделано намеренно (не затирать ручные правки), но после смены базовых
параметров синхронизируй файлы вручную и сделай `nginx -t && systemctl reload nginx`
плюс `docker compose -f /opt/headscale/docker-compose.yml up -d`.

## Подключение устройств

На сервере выполни `sudo tailnet-add` — напечатает одноразовый reusable-ключ
(по умолчанию 1 час) и готовые команды для каждой платформы. Десктопу нужен
только этот вывод: узел регистрируется ключом автоматически, approve не нужен.

Статусы клиентских инструкций (честно):

| Платформа | Способ | Статус |
|---|---|---|
| Windows | `setup-windows.ps1` или две команды из `tailnet-add` | Скрипт предоставлен; сквозная проверка — только в изолированной среде (см. чек-лист). Обрати внимание: `setup-windows.ps1` подключается **без** ключа (потребуется approve в админке), а команды из `tailnet-add` — **с** ключом (без approve) |
| macOS | `setup-mac.sh` или команды из `tailnet-add` | То же. Нужен standalone-клиент (brew cask), **не** App Store — App Store-клиент заперт на облако Tailscale |
| Linux (headless) | `setup-linux.sh <домен> <ключ>` | То же. По умолчанию `--accept-dns=false`: сервер сохраняет свой `resolv.conf`, узлы доступны по IP и через `tailscale ping <имя>` |
| Android / iOS | invite-URL Headscale / сторонние сборки | **Не проверены.** В UI официальных клиентов нет опции «свой сервер». Не считай эти пути рабочими, пока не проверишь на своей версии клиента в изолированной среде |

Быстрые пути без скриптов (ключ — из `sudo tailnet-add` на сервере):

```powershell
# Windows (PowerShell от администратора):
winget install Tailscale.Tailscale
& "C:\Program Files\Tailscale\tailscale.exe" up --login-server=https://<домен> --authkey=<ключ> --accept-dns=true
```

```bash
# macOS (standalone-клиент, не App Store):
brew install --cask tailscale
sudo defaults write io.tailscale.ipn.macos ControlURL https://<домен>
open -a Tailscale        # разрешить сетевое расширение в диалоге
sudo /Applications/Tailscale.app/Contents/MacOS/Tailscale up --login-server=https://<домен> --authkey=<ключ> --accept-dns=true
```

```bash
# Linux:
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --login-server=https://<домен> --authkey=<ключ> --accept-dns=false
```

После подключения устройство появится в админке `https://<домен>/admin` → Machines.
Админка доступна **только из tailnet**, дополнительно закрыта basic-auth, а при
первом входе попросит API-ключ.

## VPN параллельно с tailnet

Если на устройстве работает другой VPN (например, Amnezia) с kill-switch или
перехватом DNS:

1. Добавь подсеть `100.64.0.0/10` в исключения VPN (split tunneling) — иначе
   VPN-туннель перехватит трафик к tailnet.
2. Если VPN перехватывает DNS — добавь в `hosts` запись
   `<tailnet-IP сервера> <FQDN сервера>`
   (`setup-windows.ps1` предлагает это сам при неудачной DNS-проверке).

## Минимальный ручной демонтаж (справка, выполнять только в изолированной среде)

Скрипты демонтажа в репозитории нет. Ориентиры для ручной очистки тестового стенда:
`tailscale logout`, `docker compose -f /opt/headscale/docker-compose.yml down`,
удаление сайта nginx и `tailnet.conf` dnsmasq, `ufw delete` для правил tailnet,
`crontab -e` (строки certbot/headscale). Каждую команду сверяй с выводом
`ufw status numbered`, `crontab -l`, `docker ps` на конкретном стенде.
