#!/usr/bin/env bash
# Ubuntu/Debian: sudo bash setup-ssh.sh (запускать из SSH с доступом к консоли VPS).
# Публичный ключ генерируется НА КЛИЕНТЕ: ssh-keygen -t ed25519
# Существующие правила UFW сохраняются; другие пользователи теряют SSH-доступ.
set -euo pipefail
umask 077

die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
[[ $EUID == 0 ]] || die "Запустите: sudo bash $0"
[[ -t 0 ]] || die 'Нужен интерактивный терминал.'
command -v apt-get >/dev/null || die 'Поддерживаются Ubuntu/Debian с apt-get.'
command -v systemctl >/dev/null || die 'Требуется systemd.'
command -v hostnamectl >/dev/null || die 'Требуется hostnamectl.'
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

printf '%s\n' \
  'Не закрывайте текущую SSH-сессию до проверки нового входа.' \
  'Нужен доступ к web/serial-консоли провайдера на случай ошибки.' \
  'Будет создан НОВЫЙ пользователь с sudo без пароля.' \
  'SSH будет разрешён только этому пользователю и только по указанному ключу.' \
  'UFW сохранит прежние разрешения (это не сброс firewall).'
read -r -p 'Продолжить? Введите YES: ' answer
[[ $answer == YES ]] || exit 0

