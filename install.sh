#!/usr/bin/env bash
# HOME AI Bridge — one-command Proxmox VE LXC installer.
# Public bootstrap only. Source remains in a PRIVATE repository.
set -Eeuo pipefail
umask 077
export LC_ALL=C

SOURCE_REPOSITORY="DeadSoulf/home-ai-bridge"
SOURCE_REF="eab2f2b18e7c50509b95820285c7abd1e6ee0aca"
WORKDIR=""
TOKEN=""
say() { printf '\033[1;36m%s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
cleanup() {
  TOKEN=""
  unset TOKEN
  [[ -z "$WORKDIR" ]] || rm -rf -- "$WORKDIR"
}
trap cleanup EXIT
if [[ "$#" -gt 0 ]] && [[ "$1" == "--help" || "$1" == "-h" ]]; then
  cat <<'HELP'
HOME AI Bridge: интерактивная установка Debian 13 LXC на хосте Proxmox VE.
Новый unprivileged CT, сеть DHCP по умолчанию, запуск сервера на 127.0.0.1.
Ввод GitHub fine-grained PAT (Contents: Read) для приватного репозитория.
Токен не сохраняется; исходники доступны лишь во время установки.
HELP
  exit 0
fi

[[ "$(id -u)" == "0" ]] || die "Запустите команду от root на хосте Proxmox VE."
for program in pct pvesh pveam pvesm curl tar awk sort ip python3 mktemp; do
  command -v "$program" >/dev/null 2>&1 || die "Отсутствует команда $program; нужен хост Proxmox VE."
done
[[ -r /dev/tty && -w /dev/tty ]] || die "Нужен интерактивный терминал Proxmox."
ask() {
  local label="$1" default="$2" reply=""
  printf '%s [%s]: ' "$label" "$default" >/dev/tty
  IFS= read -r reply </dev/tty || die "Ввод прерван"
  if [[ -n "$reply" ]]; then REPLY="$reply"; else REPLY="$default"; fi
}
choose_storage() {
  local content="$1" preferred="$2" found=""
  found="$(pvesm status --content "$content" 2>/dev/null |
    awk 'NR>1 && $3 == "active" {print $1}' || true)"
  [[ -n "$found" ]] || die "Не найдено доступное хранилище типа $content"
  if printf '%s\n' "$found" | grep -Fxq "$preferred"; then
    printf '%s\n' "$preferred"
  else
    printf '%s\n' "$found" | head -n1
  fi
}

say "HOME AI Bridge — создание LXC в Proxmox VE"
printf '%s\n' "Будет создан НОВЫЙ контейнер Debian 13. Существующие CT не затрагиваются."
printf '%s\n\n' "После установки Bridge слушает только 127.0.0.1 (VPN и агенты подключаются отдельно)."

next_id="$(pvesh get /cluster/nextid 2>/dev/null | tr -cd '0-9' | head -c 9)"
[[ "$next_id" =~ ^[0-9]{3,9}$ ]] || die "Не удалось получить свободный CTID"
ask "Container ID" "$next_id"
CTID="$REPLY"
[[ "$CTID" =~ ^[1-9][0-9]{2,8}$ ]] || die "Неверный Container ID"
if pct config "$CTID" >/dev/null 2>&1; then die "CT $CTID уже существует"; fi

default_root="$(choose_storage rootdir local-lvm)"
default_template="$(choose_storage vztmpl local)"
ask "Хранилище диска LXC" "$default_root"
ROOT_STORAGE="$REPLY"
ask "Хранилище шаблонов" "$default_template"
TEMPLATE_STORAGE="$REPLY"

if ip link show vmbr0 >/dev/null 2>&1; then
  default_bridge="vmbr0"
else
  default_bridge="$(ip -o link show | awk -F': ' '$2 ~ /^vmbr[0-9]+/ {print $2; exit}')"
fi
[[ -n "$default_bridge" ]] || die "Сетевой мост vmbrN не найден"
ask "Сетевой мост" "$default_bridge"
BRIDGE="$REPLY"
ip link show "$BRIDGE" >/dev/null 2>&1 || die "Мост $BRIDGE отсутствует"

ask "IPv4 контейнера: dhcp или CIDR" "dhcp"
IP="$REPLY"
GATEWAY="-"
if [[ "$IP" != "dhcp" ]]; then
  ask "Шлюз IPv4" "192.168.1.1"
  GATEWAY="$REPLY"
fi

printf '\n'
say "Параметры"
printf 'CTID: %s\nДиск: %s\nШаблоны: %s\nМост: %s\nIP: %s\n' \
  "$CTID" "$ROOT_STORAGE" "$TEMPLATE_STORAGE" "$BRIDGE" "$IP"
