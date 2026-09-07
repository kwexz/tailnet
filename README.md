# Tailnet: своя Tailscale-совместимая сеть (Headscale) на VPS

Зачем: mesh-сеть своих устройств (компьютеры, телефоны) без облака Tailscale и без централизованного VPN-сервера для трафика. Устройства соединяются напрямую (WireGuard-пиринг), сервер нужен только для координации и DNS.

Состав: **Headscale** (control plane, docker) + **Headplane** (web-админка) + **dnsmasq** (split-DNS) на одном VPS. Клиенты — обычный Tailscale (Windows/macOS/Android/iOS), направленный на свой сервер.

## Файлы

| Файл | Назначение |
|---|---|
| `setup-server.sh` | Настройка VPS с нуля. Интерактивный, идемпотентный. Спрашивает домены/IP/пароли, при повторном запуске только донастраивает. |
| `tailnet-add` | Хелпер на сервере: печатает готовые команды подключения для Win/mac/Linux + одноразовый ключ. Устанавливается setup-server.sh. |
| `setup-windows.ps1` | Windows-клиент: установка Tailscale, подключение, DNS-проверка. |
| `setup-mac.sh` | Mac-клиент: GUI Tailscale.app + свой сервер. |
| `setup-linux.sh` | Linux-клиент (headless): установка tailscale + подключение. |
| `README.md` | Этот файл. |

## Как это устроено

```
Устройства (Tailscale-клиенты, IP 100.64.0.x)
   │  WireGuard-пиринг: напрямую между собой, DERP-релей (на VPS :3478/udp) как фолбэк
   ▼
VPS (например lan.example.com, tailnet-IP 100.64.0.4)
   ├─ nginx :443 (TLS, Let's Encrypt)
   │    ├─ /         → headscale :8080   — публично: control plane + DERP
   │    ├─ /admin    → headplane :3000   — ТОЛЬКО из tailnet (+ basic-auth); чужие получают nginx 404
   │    └─ /health   → headplane health  — только из tailnet
   ├─ headscale (docker, sqlite)
   ├─ headplane (docker, админка)
   ├─ dnsmasq :53 на tailnet-IP — split-DNS: своя зона → свои IP, остальное → 1.1.1.1
   └─ tailscaled — сам VPS как узел сети
```

Ключевые решения:
- **Split-DNS**: клиенты получают DNS-сервер = tailnet-IP VPS. Имена вида `*.tail.<домен>` (MagicDNS) и вся базовая зона резолвятся в tailnet-адреса; интернет-имена уходят на 1.1.1.1 напрямую.
- **Админка скрыта**: из интернета `/admin` отдаёт стандартный nginx 404 (факт наличия админки не палится), из tailnet — работает и дополнительно закрыта basic-auth.
- **Tailnet-IP сервера** фиксируется (по умолчанию 100.64.0.4, а не .1): Headscale раздаёт адреса последовательно с .1, и если VPS-узел создать первым, при добавлении устройств его адрес не «уедет» и DNS-резолвер (dnsmasq на этом IP) не изменится.
- **Порт 53 открыт только для tailnet** (UFW) — извне DNS-сервер не виден.
- **Бэкапы**: cron ежедневно 04:30, `/opt/headscale/backups/headscale-<дата>.tar.gz` (конфиги + база).

## Exit node (интернет через VPS)

`setup-server.sh` автоматически делает VPS exit node: включает маршрутизацию, NAT, объявляет и одобряет маршруты `0.0.0.0/0` и `::/0`. После запуска сервер появляется в выборе exit node в Tailscale для Windows и macOS.

- **Windows**: иконка Tailscale в системном трее → **Use exit node** → выбрать VPS.
- **macOS**: иконка Tailscale в строке меню → **Use exit node** → выбрать VPS.
- Командная строка: `tailscale set --exit-node=<IP-или-имя-VPS>`; отключить: `tailscale set --exit-node=`.

При включении exit node весь интернет-трафик устройства выходит через публичный IP VPS. Трафик к локальной сети устройства по умолчанию недоступен; при необходимости включи **Allow LAN access** рядом с выбором exit node.

Если меню macOS не показывает exit node, а команда ниже выводит VPS, это ограничение/кэш UI Tailscale.app при custom ControlURL, а не ошибка сервера. Выбрать exit node можно штатно через CLI:

```bash
sudo /Applications/Tailscale.app/Contents/MacOS/Tailscale set --exit-node=<tailnet-IP-VPS>
# отключить:
sudo /Applications/Tailscale.app/Contents/MacOS/Tailscale set --exit-node=
```

Проверка доступных exit node: `/Applications/Tailscale.app/Contents/MacOS/Tailscale exit-node list`.

## Раздельное туннелирование

Без exit node tailnet **уже является split tunnel**: через него идут только адреса устройств `100.64.0.0/10` и явно объявленные маршруты, обычный интернет-трафик остаётся у текущего провайдера/VPN.

Exit node намеренно работает наоборот: через VPS идёт весь трафик (`0.0.0.0/0` и `::/0`). Простого встроенного правила «направить через exit node только конкретные сайты» нет: сеть маршрутизирует IP-префиксы, не доменные имена.

