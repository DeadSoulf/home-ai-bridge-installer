#!/usr/bin/env bash
# HOME AI Bridge installer for an ALREADY CREATED Debian 13 Proxmox LXC.
# No GitHub token, no new container creation, no changes to PVE storage.
set -Eeuo pipefail
umask 077
export LC_ALL=C
VERSION="v0.7.0"
ASSET="home-ai-bridge-lxc-linux-amd64.tar.gz"
EXPECTED_SHA256="be9565a8419e3e53362a900e8d32fb64bf7f04d961e777dd5a0fd561601d4bf5"
URL="https://github.com/DeadSoulf/home-ai-bridge-installer/releases/download/$VERSION/$ASSET"
WORKDIR=""
cleanup() { if [[ -n "$WORKDIR" ]]; then rm -rf -- "$WORKDIR"; fi; }
trap cleanup EXIT
say() { printf '\033[1;36m%s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

if [[ "$#" -gt 0 ]] && [[ "$1" == "--help" || "$1" == "-h" ]]; then
  cat <<'HELP'
Установка HOME AI Bridge в уже созданный Debian 13 unprivileged LXC.
Создайте LXC через веб-интерфейс Proxmox или Community Scripts.
Установщик не вызывает pct create, не создаёт/удаляет диски или LXC.
HOME AI Bridge слушает 0.0.0.0:8787, с внутренней авторизацией.
Токен GitHub не требуется.
HELP
  exit 0
fi

[[ "$EUID" -eq 0 ]] || die "Откройте Shell хоста Proxmox от root"
for cmd in pct curl sha256sum tar mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || die "Команда не найдена: $cmd"
done
[[ -r /dev/tty && -w /dev/tty ]] || die "Нужен интерактивный терминал"

printf 'CTID существующего Debian 13 LXC [106]: ' >/dev/tty
IFS= read -r ctid </dev/tty || die "Ввод прерван"
CTID="$ctid"
if [[ -z "$CTID" ]]; then CTID=106; fi
[[ "$CTID" =~ ^[1-9][0-9]{2,8}$ ]] || die "Некорректный CTID"

config="$(pct config "$CTID" 2>/dev/null)" || die "LXC $CTID не найден. Сначала создайте контейнер в Proxmox."
grep -Eq '^unprivileged:[[:space:]]*1$' <<<"$config" ||
  die "Нужен непривилегированный (unprivileged) LXC. Настройки существующего CT не меняем."
[[ "$(pct status "$CTID" 2>/dev/null)" == *running* ]] ||
  die "LXC $CTID остановлен. Запустите его вручную: pct start $CTID"

pct exec "$CTID" -- /bin/sh -c '. /etc/os-release; test "$ID" = debian && test "$(printf %s "$VERSION_ID" | cut -d. -f1)" = 13' ||
  die "LXC $CTID должен работать под Debian 13"
pct exec "$CTID" -- /bin/sh -c 'test "$(uname -m)" = x86_64' ||
  die "Готовый сервер рассчитан на AMD64 / x86_64"
if pct exec "$CTID" -- /bin/sh -c 'test -e /usr/local/bin/home-ai-bridge-server || test -e /etc/systemd/system/home-ai-bridge.service'; then
  die "HOME AI Bridge уже установлен. Не перезаписываем работающую установку."
fi
if pct exec "$CTID" -- /bin/sh -c 'test -e /root/home-ai-bridge-install.tar.gz || test -e /root/home-ai-bridge-installer'; then
  die "Остались файлы предыдущей установки в LXC. Проверьте вручную перед повтором."
fi

say "Установка HOME AI Bridge в существующий LXC $CTID"
printf '%s\n' "Новые контейнеры, диски и сетевые настройки Proxmox создаваться не будут."
printf '%s\n' "В CT установятся сервер, systemd-служба и необходимые пакеты Debian."
printf '%s\n' "Служба слушает 0.0.0.0:8787, вход разрешён с частных сетей."
printf 'Для подтверждения установки в CT %s введите yes: ' "$CTID" >/dev/tty
IFS= read -r answer </dev/tty || die "Ввод прерван"
[[ "$answer" == yes ]] || die "Установка отменена"

WORKDIR="$(mktemp -d /tmp/home-ai-bridge-existing-XXXXXXXX)"
chmod 0700 "$WORKDIR"
say "Загружаю проверенный публичный пакет $VERSION"
curl -q --fail --silent --show-error --location --retry 2 \
  --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --output "$WORKDIR/$ASSET" "$URL" || die "Пакет недоступен"
printf '%s  %s\n' "$EXPECTED_SHA256" "$WORKDIR/$ASSET" | sha256sum --check --status ||
  die "Контрольная сумма SHA-256 не совпала"
mkdir -p "$WORKDIR/package"
tar -xzf "$WORKDIR/$ASSET" -C "$WORKDIR/package"
[[ -x "$WORKDIR/package/bin/home-ai-bridge-server" &&
   -f "$WORKDIR/package/deploy/proxmox/install-inside-lxc.sh" &&
   -f "$WORKDIR/package/deploy/proxmox/home-ai-bridge.service" ]] ||
  die "В скачанном архиве отсутствуют необходимые файлы"

tar -czf "$WORKDIR/install.tar.gz" -C "$WORKDIR/package" \
  bin/home-ai-bridge-server \
  deploy/proxmox/install-inside-lxc.sh \
  deploy/proxmox/home-ai-bridge.service
pct push "$CTID" "$WORKDIR/install.tar.gz" /root/home-ai-bridge-install.tar.gz --perms 0600
pct exec "$CTID" -- mkdir /root/home-ai-bridge-installer
pct exec "$CTID" -- tar -xzf /root/home-ai-bridge-install.tar.gz -C /root/home-ai-bridge-installer
pct exec "$CTID" -- /bin/bash /root/home-ai-bridge-installer/deploy/proxmox/install-inside-lxc.sh
pct exec "$CTID" -- rm -f /root/home-ai-bridge-install.tar.gz
pct exec "$CTID" -- rm -rf /root/home-ai-bridge-installer
say "HOME AI Bridge установлен в LXC $CTID"
printf 'Проверка: pct exec %s -- curl -fsS http://127.0.0.1:8787/health\n' "$CTID"
printf 'IP: pct exec %s -- hostname -I\n' "$CTID"