printf '%s\n' "1 vCPU, 512 MiB RAM, 4 GiB disk, unprivileged LXC."
printf 'Введите yes для создания нового контейнера: ' >/dev/tty
IFS= read -r confirmation </dev/tty || die "Ввод прерван"
[[ "$confirmation" == "yes" ]] || die "Отменено до создания CT."

say "Для скачивания приватного репозитория требуется GitHub Personal Access Token."
printf '%s\n' "Создать токен: https://github.com/settings/personal-access-tokens/new" >/dev/tty
printf '%s\n' "Repository access: Only select repositories -> home-ai-bridge" >/dev/tty
printf '%s\n' "Repository permissions: Contents = Read-only" >/dev/tty
printf '%s\n' "При вставке в веб-консоль Proxmox используйте Ctrl+Shift+V или Shift+Insert." >/dev/tty
printf '%s\n' "Ввод скрыт: при вставке токена на экране не появятся символы." >/dev/tty
for attempt in 1 2 3; do
  printf 'GitHub PAT (попытка %s/3): ' "$attempt" >/dev/tty
  IFS= read -r -s TOKEN </dev/tty || die "Ввод токена прерван"
  printf '\n' >/dev/tty
  TOKEN="${TOKEN%$'\r'}"
  # Accept copy/paste artifacts, but never print or log any part of the credential.
  TOKEN="${TOKEN#"${TOKEN%%[![:space:]]*}"}"
  TOKEN="${TOKEN%"${TOKEN##*[![:space:]]}"}"
  if [[ "$TOKEN" == \"*\" && "${#TOKEN}" -ge 2 ]]; then TOKEN="${TOKEN:1:${#TOKEN}-2}"; fi
  if [[ "$TOKEN" == \'*\' && "${#TOKEN}" -ge 2 ]]; then TOKEN="${TOKEN:1:${#TOKEN}-2}"; fi
  if [[ "$TOKEN" =~ ^[a-zA-Z0-9_-]{16,512}$ ]]; then break; fi
  TOKEN=""
  if [[ "$attempt" == 3 ]]; then
    die "Токен не распознан после трёх попыток. Проверьте PAT Contents: Read и повторите запуск."
  fi
  printf '%s\n' "Токен пустой или содержит посторонние символы. Вставьте значение PAT без URL и лишнего текста." >/dev/tty
done
WORKDIR="$(mktemp -d /tmp/home-ai-bridge-XXXXXXXX)"
chmod 0700 "$WORKDIR"

say "Скачиваю приватный серверный код по HTTPS"
# Credentials go via stdin to curl --config -, never as command-line arguments.
# Do not run this script with bash -x, which could log sensitive data.
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" |
  curl -q --fail --silent --show-error --location --retry 2 \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --header 'Accept: application/vnd.github+json' \
    --config - --output "$WORKDIR/source.tar.gz" \
    "https://api.github.com/repos/$SOURCE_REPOSITORY/tarball/$SOURCE_REF" ||
    die "Не удалось скачать приватный репозиторий. Проверьте GitHub PAT Contents: Read."
TOKEN=""
unset TOKEN

mkdir -p "$WORKDIR/source"
tar -xzf "$WORKDIR/source.tar.gz" -C "$WORKDIR/source"
SOURCE_DIR="$(find "$WORKDIR/source" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -n "$SOURCE_DIR" && -f "$SOURCE_DIR/deploy/proxmox/create-lxc.sh" ]] ||
  die "Некорректный архив: create-lxc.sh не найден"

say "Выбираю шаблон Debian 13"
TEMPLATE="$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null |
  awk '$1 ~ /debian-13-standard.*amd64\.tar\.(zst|gz)$/ {print $1}' |
  sort -V | tail -n1)"
if [[ -z "$TEMPLATE" ]]; then
  template_name="$(pveam available --section system |
    awk '$2 ~ /^debian-13-standard_.*amd64\.tar\.(zst|gz)$/ {print $2}' |
    sort -V | tail -n1)"
  [[ -n "$template_name" ]] || die "Шаблон Debian 13 не найден. Проверьте pveam update."
  pveam download "$TEMPLATE_STORAGE" "$template_name"
  TEMPLATE="$TEMPLATE_STORAGE:vztmpl/$template_name"
fi

say "Устанавливаю HOME AI Bridge в новый CT $CTID"
bash "$SOURCE_DIR/deploy/proxmox/create-lxc.sh" \
  "$CTID" "$TEMPLATE" "$ROOT_STORAGE" "$BRIDGE" "$IP" "$GATEWAY"

say "Готово. Создан LXC $CTID (сервер пока доступен только локально)."
printf '%s\n' "Статус: pct exec $CTID -- systemctl status home-ai-bridge --no-pager"
printf '%s\n' "Проверка: pct exec $CTID -- curl -fsS http://127.0.0.1:8787/health"
printf '%s\n' "Настройка сети и агентов: pct enter $CTID"
printf '%s\n' "GitHub PAT не сохранён; старый сервер Windows не изменён."
