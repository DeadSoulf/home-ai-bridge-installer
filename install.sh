#!/usr/bin/env bash
# Public bootstrap for HOME AI Bridge: no GitHub account, PAT, or private code required.
set -Eeuo pipefail
umask 077
export LC_ALL=C
VERSION="v0.7.0"
ASSET="home-ai-bridge-lxc-linux-amd64.tar.gz"
EXPECTED_SHA256="be9565a8419e3e53362a900e8d32fb64bf7f04d961e777dd5a0fd561601d4bf5"
URL="https://github.com/DeadSoulf/home-ai-bridge-installer/releases/download/$VERSION/$ASSET"
WORKDIR=""
say() { printf '\033[1;36m%s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
cleanup() { if [[ -n "$WORKDIR" ]]; then rm -rf -- "$WORKDIR"; fi; }
trap cleanup EXIT

if [[ "$#" -gt 0 ]] && [[ "$1" == "--help" || "$1" == "-h" ]]; then
  cat <<'HELP'
HOME AI Bridge: Debian 13 LXC в Proxmox VE.
Без GitHub Personal Access Token и без ручного ввода секретов.
Новый непривилегированный CT, по умолчанию DHCP, 1 CPU, 512 MiB, диск 4 GiB.
Сервер слушает 0.0.0.0:8787 (все IPv4-интерфейсы).
Для обмена заданиями требуется внутренняя авторизация агентов;
доступ разрешён с адресов частных сетей.
HELP
  exit 0
fi

[[ "$(id -u)" == "0" ]] || die "Откройте Shell хоста Proxmox VE от root."
for program in pct pvesh pveam pvesm curl tar awk sort ip python3 mktemp sha256sum; do
  command -v "$program" >/dev/null 2>&1 || die "Не найдена команда $program (запустите на Proxmox VE)."
done
[[ -r /dev/tty && -w /dev/tty ]] || die "Требуется интерактивная Shell-консоль Proxmox."

ask() {
  local question="$1" default="$2" answer=""
  printf '%s [%s]: ' "$question" "$default" >/dev/tty
  IFS= read -r answer </dev/tty || die "Ввод прерван"
  if [[ -n "$answer" ]]; then REPLY="$answer"; else REPLY="$default"; fi
}

choose_storage() {
  local content="$1" preferred="$2" available=""
  available="$(pvesm status --content "$content" 2>/dev/null |
    awk 'NR>1 && $3 == "active" {print $1}' || true)"
  [[ -n "$available" ]] || die "Нет подходящего доступного хранилища: $content"
  if printf '%s\n' "$available" | grep -Fxq "$preferred"; then
    printf '%s\n' "$preferred"
  else
    printf '%s\n' "$available" | head -n1
  fi
}

say "HOME AI Bridge — установка Proxmox LXC без токенов GitHub"
printf '%s\n' "HOME AI Bridge будет слушать 0.0.0.0:8787. Для агентов сохраняется обязательная авторизация."
printf '%s\n' "1 — создать новый LXC"
printf '%s\n' "2 — установить в уже созданный Debian 13 LXC (обойти проблемный pct create)"
printf 'Режим [1]: ' >/dev/tty
IFS= read -r mode </dev/tty || die "Ввод прерван"
if [[ "$mode" == 2 ]]; then
  WORKDIR="$(mktemp -d /tmp/home-ai-bridge-mode-XXXXXXXX)"
  chmod 0700 "$WORKDIR"
  curl -q --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --output "$WORKDIR/install-existing.sh" \
    "https://raw.githubusercontent.com/DeadSoulf/home-ai-bridge-installer/main/install-existing.sh" ||
    die "Не удалось скачать установщик для существующего LXC"
  bash "$WORKDIR/install-existing.sh"
  exit $?
fi
[[ -z "$mode" || "$mode" == 1 ]] || die "Неизвестный режим установки"
printf '%s\n' "Будет создан новый Debian 13 LXC. Существующие контейнеры не изменятся."

next_id="$(pvesh get /cluster/nextid 2>/dev/null | tr -cd '0-9' | head -c 9)"
[[ "$next_id" =~ ^[0-9]{3,9}$ ]] || die "Нет свободного CTID"
ask "Container ID" "$next_id"
CTID="$REPLY"
[[ "$CTID" =~ ^[1-9][0-9]{2,8}$ ]] || die "Неверный CTID"
if pct config "$CTID" >/dev/null 2>&1; then die "CT $CTID уже существует."; fi

