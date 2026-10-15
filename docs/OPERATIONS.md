# Эксплуатация

Все команды сервера выполняются на VPS от root. Ничего из этого раздела нельзя
запускать на рабочей машине или на боевом сервере без стенда.

## Ежедневные команды

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

Админка: `https://<домен>/admin` — только из tailnet, сначала basic-auth, затем API-ключ.

## Диагностика подключения

1. `tailscale status` на клиенте: смотри, есть ли узел VPS и пометку `direct`
   (пиринг напрямую) или `relay` (идёт через DERP на VPS — работает, но медленнее
   и зависит от сервера).
2. `tailscale ping <имя-или-IP>` — проверка связности на уровне WireGuard.
3. `tailscale netcheck` — есть ли UDP наружу, какой DERP выбран.
4. `tailscale exit-node list` — какие exit node видны клиенту.
5. На сервере: `docker exec headscale headscale nodes list` — зарегистрирован ли
   узел, одобрены ли маршруты.
6. Логи: `docker logs headscale`, `docker logs headplane`, `journalctl -u tailscaled`,
   `journalctl -u dnsmasq`, `nginx -t` + `journalctl -u nginx`.
7. Сеть сервера: `ufw status verbose`, `ss -ulnp | grep -E ':(53|3478)'`,
   `curl -sf https://<домен>/key -o /dev/null && echo OK`.

## Диагностика DNS

```bash
# с клиента: резолвится ли FQDN через tailnet-DNS
nslookup <домен> <tailnet-IP-VPS>
# или
dig @<tailnet-IP-VPS> <домен>
```

```powershell
# Windows:
Resolve-DnsName <домен> -Type A
ipconfig /flushdns
```

- Если имя не резолвится, а IP пингуется: смотри раздел «VPN параллельно с tailnet»
  в `docs/DEPLOYMENT.md` (перехват DNS сторонним VPN, запись в `hosts`).
- На сервере: `cat /etc/dnsmasq.d/tailnet.conf`, `systemctl status dnsmasq`,
  `ss -ulnp | grep :53` (слушать должен только tailnet-IP).

## Exit node

Включение на клиенте:

- Windows: иконка в трее → **Use exit node** → выбрать VPS.
- macOS: иконка в меню → **Use exit node** → выбрать VPS.
- CLI: `tailscale set --exit-node=<IP-или-имя-VPS>`; отключить: `tailscale set --exit-node=`.

При включённом exit node весь интернет-трафик идёт через публичный IP VPS;
доступ к локальной сети устройства по умолчанию пропадает — при необходимости
включи **Allow LAN access** рядом с выбором exit node.

Если меню macOS не показывает exit node, а `exit-node list` его видит — это
ограничение/кэш UI Tailscale.app при custom ControlURL, а не ошибка сервера.
Выбор через CLI (пример для standalone-клиента):

```bash
sudo /Applications/Tailscale.app/Contents/MacOS/Tailscale set --exit-node=<tailnet-IP-VPS>
# отключить:
sudo /Applications/Tailscale.app/Contents/MacOS/Tailscale set --exit-node=
```

На сервере exit node держится на трёх вещах: `net.ipv4.ip_forward=1` +
`net.ipv6.conf.all.forwarding=1` (`/etc/sysctl.d/99-tailnet-exit-node.conf`),
`tailscale set --advertise-exit-node` и одобренные в Headscale маршруты
`0.0.0.0/0`, `::/0` (одобрение видно в Headplane или `headscale nodes list`).
После переподключения хоста к tailnet перезапусти `setup-server.sh` — он
донастроит форвардинг и одобрение заново.

## Ротация ключей и паролей

| Секрет | Срок жизни | Ротация |
|---|---|---|
| Pre-auth ключи (`tailnet-add`, подключение хоста) | reusable, по умолчанию 1 час | Короткое окно — главная защита. Не пересылай по незащищённым каналам. Список/отзыв: `docker exec headscale headscale preauthkeys --help` (list/expire) |
| API-ключ Headscale (доступ Headplane к API) | 90 дней | `docker exec headscale headscale apikeys create --expiration 90d`, вписать новый `api_key` в `/opt/headscale/config/headplane.yaml`, `docker compose -f /opt/headscale/docker-compose.yml restart headplane`. Перезапуск `setup-server.sh` делает то же самое, но **создаёт ключ при каждом запуске** — старые отзови вручную (`headscale apikeys --help`: list/expire/delete) |
| Пароль basic-auth `/admin` | бессрочно | Перезапусти `setup-server.sh` и введи новый пароль (или сгенерируй), либо пересоздай `/etc/nginx/.htpasswd_headplane` через `openssl passwd -6` вручную и сделай `systemctl reload nginx` |
| `cookie_secret` Headplane | бессрочно | Меняется только вручную в `headplane.yaml` + рестарт headplane (все сессии сбросятся) |

## Резервное копирование и восстановление

Что бэкапится: ежедневный cron в `04:30` складывает
`/opt/headscale/backups/headscale-<дата>.tar.gz` (каталоги `config`, `data`,
`headplane-data`).

Ограничения, принятые осознанно (подробности — `docs/SECURITY.md` R11–R12):

- tar снимается с живой sqlite-базы — консистентность не гарантирована;
  для гарантированного бэкапа останавливай `headscale` на время архивации;
- ротации, шифрования и выноса копии наружу нет — настрой самостоятельно.

Восстановление (останавливаем контейнеры **до** распаковки, иначе база перепишется
или повредится):

```bash
sudo docker compose -f /opt/headscale/docker-compose.yml stop headscale headplane
sudo tar tzf /opt/headscale/backups/headscale-<дата>.tar.gz   # проверка целостности
sudo cp -a /opt/headscale /opt/headscale.bak-$(date +%F)      # точка отката
sudo tar xzf /opt/headscale/backups/headscale-<дата>.tar.gz -C /opt/headscale
sudo docker compose -f /opt/headscale/docker-compose.yml up -d
docker exec headscale headscale nodes list                    # проверка
```

Рекомендуемое доп. обслуживание бэкапов (добавь в cron вручную):

```bash
# ротация старше 14 дней:
find /opt/headscale/backups -name 'headscale-*.tar.gz' -mtime +14 -delete
# права и вынос копии наружу (пример):
chmod 600 /opt/headscale/backups/headscale-*.tar.gz
```

## Обновление компонентов

- Headscale в compose зафиксирован на образе (`v0.29.3` на момент написания),
  Headplane — `:latest` (не воспроизводимо; рекомендация — зафиксировать тег или
  digest, см. `docs/SECURITY.md` R15). Обновление: поменяй тег, `docker compose up -d`,
  проверь `headscale nodes list` и вход в `/admin`.
- Tailscale на клиентах обновляется штатно (winget/brew/пакетный менеджер);
  смена major-версии клиента — повод перепроверить подключение в изолированной среде.
- Сертификаты Let's Encrypt обновляются cron-строкой `certbot renew` (ежедневно 03:00
  + reload nginx); проверяй `systemctl status certbot.timer` или лог cron.
