#!/bin/bash
set -e

echo "=============================="
echo "Установка и настройка Cloudflare WARP для Xray"
echo "=============================="

# --- Проверка root ---
if [ "$(id -u)" -ne 0 ]; then
  echo "Скрипт нужно запускать от root"
  exit 1
fi

# --- Установка зависимостей ---
apt update -y
apt install -y wireguard resolvconf curl jq

# --- Установка wgcf ---
if ! command -v wgcf &>/dev/null; then
  echo "Устанавливаем wgcf..."
  WGCF_URL=$(curl -s https://api.github.com/repos/ViRb3/wgcf/releases/latest | jq -r '.assets[] | select(.name | contains("linux_amd64")) | .browser_download_url')
  wget -O /usr/local/bin/wgcf "$WGCF_URL"
  chmod +x /usr/local/bin/wgcf
else
  echo "wgcf уже установлен"
fi

cd /root

# --- Регистрация и генерация профиля ---
if [ ! -f wgcf-account.toml ]; then
  echo "Регистрируем аккаунт WARP..."
  yes | wgcf register
fi

wgcf generate

# --- Настройка wgcf.conf ---
WGCF_CONF="/etc/wireguard/wgcf.conf"
mv -f wgcf-profile.conf $WGCF_CONF

# Отключаем системные маршруты и добавляем таблицу для XRAY
sed -i '/^\[Interface\]/a Table = off' $WGCF_CONF
sed -i '/^\[Interface\]/a PostUp = ip rule add from $(ip -4 addr show wgcf | grep -oP "(?<=inet ).*(?=/)") table 51820' $WGCF_CONF
sed -i '/^\[Interface\]/a PostDown = ip rule delete from $(ip -4 addr show wgcf | grep -oP "(?<=inet ).*(?=/)") table 51820' $WGCF_CONF

# --- Автозапуск wgcf ---
systemctl enable wg-quick@wgcf
systemctl start wg-quick@wgcf || {
  echo "Не удалось запустить wgcf, пробуем вручную..."
  wg-quick up wgcf || echo "Ошибка при поднятии wgcf-интерфейса"
}

# --- Проверка интерфейса ---
if ip a show wgcf | grep -q inet; then
  echo "Интерфейс wgcf активен:"
  ip a show wgcf | grep inet
else
  echo "wgcf не имеет IP — попробуй перезапустить сервер."
fi

# --- Создаём мониторинг ---
cat >/usr/local/bin/check_warp.sh <<'EOF'
#!/bin/bash

# --- Проверяем интерфейс ---
if ! ip a show wgcf 2>/dev/null | grep -q "inet "; then
  systemctl restart wg-quick@wgcf
  sleep 5
fi

# --- Проверяем статус WARP ---
RESPONSE=$(curl -s --max-time 10 --interface wgcf https://www.cloudflare.com/cdn-cgi/trace || true)
WARP_STATUS=$(echo "$RESPONSE" | grep -E '^warp=' | cut -d= -f2)

if [ "$WARP_STATUS" != "on" ]; then
  systemctl restart wg-quick@wgcf
  sleep 5
fi

# --- Проверяем активен ли Xray ---
if ! systemctl is-active --quiet xray; then
  systemctl restart xray
fi

# --- Проверяем количество соединений ---
CONNS=$(ss -tnp | grep xray | wc -l)
if [ "$CONNS" -gt 3000 ]; then
    systemctl restart xray
fi
EOF

chmod +x /usr/local/bin/check_warp.sh

# --- Создаём systemd-сервис и таймер ---
cat >/etc/systemd/system/warp-monitor.service <<'EOF'
[Unit]
Description=Мониторинг Cloudflare WARP и Xray
After=network.target

[Service]
ExecStart=/usr/local/bin/check_warp.sh
Type=oneshot
StandardOutput=null
StandardError=journal
EOF

cat >/etc/systemd/system/warp-monitor.timer <<'EOF'
[Unit]
Description=Проверка состояния WARP и Xray каждые 30 секунд

[Timer]
OnBootSec=10s
OnUnitActiveSec=30s
Unit=warp-monitor.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now warp-monitor.timer

# --- Настройка XRAY ---
XRAY_SERVICE="/etc/systemd/system/xray.service"
XRAY_CONFIG="/usr/local/etc/xray/config.json"

if [[ -f "$XRAY_SERVICE" ]]; then
  echo "Настройка запуска XRAY от root..."
  sed -i 's/^User=.*/User=root/' "$XRAY_SERVICE" || true
  systemctl daemon-reload
fi

if [[ -f "$XRAY_CONFIG" ]]; then
  echo "Обновление блока outbounds..."
  jq '.outbounds = [
    {
      "protocol": "freedom",
      "tag": "direct",
      "streamSettings": {
        "sockopt": {
          "interface": "wgcf"
        }
      }
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]' "$XRAY_CONFIG" > /tmp/xray_new.json && mv /tmp/xray_new.json "$XRAY_CONFIG"
fi

# --- Ограничиваем размер journald ---
JOURNALD_CONF="/etc/systemd/journald.conf"
if ! grep -q "^SystemMaxUse=" "$JOURNALD_CONF"; then
  echo "SystemMaxUse=100M" >> "$JOURNALD_CONF"
  systemctl restart systemd-journald
  echo "Журнал ограничен до 100 МБ."
fi

systemctl restart xray

echo "=============================="
echo "Установка WARP с авто-мониторингом завершена."
echo "Логирование мониторинга подавлено (StandardOutput=null)."
echo "Размер журнала ограничен до 100 МБ."
echo "=============================="