current_hostname=$(hostnamectl --static)
while :; do
  read -r -p "Имя хоста (например vps-01) [$current_hostname]: " new_hostname
  new_hostname=${new_hostname:-$current_hostname}
  # Короткое DNS-имя или FQDN: до 253 символов, метки до 63 символов.
  valid_hostname=1
  if [[ -z $new_hostname || ${#new_hostname} -gt 253 || $new_hostname == *. ]]; then
    valid_hostname=0
  else
    IFS=. read -r -a hostname_labels <<< "$new_hostname"
    for label in "${hostname_labels[@]}"; do
      if [[ ${#label} -gt 63 || ! $label =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
        valid_hostname=0
      fi
    done
  fi
  (( valid_hostname )) && break
  echo 'Некорректное имя: используйте буквы, цифры, дефисы и точки; без дефиса по краям меток.'
done
if [[ $new_hostname != "$current_hostname" ]]; then
  hosts_backup=$(mktemp /etc/hosts.setup-ssh.XXXXXXXX)
  cp -p /etc/hosts "$hosts_backup"
  hosts_content=$(awk -v name="$new_hostname" '
    BEGIN { short = name; sub(/\..*$/, "", short) }
    $1 == "127.0.1.1" { next }
    { print }
    END {
      if (short == name) print "127.0.1.1\t" name
      else print "127.0.1.1\t" name " " short
    }
  ' /etc/hosts)
  # Сохраняем inode /etc/hosts: в контейнерах это может быть bind mount.
  printf '%s\n' "$hosts_content" > /etc/hosts
  if ! hostnamectl set-hostname "$new_hostname"; then
    cat "$hosts_backup" > /etc/hosts
    die "Не удалось задать hostname. Копия /etc/hosts: $hosts_backup"
  fi
  printf 'Имя хоста: %s. Копия /etc/hosts: %s\n' "$new_hostname" "$hosts_backup"
  echo 'Если провайдер использует cloud-init, проверьте preserve_hostname: true, иначе имя может сброситься после перезагрузки.'
fi

apt-get update
apt-get install -y openssh-server sudo ufw
SSHD=$(command -v sshd)
"$SSHD" -t
if systemctl is-active --quiet ssh.service; then
  ssh_service=ssh.service
elif systemctl is-active --quiet sshd.service; then
  ssh_service=sshd.service
else
  die 'Не найдена активная служба ssh/sshd. Сначала запустите OpenSSH.'
fi

while :; do
  read -r -p 'Имя нового пользователя: ' username
  [[ $username =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { echo 'Используйте a-z, 0-9, _ и -, начиная с буквы (до 32 символов).'; continue; }
  if getent passwd "$username" >/dev/null; then
    echo 'Такой пользователь уже существует; выберите другое имя.'
  elif [[ -e /home/$username || -L /home/$username || -e /etc/sudoers.d/90-ssh-"$username" ]]; then
    echo 'Домашний каталог или sudoers уже существует; выберите другое имя.'
  else
    break
  fi
done

work=$(mktemp -d /root/setup-ssh.XXXXXXXX)
backup=''
pending=0
cleanup() {
  local status=$?
  trap - EXIT
  if (( pending )); then
    printf '\nВосстанавливаю прежний sshd_config из %s\n' "$backup" >&2
    cp -a -- "$backup" /etc/ssh/sshd_config
    if "$SSHD" -t; then
      systemctl reload "$ssh_service" || echo 'Не удалось перезагрузить SSH; используйте консоль VPS.' >&2
    fi
  fi
  rm -f -- "$work/key.pub" "$work/effective" "$work/check" "$work/sudoers" "$work/config"
  if [[ ! -f $work/sshd_config.backup ]]; then rmdir -- "$work"; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while :; do
  echo 'Вставьте ОДНУ строку публичного ключа (.pub), например ssh-ed25519 AAAA...'
  echo 'Приватный ключ не вставляйте. Для создания ключа выполните ssh-keygen -t ed25519 на своём компьютере.'
  read -r -p 'Публичный ключ: ' public_key
  # Не допускаем options в authorized_keys, сертификаты и несколько строк.
  if [[ $public_key =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]]; then
    printf '%s\n' "$public_key" > "$work/key.pub"
    if ssh-keygen -lf "$work/key.pub"; then break; fi
  fi
  echo 'Не удалось распознать публичный ключ.'
done

"$SSHD" -T > "$work/effective"
mapfile -t ssh_ports < <(awk '$1 == "port" {print $2}' "$work/effective")
(( ${#ssh_ports[@]} > 0 )) || die 'Не удалось определить SSH-порт.'
default_port=${ssh_ports[0]}
if [[ -n ${SSH_CONNECTION:-} ]]; then default_port=${SSH_CONNECTION##* }; fi
read -r -p "Текущий внешний SSH-порт (учитывайте socket activation/NAT) [$default_port]: " current_port
current_port=${current_port:-$default_port}
[[ $current_port =~ ^[0-9]{1,5}$ ]] || die 'Некорректный порт.'
current_port=$((10#$current_port))
(( current_port >= 1 && current_port <= 65535 )) || die 'Порт должен быть от 1 до 65535.'
ssh_ports+=("$current_port")

useradd --create-home --shell /bin/bash "$username"
echo 'Задайте пароль пользователя (ввод скрыт; это НЕ пароль для SSH):'
passwd "$username"
usermod -aG sudo "$username"
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$username" > "$work/sudoers"
visudo -cf "$work/sudoers"
install -o root -g root -m 0440 "$work/sudoers" "/etc/sudoers.d/90-ssh-$username"
group=$(id -gn "$username")
chmod go-w "/home/$username"
install -d -o "$username" -g "$group" -m 0700 "/home/$username/.ssh"
install -o "$username" -g "$group" -m 0600 "$work/key.pub" "/home/$username/.ssh/authorized_keys"

# Открываем SSH ДО включения UFW, включая нестандартный порт.
for port in "${ssh_ports[@]}"; do ufw allow "$port/tcp"; done
ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo
echo 'Перед отключением паролей откройте ВТОРОЙ терминал на своём компьютере:'
printf '  ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o IdentitiesOnly=yes -i /путь/к/приватному_ключу -p %s %s@IP_VPS\n' "$current_port" "$username"
echo 'В новой сессии проверьте: sudo -n whoami (должно вывести root).'
echo 'Если вход не работает — не подтверждайте: проверьте настройки SSH через консоль VPS.'
read -r -p 'Вход по ключу и sudo проверены? Введите YES: ' answer
[[ $answer == YES ]] || die 'Остановлено. Пользователь и UFW уже настроены; SSH-конфигурация ещё не изменена.'

[[ ! -L /etc/ssh/sshd_config ]] || die 'sshd_config является symlink; настройте его вручную.'
backup="$work/sshd_config.backup"
cp -a /etc/ssh/sshd_config "$backup"
# В OpenSSH первое значение обычно побеждает: ставим блок ПЕРЕД Include.
# Match-блоки проверяются отдельно ниже; при конфликте ничего не применяем.
cat > "$work/config" <<EOF
# Managed by setup-ssh.sh
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
AuthorizedKeysFile /home/$username/.ssh/authorized_keys
AuthorizedKeysCommand none
TrustedUserCAKeys none
MaxAuthTries 3
X11Forwarding no
AllowUsers $username
EOF
cat "$backup" >> "$work/config"
"$SSHD" -t -f "$work/config"

check_config() {
  local expected
  "$SSHD" -T -f "$work/config" "$@" > "$work/check"
  for expected in \
    'permitrootlogin no' 'passwordauthentication no' \
    'kbdinteractiveauthentication no' 'pubkeyauthentication yes' \
    'authenticationmethods publickey' 'authorizedkeyscommand none' \
    'trustedusercakeys none' 'maxauthtries 3' 'x11forwarding no' \
    "authorizedkeysfile /home/$username/.ssh/authorized_keys" "allowusers $username"; do
    grep -Fxq "$expected" "$work/check" || die "Конфликт SSH-конфигурации: ожидалось '$expected'. Проверьте Include/Match/AllowUsers; изменения SSH не применены."
  done
  [[ $(grep -c '^allowusers ' "$work/check") == 1 ]] || die 'В конфигурации есть дополнительные AllowUsers; удалите конфликт вручную.'
}
check_config
client_addr=127.0.0.1
server_addr=127.0.0.1
server_port=${ssh_ports[0]}
if [[ -n ${SSH_CONNECTION:-} ]]; then
  read -r client_addr _ server_addr server_port <<< "$SSH_CONNECTION"
fi
check_config -C "user=$username,addr=$client_addr,host=$client_addr,laddr=$server_addr,lport=$server_port"

pending=1
install -o root -g root -m 0600 "$work/config" /etc/ssh/sshd_config
"$SSHD" -t
systemctl reload "$ssh_service"
echo 'Проверьте ЕЩЁ ОДИН новый вход по ключу: теперь root и пароли отключены.'
read -r -p 'Новый вход после применения работает? Введите YES (иначе откат SSH): ' answer
[[ $answer == YES ]] || die 'Изменения SSH будут отменены; пользователь и UFW сохранятся.'
pending=0
printf '\nГотово. Резервная копия SSH: %s\n' "$backup"
echo 'Сохраните текущую сессию до завершения всех проверок.'
ufw status verbose