default_root="$(choose_storage rootdir local-lvm)"
default_template="$(choose_storage vztmpl local)"
ask "Хранилище диска LXC" "$default_root"
ROOT_STORAGE="$REPLY"
ask "Хранилище шаблонов" "$default_template"
TEMPLATE_STORAGE="$REPLY"

if ip link show vmbr0 >/dev/null 2>&1; then
  bridge_default=vmbr0
else
  bridge_default="$(ip -o link show | awk -F': ' '$2 ~ /^vmbr[0-9]+/ {print $2; exit}')"
fi
[[ -n "$bridge_default" ]] || die "Сетевой мост vmbr не обнаружен"
ask "Сетевой мост" "$bridge_default"
BRIDGE="$REPLY"
ip link show "$BRIDGE" >/dev/null 2>&1 || die "Мост $BRIDGE отсутствует"

ask "IPv4: dhcp или CIDR" "dhcp"
IP="$REPLY"
GATEWAY="-"
if [[ "$IP" != "dhcp" ]]; then
  ask "IPv4 шлюз" "192.168.1.1"
  GATEWAY="$REPLY"
fi
printf '\n'
say "Параметры нового контейнера"
printf 'CTID: %s\nДиск: %s\nШаблоны: %s\nМост: %s\nIP: %s\n' \
  "$CTID" "$ROOT_STORAGE" "$TEMPLATE_STORAGE" "$BRIDGE" "$IP"
printf '%s\n' "CPU: 1 | RAM: 512 MiB | Storage: 4 GiB | unprivileged LXC"
printf '%s\n' "IPv4 bind: 0.0.0.0:8787 | allowed peers: private IPv4 networks"
printf 'Для создания нового контейнера введите yes: ' >/dev/tty
IFS= read -r consent </dev/tty || die "Ввод прерван"
[[ "$consent" == "yes" ]] || die "Отменено без создания CT."

WORKDIR="$(mktemp -d /tmp/home-ai-bridge-XXXXXXXX)"
chmod 0700 "$WORKDIR"
[[ "$EXPECTED_SHA256" =~ ^[a-f0-9]{64}$ ]] || die "Не опубликована проверенная контрольная сумма релиза"
say "Загружаю готовый Linux-сервер без GitHub-токенов"
curl -q --fail --silent --show-error --location --retry 2 \
  --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --output "$WORKDIR/$ASSET" "$URL" ||
  die "Не удалось скачать публичную сборку HOME AI Bridge"
actual="$(sha256sum "$WORKDIR/$ASSET" | awk '{print $1}')"
[[ "$actual" == "$EXPECTED_SHA256" ]] || die "Проверка SHA-256 не прошла; установка остановлена"
mkdir -p "$WORKDIR/package"
tar -xzf "$WORKDIR/$ASSET" -C "$WORKDIR/package"
[[ -x "$WORKDIR/package/bin/home-ai-bridge-server" ]] ||
  die "В релизе отсутствует серверный бинарный файл"
[[ -f "$WORKDIR/package/deploy/proxmox/create-lxc.sh" ]] ||
  die "В релизе отсутствует установщик контейнера"

say "Поиск Debian 13 LXC-шаблона"
TEMPLATE="$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null |
  awk '$1 ~ /debian-13-standard.*amd64\.tar\.(zst|gz)$/ {print $1}' |
  sort -V | tail -n1)"
if [[ -z "$TEMPLATE" ]]; then
  template_name="$(pveam available --section system |
    awk '$2 ~ /^debian-13-standard_.*amd64\.tar\.(zst|gz)$/ {print $2}' |
    sort -V | tail -n1)"
  [[ -n "$template_name" ]] || die "Debian 13-шаблон не найден. Проверьте 'pveam update'."
  pveam download "$TEMPLATE_STORAGE" "$template_name"
  TEMPLATE="$TEMPLATE_STORAGE:vztmpl/$template_name"
fi

say "Создание и установка HOME AI Bridge LXC $CTID"
bash "$WORKDIR/package/deploy/proxmox/create-lxc.sh" \
  "$CTID" "$TEMPLATE" "$ROOT_STORAGE" "$BRIDGE" "$IP" "$GATEWAY"
say "Установка завершена"
printf '%s\n' "Статус: pct exec $CTID -- systemctl status home-ai-bridge --no-pager"
printf '%s\n' "Health: pct exec $CTID -- curl -fsS http://127.0.0.1:8787/health"
printf '%s\n' "IP CT: pct exec $CTID -- hostname -I"
printf '%s\n' "Агенты регистрируются отдельно, без открытия неавторизованного доступа."
