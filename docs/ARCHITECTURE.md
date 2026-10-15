# Архитектура tailnet

Собственная mesh-сеть на базе Headscale: координация и DNS централизованы
на одном VPS, а трафик между устройствами идёт напрямую (WireGuard-пиринг).

## Компоненты

| Компонент | Где | Роль |
|---|---|---|
| Headscale | docker на VPS (`headscale`, sqlite) | Control plane: регистрация узлов, выдача конфигурации WireGuard, координация пиринга, MagicDNS, API |
| Headplane | docker на VPS (`headplane`) | Web-админка (`/admin`): список узлов, маршруты, ключи. Ходит в Headscale API по ключу |
| nginx | хост VPS, TLS Let's Encrypt | `:443` → Headscale `:8080` (публично, control plane + DERP); `/admin` и `/health` — только из tailnet (+ basic-auth для `/admin`) |
| dnsmasq | хост VPS, слушает только tailnet-IP | Split-DNS для клиентов: своя зона → свои ответы, остальное → `1.1.1.1` / `1.0.0.1` |
| tailscaled | хост VPS | Сам VPS — рядовой узел сети с фиксированным tailnet-IP (по умолчанию `100.64.0.4`) |
| Клиенты | Windows / macOS / Linux | Обычный Tailscale, направленный на свой control plane (`--login-server`) |
| DERP-релей | встроен в Headscale (`:3478/udp`) | Фолбэк, когда прямое соединение между узлами невозможно (NAT/файрвол) |

## Топология

```
Устройства (Tailscale-клиенты, IP 100.64.0.x)
   │  WireGuard-пиринг: напрямую между собой,
   │  DERP-релей (на VPS :3478/udp) как фолбэк
   ▼
VPS (например lan.example.com, tailnet-IP 100.64.0.4)
   ├─ nginx :443 (TLS, Let's Encrypt)
   │    ├─ /         → headscale :8080   — публично: control plane + DERP
   │    ├─ /admin    → headplane :3000   — ТОЛЬКО из tailnet (+ basic-auth);
   │    │                                  чужие получают nginx 404
   │    └─ /health   → headplane health  — только из tailnet
   ├─ headscale (docker, sqlite)
   ├─ headplane (docker, админка)
   ├─ dnsmasq :53 на tailnet-IP — split-DNS: своя зона → свои IP,
   │                              остальное → 1.1.1.1
   └─ tailscaled — сам VPS как узел сети
```

## Сеть и порты

| Точка | Порт | Доступ | Назначение |
|---|---|---|---|
| VPS TCP 22 | ssh | интернет (ограничь по IP, если можешь) | администрирование |
| VPS TCP 80 | http | интернет | только `/.well-known/acme-challenge/` + редирект на https |
| VPS TCP 443 | https | интернет (`/`), tailnet (`/admin`, `/health`) | control plane + DERP поверх TLS; админка скрыта от интернета правилом `allow 100.64.0.0/10` + `deny all` с подменой 403 на 404 |
| VPS UDP 3478 | stun/DER-to-DERP | интернет | построение пиринга + релейный трафик (`verify_clients: true`) |
| VPS UDP/TCP 53 | dns | **только** интерфейс `tailscale0` (UFW) | split-DNS для узлов сети |
| docker-сеть `172.30.0.0/24` | 8080/3000 на loopback | только хост | Headscale `:8080`, Headplane `:3000` не торчат наружу напрямую |
| tailnet `100.64.0.0/10` | весь WireGuard-трафик | только узлы сети | diagnosed: `tailscale status` показывает `direct` (напрямую) или `relay` (через DERP) |

## DNS

1. Headscale раздаёт клиентам DNS-сервер = tailnet-IP VPS и зону MagicDNS
   `tail.<базовая-зона>`; в `config.yaml` также прописан split-DNS для базовой
   зоны и A-запись `FQDN сервера → tailnet-IP`.
2. Запросы к своей зоне обслуживает dnsmasq на VPS; всё остальное уходит на
   `1.1.1.1`/`1.0.0.1` напрямую (plaintext, без DoH/DoT — см. `docs/SECURITY.md`).
3. Поведение клиентов различается (и это нормально, см. `docs/DEPLOYMENT.md`):
   Windows/macOS подключаются с `--accept-dns=true`, Linux-хелпер — с
   `--accept-dns=false` (сервер сохраняет свой `resolv.conf`).

## Почему tailnet-IP сервера фиксирован

Headscale раздаёт адреса последовательно с `100.64.0.1`. Если VPS-узел создать
первым с высоким адресом (по умолчанию `100.64.0.4`), при добавлении устройств
его адрес не «уедет», и DNS-резолвер (dnsmasq на этом IP), который уже роздан
клиентам, не изменится.

## Split tunnel и exit node

- По умолчанию tailnet — уже split tunnel: через него идут только `100.64.0.0/10`
  и явно объявленные маршруты, остальной интернет — напрямую у провайдера.
- Exit node — обратное: `setup-server.sh` делает VPS exit node (форвардинг, NAT,
  объявление и одобрение `0.0.0.0/0` и `::/0`). При его выборе весь
  интернет-трафик устройства выходит через публичный IP VPS.
- Маршрутизация работает по IP-префиксам, не по доменам: правила «через VPS
  только эти сайты» средствами exit node не существует (подробности и обходные
  пути — в README и `docs/OPERATIONS.md`).

## Данные и состояние

- Вся координация — в `/opt/headscale`: `config/` (yaml, policy), `data/`
  (sqlite-база, ключи noise/DERP), `headplane-data/`, `backups/`.
- Состояние установки — `/opt/headscale/.setup-state` (редактировать вручную
  не нужно; подробности про повторные запуски — в `docs/DEPLOYMENT.md`).
- Резервные копии — ежедневный tar в `backups/`; ограничения (hot-backup sqlite,
  без ротации/шифрования/выноса) и правильная процедура восстановления — в
  `docs/OPERATIONS.md` и `docs/SECURITY.md`.
