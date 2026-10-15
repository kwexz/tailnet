# Tailnet: своя Tailscale-совместимая сеть (Headscale) на VPS

![static-checks](https://github.com/kwexz/tailnet/actions/workflows/static-checks.yml/badge.svg)

Собственная mesh-сеть для своих устройств — без облака Tailscale и без
централизованного VPN-сервера для трафика. Устройства соединяются напрямую
(WireGuard-пиринг), а сервер на VPS нужен только для координации, DNS и
администрирования.

Состав: **Headscale** (control plane, docker) + **Headplane** (web-админка) +
**dnsmasq** (split-DNS) + **nginx** (TLS) на одном VPS. Клиенты — обычный
Tailscale, направленный на свой сервер.

Подробная архитектура: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Архитектура (кратко)

```
Устройства (Tailscale-клиенты, IP 100.64.0.x)
   │  WireGuard-пиринг напрямую; DERP-релей на VPS (:3478/udp) как фолбэк
   ▼
VPS (например lan.example.com, tailnet-IP 100.64.0.4)
   ├─ nginx :443 (TLS, Let's Encrypt)
   │    ├─ /         → headscale :8080   — публично: control plane + DERP
   │    ├─ /admin    → headplane :3000   — ТОЛЬКО из tailnet (+ basic-auth)
   │    └─ /health   → headplane health  — только из tailnet
   ├─ headscale (docker, sqlite) + headplane (docker, админка)
   ├─ dnsmasq :53 на tailnet-IP — split-DNS: своя зона → свои IP, остальное → 1.1.1.1
   └─ tailscaled — сам VPS как узел сети (и опционально exit node)
```

Ключевые решения: split-DNS с DNS-сервером на tailnet-IP VPS; админка скрыта от
интернета (чужие получают стандартный nginx 404); фиксированный tailnet-IP
сервера, чтобы DNS-резолвер у клиентов не «уезжал»; порт 53 открыт только для
tailnet; ежедневные бэкапы в `/opt/headscale/backups/`.

## Клиенты

| Платформа | Подключение | Статус проверки |
|---|---|---|
| Windows | `setup-windows.ps1` или команды из `tailnet-add` | Скрипт предоставлен; сквозная проверка — только в изолированной среде |
| macOS | `setup-mac.sh` или команды из `tailnet-add` (нужен standalone-клиент через brew, не App Store) | То же |
| Linux (headless) | `setup-linux.sh <домен> <ключ>` | То же |
| Android / iOS | — | **Не проверены.** В UI официальных клиентов нет опции «свой сервер»; не считай эти пути рабочими без собственной проверки |

## Типовые сценарии

- Доступ к своим компьютерам и сервисам из любой сети по стабильным tailnet-IP
  и MagicDNS-именам, без открытых портов на устройствах.
- Администрирование VPS и веб-панелей через `/admin`-подобные интерфейсы,
  видимые только внутри сети.
- Выход в интернет через IP VPS (exit node) на недоверенных сетях.
- Изоляция рабочего трафика от публичного интернета: по умолчанию через сеть
  идут только `100.64.0.0/10` и объявленные маршруты (split tunnel).

## Быстрый старт

Сервер (VPS с Ubuntu, A-запись `lan.example.com` → IP VPS, root):

```bash
sudo bash setup-server.sh
```

Скрипт спросит FQDN, базовую DNS-зону, email для Let's Encrypt, tailnet-IP
сервера, имя пользователя и логин/пароль basic-auth. В конце выведет API-ключ
Headplane (вставить при первом входе в админку) и — если хост ещё не в сети —
команду подключения самого VPS. После подключения хоста **перезапусти скрипт**:
он доведёт UFW/DNS-правила и exit node.

Устройства (ключ — вывод `sudo tailnet-add` на сервере, живёт 1 час):

```powershell
# Windows (PowerShell от администратора):
winget install Tailscale.Tailscale
& "C:\Program Files\Tailscale\tailscale.exe" up --login-server=https://<домен> --authkey=<ключ> --accept-dns=true
```

```bash
# macOS (standalone, не App Store) / Linux — см. docs/DEPLOYMENT.md
```

Полное развёртывание, повторные запуски, подключение каждой платформы и
сосуществование с другим VPN: [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md).

## Документация

| Документ | Содержание |
|---|---|
| `docs/ARCHITECTURE.md` | компоненты, топология, порты, DNS, split tunnel/exit node, данные и состояние |
| `docs/DEPLOYMENT.md` | предусловия, установка сервера, повторные запуски (таблица идемпотентности), подключение клиентов, VPN параллельно |
| `docs/OPERATIONS.md` | ежедневные команды, диагностика сети и DNS, exit node, ротация ключей, бэкап/восстановление, обновления |
| `docs/SECURITY.md` | честная модель безопасности, реестр рисков и исправлений, ручной чек-лист для изолированной среды |

## Безопасность (кратко)

WireGuard шифрует транспорт, но безопасность решения определяют control plane,
админка, DNS, бэкапы и ротация — а не сам факт WireGuard. Компрометация VPS
компрометирует всю сеть; политика по умолчанию — `accept *` (плоская сеть);
бэкапы без шифрования и ротации; API-ключи копятся при перезапусках скрипта
(чистить вручную). Полная картина — в [`docs/SECURITY.md`](docs/SECURITY.md).

## Эксплуатация (кратко)

```bash
# на сервере:
docker exec headscale headscale nodes list
docker exec headscale headscale users list
# на клиенте:
tailscale status    # direct = напрямую; relay = через DERP
tailscale ping <имя>
```

Админка: `https://<домен>/admin` — только из tailnet, basic-auth, затем API-ключ
(живёт 90 дней; ротация — в `docs/OPERATIONS.md`). Восстановление из бэкапа —
только с остановленными контейнерами, процедура — в `docs/OPERATIONS.md`.

## Проверки

- Автоматически (CI, только статика — без развёртывания и изменения сети):
  `bash -n`, ShellCheck (`--severity=warning`), синтаксический разбор PowerShell
  через AST (без запуска скрипта), PSScriptAnalyzer, поиск случайных секретов.
  Локально: `bash scripts/check-static.sh` (`STRICT=1` требует наличия всех инструментов).
- Вручную — только в изолированной среде (чистый тестовый стенд, снапшот до старта).
  Чек-лист: сервер (11 пунктов), клиенты (6 пунктов) — в [`docs/SECURITY.md`](docs/SECURITY.md).
  Android/iOS в чек-лист не входят — эти пути не проверены.

## Файлы

| Файл | Назначение |
|---|---|
| `setup-server.sh` | Настройка VPS с нуля. Интерактивный, безопасно перезапускаемый (подробности и ограничения — в `docs/DEPLOYMENT.md`) |
| `tailnet-add` | Хелпер на сервере: печатает ключ (1 час) и готовые команды подключения для Win/mac/Linux |
| `setup-windows.ps1` | Windows-клиент: установка Tailscale, подключение (без ключа — потребуется approve), DNS-проверка |
| `setup-mac.sh` | macOS-клиент: standalone Tailscale.app + свой сервер |
| `setup-linux.sh` | Linux-клиент (headless): установка tailscale + подключение (`--accept-dns=false`) |
| `scripts/check-static.sh` | Статические проверки без выполнения скриптов |
| `.github/workflows/static-checks.yml` | CI только со статическими проверками |

## Лицензия

MIT — см. [`LICENSE`](LICENSE).