Для отдельных IP или подсетей используется штатный subnet routing: Linux/VPS объявляет, например, `203.0.113.0/24`, Headscale одобряет маршрут, клиенты его принимают. Такой трафик пойдёт через VPS, всё остальное — напрямую. Для сайтов это ненадёжно: один домен часто использует меняющиеся IP и CDN. Если нужна выборочная маршрутизация именно по доменам, используй прокси (SOCKS/HTTP) или правила другого VPN, а не exit node.

## Развёртывание с нуля

### Сервер

Предусловия: VPS (Ubuntu), A-запись вида `lan.example.com` → публичный IP, root-доступ.

```bash
sudo bash setup-server.sh
```

Скрипт спросит: FQDN сервера, базовую DNS-зону, email для Let's Encrypt, tailnet-IP сервера, имя пользователя, логин/пароль basic-auth (Enter = сгенерировать). В конце:
- выведет **API-ключ Headplane** — вставь его при первом входе в админку;
- подскажет команду подключения самого VPS к tailnet (выполни и перезапусти скрипт — он доведёт UFW/DNS-правила).

### Добавление устройств

На сервере: `sudo tailnet-add` — напечатает одноразовый ключ (1 час) и готовые команды для каждого типа клиента. Десктопу нужен **только этот вывод** (например, переслать в чат): никакой админки и approve на подключаемой машине не требуется, узел регистрируется ключом автоматически.

Быстрые пути без скриптов:

- **Windows** (админ-PowerShell):
  ```powershell
  winget install Tailscale.Tailscale
  & "C:\Program Files\Tailscale\tailscale.exe" up --login-server=https://<домен> --authkey=<ключ> --accept-dns=true
  ```
- **macOS** (нужен standalone-клиент, не App Store):
  ```bash
  brew install --cask tailscale
  sudo defaults write io.tailscale.ipn.macos ControlURL https://<домен>
  open -a Tailscale        # разрешить сетевое расширение в диалоге
  sudo /Applications/Tailscale.app/Contents/MacOS/Tailscale up --login-server=https://<домен> --authkey=<ключ> --accept-dns=true
  ```
- **Linux**: `sudo bash setup-linux.sh <домен> <ключ>` — или вручную:
  ```bash
  curl -fsSL https://tailscale.com/install.sh | sh
  sudo tailscale up --login-server=https://<домен> --authkey=<ключ> --accept-dns=false
  ```
  `--accept-dns=false` — сервер сохраняет свой resolv.conf; tailnet-узлы доступны по IP и `tailscale ping <имя>` без DNS.

Полные скрипты (`setup-windows.ps1`, `setup-mac.sh`) делают то же самое плюс проверки DNS/связности.

- **Android/iOS**: у официальных клиентов нет опции «свой сервер» в UI. Варианты: загрузить modified-клиент (см. [headscales docs](https://headscale.net/)) или… на практике телефоны подключают через invite-URL Headscale при разблокированной настройке. Проверь актуальную инструкцию под свою версию клиента.

После подключения устройство появится в админке (`https://<домен>/admin` → Machines).

## VPN параллельно с tailnet (важно для клиентов)

Если на устройстве работает другой VPN (Amnezia и т.п.) с kill-switch/перехватом DNS:
1. Добавь подсеть **100.64.0.0/10** в исключения VPN (split tunneling) — иначе VPN-туннель перехватит трафик к tailnet.
2. Если VPN всё равно перехватывает DNS — добавь в hosts запись `<tailnet-IP сервера> <FQDN сервера>` (Windows-скрипт предлагает это сам при неудачной DNS-проверке).

## Ежедневные операции

```bash
# на сервере:
docker exec headscale headscale nodes list
docker exec headscale headscale users list
docker exec headscale headscale preauthkeys create --user 1 --reusable --expiration 1h
docker exec headscale headscale apikeys create --expiration 90d   # для админки/API

# на клиенте:
tailscale status    # direct ... = напрямую; relay/DERP = через релей
tailscale ping <имя>
```

Админка: `https://<домен>/admin` — только из tailnet, basic-auth, затем API-ключ.

## Восстановление из бэкапа

```bash
sudo tar xzf /opt/headscale/backups/headscale-<дата>.tar.gz -C /opt/headscale
sudo docker compose -f /opt/headscale/docker-compose.yml restart
```

## Известные нюансы

- **API-ключ админки протухает каждые 90 дней** — это ключ, который Headscale выдаёт для управления собой (Headplane ходит в Headscale API). Обновление: `docker exec headscale headscale apikeys create --expiration 90d`, затем поправить `api_key` в `/opt/headscale/config/headplane.yaml` и перезапустить headplane (или перезапустить `setup-server.sh` — обновит сам).
- **App Store Tailscale на Mac** не примет свой сервер — только standalone-версия.
- **Список устройств в GUI-клиентах** может не заполняться (клиенты тянут его из облака Tailscale, которого нет) — это косметика: статус, подключение, exit node работают.
