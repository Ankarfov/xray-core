#!/bin/bash
echo "=============================="
echo "Установка Vless: TCP+Vision (443) + XHTTP (8443)"
echo "=============================="
sleep 3
apt update
apt install qrencode curl jq git -y

# Включаем bbr
bbr=$(sysctl -a | grep net.ipv4.tcp_congestion_control)
if [ "$bbr" = "net.ipv4.tcp_congestion_control = bbr" ]; then
echo "bbr уже включен"
else
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p
echo "bbr включен"
fi

# Устанавливаем ядро Xray
bash -c "$(curl -4 -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
[ -f /usr/local/etc/xray/.keys ] && rm /usr/local/etc/xray/.keys
touch /usr/local/etc/xray/.keys
echo "shortsid: $(openssl rand -hex 8)" >> /usr/local/etc/xray/.keys
echo "uuid: $(xray uuid)" >> /usr/local/etc/xray/.keys
xray x25519 >> /usr/local/etc/xray/.keys

export uuid=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/uuid/ {print $2}')
export privatkey=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/PrivateKey/ {print $2}')
export shortsid=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/shortsid/ {print $2}')

# Создаем файл конфигурации Xray
cat << EOF > /usr/local/etc/xray/config.json
{
    "log": {
        "loglevel": "warning"
    },
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "domain": [
                    "geosite:category-ads-all"
                ],
                "outboundTag": "block"
            },
            {
                "type": "field",
                "protocol": [
                    "bittorrent"
                ],
                "outboundTag": "block"
            }
        ]
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": 443,
            "protocol": "vless",
            "tag": "vless-tcp",
            "settings": {
                "clients": [
                    {
                        "email": "main",
                        "id": "$uuid",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "github.com:443",
                    "xver": 0,
                    "serverNames": [
                        "github.com",
                        "www.github.com"
                    ],
                    "privateKey": "$privatkey",
                    "minClientVer": "",
                    "maxClientVer": "",
                    "maxTimeDiff": 0,
                    "shortIds": [
                        "$shortsid"
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls",
                    "quic",
                    "fakedns"
                ]
            }
        },
        {
            "listen": "0.0.0.0",
            "port": 8443,
            "protocol": "vless",
            "tag": "vless-xhttp",
            "settings": {
                "clients": [
                    {
                        "email": "main",
                        "id": "$uuid",
                        "flow": ""
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "xhttp",
                "xhttpSettings": {
                    "path": "/"
                },
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "github.com:443",
                    "xver": 0,
                    "serverNames": [
                        "github.com",
                        "www.github.com"
                    ],
                    "privateKey": "$privatkey",
                    "minClientVer": "",
                    "maxClientVer": "",
                    "maxTimeDiff": 0,
                    "shortIds": [
                        "$shortsid"
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls",
                    "quic",
                    "fakedns"
                ]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ],
    "policy": {
        "levels": {
            "0": {
                "handshake": 3,
                "connIdle": 180
            }
        }
    }
}
EOF

# Создаём файл для хранения маппинга пользователь -> файл подписки
touch /usr/local/etc/xray/.submap

# ==================== КОМАНДЫ ====================

# editrepo — настройка репозитория и токена
cat << 'EOF' > /usr/local/bin/editrepo
#!/bin/bash
REPO_FILE="/usr/local/etc/xray/.repo"

echo "Настройка репозитория для подписок"
echo ""

if [ -f "$REPO_FILE" ]; then
    echo "Текущие настройки:"
    cat "$REPO_FILE"
    echo ""
    read -p "Перезаписать? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        echo "Отменено."
        exit 0
    fi
fi

read -p "GitHub репозиторий (user/repo): " repo
read -p "GitHub токен: " token
read -p "URL сайта (например https://mysite.netlify.app): " site_url

# Убираем trailing slash
site_url="${site_url%/}"

cat > "$REPO_FILE" << CONF
repo=$repo
token=$token
site_url=$site_url
CONF

chmod 600 "$REPO_FILE"
echo ""
echo "Настройки сохранены."
EOF
chmod +x /usr/local/bin/editrepo

# userlist — список клиентов
cat << 'EOF' > /usr/local/bin/userlist
#!/bin/bash
emails=($(jq -r '.inbounds[0].settings.clients[].email' "/usr/local/etc/xray/config.json"))

if [[ ${#emails[@]} -eq 0 ]]; then
    echo "Список клиентов пуст"
    exit 1
fi

echo "Список клиентов:"
for i in "${!emails[@]}"; do
    echo "$((i+1)). ${emails[$i]}"
done
EOF
chmod +x /usr/local/bin/userlist

# mainuser — ссылки основного пользователя (TCP + XHTTP)
cat << 'EOF' > /usr/local/bin/mainuser
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
KEYS="/usr/local/etc/xray/.keys"

uuid=$(awk -F': ' '/uuid/ {print $2}' "$KEYS")
pbk=$(awk -F': ' '/Password/ {print $2}' "$KEYS")
sid=$(awk -F': ' '/shortsid/ {print $2}' "$KEYS")
ip=$(timeout 3 curl -4 -s icanhazip.com)

INBOUND_COUNT=$(jq '.inbounds | length' "$CONFIG")
for (( i=0; i<INBOUND_COUNT; i++ )); do
    network=$(jq -r --argjson idx "$i" '.inbounds[$idx].streamSettings.network' "$CONFIG")
    port=$(jq -r --argjson idx "$i" '.inbounds[$idx].port' "$CONFIG")
    sni=$(jq -r --argjson idx "$i" '.inbounds[$idx].streamSettings.realitySettings.serverNames[0]' "$CONFIG")
    flow=$(jq -r --argjson idx "$i" '.inbounds[$idx].settings.clients[0].flow // ""' "$CONFIG")

    if [ "$network" = "tcp" ]; then
        link="vless://$uuid@$ip:$port?security=reality&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=/&type=tcp&flow=$flow&encryption=none#$ip"
        echo ""
        echo "=== TCP (порт $port) ==="
    elif [ "$network" = "xhttp" ]; then
        path=$(jq -r --argjson idx "$i" '.inbounds[$idx].streamSettings.xhttpSettings.path' "$CONFIG")
        link="vless://$uuid@$ip:$port?security=reality&path=$(echo $path | sed 's|/|%2F|g')&mode=auto&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=%2F&type=xhttp&encryption=none#$ip"
        echo ""
        echo "=== XHTTP (порт $port) ==="
    else
        continue
    fi

    echo "$link"
    echo ""
    echo "QR-код:"
    echo "$link" | qrencode -t ansiutf8
done
EOF
chmod +x /usr/local/bin/mainuser

# _gen_sub — внутренняя функция генерации файла подписки для пользователя
cat << 'GENEOF' > /usr/local/bin/_gen_sub
#!/bin/bash
# Использование: _gen_sub <email>
CONFIG="/usr/local/etc/xray/config.json"
KEYS="/usr/local/etc/xray/.keys"
SUBMAP="/usr/local/etc/xray/.submap"

email="$1"
if [ -z "$email" ]; then
    exit 1
fi

pbk=$(awk -F': ' '/Password/ {print $2}' "$KEYS")
sid=$(awk -F': ' '/shortsid/ {print $2}' "$KEYS")
ip=$(timeout 3 curl -4 -s icanhazip.com)

links=""
INBOUND_COUNT=$(jq '.inbounds | length' "$CONFIG")
for (( i=0; i<INBOUND_COUNT; i++ )); do
    network=$(jq -r --argjson idx "$i" '.inbounds[$idx].streamSettings.network' "$CONFIG")
    port=$(jq -r --argjson idx "$i" '.inbounds[$idx].port' "$CONFIG")
    sni=$(jq -r --argjson idx "$i" '.inbounds[$idx].streamSettings.realitySettings.serverNames[0]' "$CONFIG")
    uuid=$(jq -r --argjson idx "$i" --arg email "$email" '.inbounds[$idx].settings.clients[] | select(.email == $email) | .id' "$CONFIG")
    flow=$(jq -r --argjson idx "$i" --arg email "$email" '.inbounds[$idx].settings.clients[] | select(.email == $email) | .flow // ""' "$CONFIG")

    if [ -z "$uuid" ]; then
        continue
    fi

    if [ "$network" = "tcp" ]; then
        link="vless://$uuid@$ip:$port?security=reality&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=/&type=tcp&flow=$flow&encryption=none#$email"
    elif [ "$network" = "xhttp" ]; then
        path=$(jq -r --argjson idx "$i" '.inbounds[$idx].streamSettings.xhttpSettings.path' "$CONFIG")
        link="vless://$uuid@$ip:$port?security=reality&path=$(echo $path | sed 's|/|%2F|g')&mode=auto&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=%2F&type=xhttp&encryption=none#$email"
    else
        continue
    fi

    if [ -n "$links" ]; then
        links="$links\n$link"
    else
        links="$link"
    fi
done

echo -e "$links" | base64 -w 0
GENEOF
chmod +x /usr/local/bin/_gen_sub

# pushsubs — генерация и пуш подписок в GitHub
cat << 'EOF' > /usr/local/bin/pushsubs
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
REPO_FILE="/usr/local/etc/xray/.repo"
SUBMAP="/usr/local/etc/xray/.submap"

if [ ! -f "$REPO_FILE" ]; then
    echo "Репозиторий не настроен. Выполните editrepo."
    exit 1
fi

source "$REPO_FILE"

if [ -z "$repo" ] || [ -z "$token" ]; then
    echo "Неполные настройки репозитория. Выполните editrepo."
    exit 1
fi

WORK_DIR="/tmp/xray-subs-work"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

# Клонируем репозиторий
git clone "https://x-access-token:${token}@github.com/${repo}.git" "$WORK_DIR" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "Ошибка: не удалось клонировать репозиторий."
    rm -rf "$WORK_DIR"
    exit 1
fi

cd "$WORK_DIR"
git config user.email "xray@server"
git config user.name "xray"

# Удаляем старые файлы подписок (кроме .gitkeep и .git)
find "$WORK_DIR" -maxdepth 1 -type f ! -name '.gitkeep' -delete

# Генерируем подписки для каждого пользователя
emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG"))

> "$SUBMAP"

for email in "${emails[@]}"; do
    # Проверяем есть ли уже маппинг
    existing_file=$(grep "^${email}=" /usr/local/etc/xray/.submap.old 2>/dev/null | cut -d= -f2)
    if [ -n "$existing_file" ]; then
        filename="$existing_file"
    else
        filename="$(openssl rand -hex 10).txt"
    fi

    # Генерируем содержимое подписки
    sub_content=$(/usr/local/bin/_gen_sub "$email")
    echo "$sub_content" > "${WORK_DIR}/${filename}"

    echo "${email}=${filename}" >> "$SUBMAP"
done

# Сохраняем старый маппинг для следующего раза
cp "$SUBMAP" /usr/local/etc/xray/.submap.old

# Пушим
git add -A
git commit -m "update subs" 2>/dev/null

if [ $? -eq 0 ]; then
    git push 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "Подписки обновлены."
    else
        echo "Ошибка при пуше."
    fi
else
    echo "Нет изменений для пуша."
fi

rm -rf "$WORK_DIR"
EOF
chmod +x /usr/local/bin/pushsubs

# sharesubs — показать ссылки на подписки пользователей
cat << 'EOF' > /usr/local/bin/sharesubs
#!/bin/bash
REPO_FILE="/usr/local/etc/xray/.repo"
SUBMAP="/usr/local/etc/xray/.submap"

if [ ! -f "$REPO_FILE" ]; then
    echo "Репозиторий не настроен. Выполните editrepo."
    exit 1
fi

if [ ! -f "$SUBMAP" ] || [ ! -s "$SUBMAP" ]; then
    echo "Подписки не сгенерированы. Выполните pushsubs."
    exit 1
fi

source "$REPO_FILE"

echo ""
echo "Ссылки на подписки:"
echo ""
while IFS='=' read -r email filename; do
    echo "$email:"
    echo "  ${site_url}/${filename}"
    echo ""
done < "$SUBMAP"
EOF
chmod +x /usr/local/bin/sharesubs

# newuser — создание пользователя (без QR и ссылок)
cat << 'EOF' > /usr/local/bin/newuser
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"

read -p "Введите имя пользователя (email): " email

if [[ -z "$email" || "$email" == *" "* ]]; then
    echo "Имя пользователя не может быть пустым или содержать пробелы."
    exit 1
fi

existing=$(jq --arg email "$email" '.inbounds[0].settings.clients[] | select(.email == $email)' "$CONFIG")
if [[ -n "$existing" ]]; then
    echo "Пользователь с таким именем уже существует."
    exit 1
fi

uuid=$(xray uuid)

# Добавляем во все inbound
INBOUND_COUNT=$(jq '.inbounds | length' "$CONFIG")
for (( i=0; i<INBOUND_COUNT; i++ )); do
    network=$(jq -r --argjson idx "$i" '.inbounds[$idx].streamSettings.network' "$CONFIG")
    if [ "$network" = "tcp" ]; then
        jq --argjson idx "$i" --arg email "$email" --arg uuid "$uuid" \
           '(.inbounds[$idx].settings.clients) += [{"email": $email, "id": $uuid, "flow": "xtls-rprx-vision"}]' \
           "$CONFIG" > tmp.json && mv tmp.json "$CONFIG"
    else
        jq --argjson idx "$i" --arg email "$email" --arg uuid "$uuid" \
           '(.inbounds[$idx].settings.clients) += [{"email": $email, "id": $uuid, "flow": ""}]' \
           "$CONFIG" > tmp.json && mv tmp.json "$CONFIG"
    fi
done

systemctl restart xray
echo "Пользователь $email создан."

# Автоматически обновляем подписки
if [ -f /usr/local/etc/xray/.repo ]; then
    pushsubs
fi
EOF
chmod +x /usr/local/bin/newuser

# rmuser — удаление пользователя из всех inbound
cat << 'EOF' > /usr/local/bin/rmuser
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG"))

if [[ ${#emails[@]} -eq 0 ]]; then
    echo "Нет клиентов для удаления."
    exit 1
fi

echo "Список клиентов:"
for i in "${!emails[@]}"; do
    echo "$((i+1)). ${emails[$i]}"
done

read -p "Введите номер клиента для удаления: " choice

if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#emails[@]} )); then
    echo "Ошибка: номер должен быть от 1 до ${#emails[@]}"
    exit 1
fi

selected_email="${emails[$((choice - 1))]}"

# Удаляем из всех inbound
INBOUND_COUNT=$(jq '.inbounds | length' "$CONFIG")
for (( i=0; i<INBOUND_COUNT; i++ )); do
    jq --argjson idx "$i" --arg email "$selected_email" \
       '(.inbounds[$idx].settings.clients) |= map(select(.email != $email))' \
       "$CONFIG" > tmp && mv tmp "$CONFIG"
done

# Удаляем маппинг подписки
SUBMAP="/usr/local/etc/xray/.submap"
if [ -f "$SUBMAP" ]; then
    sed -i "/^${selected_email}=/d" "$SUBMAP"
    cp "$SUBMAP" /usr/local/etc/xray/.submap.old
fi

systemctl restart xray
echo "Клиент $selected_email удалён."

# Автоматически обновляем подписки
if [ -f /usr/local/etc/xray/.repo ]; then
    pushsubs
fi
EOF
chmod +x /usr/local/bin/rmuser

# sharelink — ссылки для выбранного клиента (все inbound)
cat << 'EOF' > /usr/local/bin/sharelink
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
KEYS="/usr/local/etc/xray/.keys"

emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG"))

if [[ ${#emails[@]} -eq 0 ]]; then
    echo "Нет клиентов."
    exit 1
fi

for i in "${!emails[@]}"; do
   echo "$((i + 1)). ${emails[$i]}"
done

read -p "Выберите клиента: " client

if ! [[ "$client" =~ ^[0-9]+$ ]] || (( client < 1 || client > ${#emails[@]} )); then
    echo "Ошибка: номер должен быть от 1 до ${#emails[@]}"
    exit 1
fi

selected_email="${emails[$((client - 1))]}"

pbk=$(awk -F': ' '/Password/ {print $2}' "$KEYS")
sid=$(awk -F': ' '/shortsid/ {print $2}' "$KEYS")
ip=$(timeout 3 curl -4 -s icanhazip.com)

INBOUND_COUNT=$(jq '.inbounds | length' "$CONFIG")
for (( i=0; i<INBOUND_COUNT; i++ )); do
    network=$(jq -r --argjson idx "$i" '.inbounds[$idx].streamSettings.network' "$CONFIG")
    port=$(jq -r --argjson idx "$i" '.inbounds[$idx].port' "$CONFIG")
    sni=$(jq -r --argjson idx "$i" '.inbounds[$idx].streamSettings.realitySettings.serverNames[0]' "$CONFIG")
    uuid=$(jq -r --argjson idx "$i" --arg email "$selected_email" '.inbounds[$idx].settings.clients[] | select(.email == $email) | .id' "$CONFIG")
    flow=$(jq -r --argjson idx "$i" --arg email "$selected_email" '.inbounds[$idx].settings.clients[] | select(.email == $email) | .flow // ""' "$CONFIG")

    if [ -z "$uuid" ]; then continue; fi

    if [ "$network" = "tcp" ]; then
        link="vless://$uuid@$ip:$port?security=reality&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=/&type=tcp&flow=$flow&encryption=none#$selected_email"
        echo ""
        echo "=== TCP (порт $port) ==="
    elif [ "$network" = "xhttp" ]; then
        path=$(jq -r --argjson idx "$i" '.inbounds[$idx].streamSettings.xhttpSettings.path' "$CONFIG")
        link="vless://$uuid@$ip:$port?security=reality&path=$(echo $path | sed 's|/|%2F|g')&mode=auto&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=%2F&type=xhttp&encryption=none#$selected_email"
        echo ""
        echo "=== XHTTP (порт $port) ==="
    else
        continue
    fi

    echo "$link"
    echo ""
    echo "QR-код:"
    echo "$link" | qrencode -t ansiutf8
done
EOF
chmod +x /usr/local/bin/sharelink

# exportusers — экспорт пользователей и ключей
cat << 'EOF' > /usr/local/bin/exportusers
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
KEYS="/usr/local/etc/xray/.keys"
EXPORT_DIR="/tmp/xray-export"

rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"

jq '.inbounds[0].settings.clients' "$CONFIG" > "$EXPORT_DIR/clients.json"
cp "$KEYS" "$EXPORT_DIR/.keys"
[ -f /usr/local/etc/xray/.submap ] && cp /usr/local/etc/xray/.submap "$EXPORT_DIR/.submap"

ARCHIVE="$HOME/xray-users-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "$ARCHIVE" -C "$EXPORT_DIR" .
rm -rf "$EXPORT_DIR"

echo ""
echo "Экспорт завершён!"
echo "Файл: $ARCHIVE"
echo ""
echo "Скопируйте архив на новый сервер:"
echo "  scp $ARCHIVE root@NEW_SERVER_IP:~/"
echo ""
echo "На новом сервере выполните:"
echo "  importusers ~/$(basename $ARCHIVE)"
EOF
chmod +x /usr/local/bin/exportusers

# importusers — импорт пользователей и ключей
cat << 'EOF' > /usr/local/bin/importusers
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
KEYS="/usr/local/etc/xray/.keys"

if [[ -z "$1" ]]; then
    echo "Использование: importusers <путь_к_архиву>"
    exit 1
fi

if [[ ! -f "$1" ]]; then
    echo "Ошибка: файл $1 не найден"
    exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
    echo "Ошибка: конфиг Xray не найден."
    exit 1
fi

IMPORT_DIR="/tmp/xray-import"
rm -rf "$IMPORT_DIR"
mkdir -p "$IMPORT_DIR"
tar -xzf "$1" -C "$IMPORT_DIR"

if [[ ! -f "$IMPORT_DIR/clients.json" || ! -f "$IMPORT_DIR/.keys" ]]; then
    echo "Ошибка: архив повреждён или неверный формат"
    rm -rf "$IMPORT_DIR"
    exit 1
fi

CLIENT_COUNT=$(jq 'length' "$IMPORT_DIR/clients.json")
echo "Найдено клиентов: $CLIENT_COUNT"

# Клиенты для каждого inbound
INBOUND_COUNT=$(jq '.inbounds | length' "$CONFIG")
for (( i=0; i<INBOUND_COUNT; i++ )); do
    network=$(jq -r --argjson idx "$i" '.inbounds[$idx].streamSettings.network' "$CONFIG")
    if [ "$network" = "tcp" ]; then
        CLIENTS=$(jq '[.[] | . + {"flow": "xtls-rprx-vision"}]' "$IMPORT_DIR/clients.json")
    else
        CLIENTS=$(jq '[.[] | {email, id} + {"flow": ""}]' "$IMPORT_DIR/clients.json")
    fi
    jq --argjson idx "$i" --argjson clients "$CLIENTS" \
       '.inbounds[$idx].settings.clients = $clients' \
       "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
done

# Восстанавливаем ключи
cp "$IMPORT_DIR/.keys" "$KEYS"

# Восстанавливаем маппинг подписок
if [ -f "$IMPORT_DIR/.submap" ]; then
    cp "$IMPORT_DIR/.submap" /usr/local/etc/xray/.submap
    cp "$IMPORT_DIR/.submap" /usr/local/etc/xray/.submap.old
fi

PRIVKEY=$(awk -F': ' '/PrivateKey/ {print $2}' "$KEYS")
SHORTSID=$(awk -F': ' '/shortsid/ {print $2}' "$KEYS")

# Обновляем ключи во всех inbound
for (( i=0; i<INBOUND_COUNT; i++ )); do
    jq --argjson idx "$i" --arg pk "$PRIVKEY" --arg sid "$SHORTSID" \
       '.inbounds[$idx].streamSettings.realitySettings.privateKey = $pk |
        .inbounds[$idx].streamSettings.realitySettings.shortIds = [$sid]' \
       "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
done

rm -rf "$IMPORT_DIR"
systemctl restart xray

echo ""
echo "Импорт завершён! Xray перезапущен."
echo "Импортировано клиентов: $CLIENT_COUNT"
echo ""
echo "Используйте pushsubs для обновления подписок."
EOF
chmod +x /usr/local/bin/importusers

systemctl restart xray

echo ""
echo "=============================="
echo "Xray-core успешно установлен"
echo "TCP+Vision на порту 443"
echo "XHTTP на порту 8443"
echo "=============================="
echo ""
echo "Выполните editrepo для настройки репозитория подписок."
echo ""
mainuser

# Файл с подсказками
cat << 'EOF' > $HOME/help

Команды для управления Xray:

    mainuser      — ссылки основного пользователя
    newuser       — создать нового пользователя
    rmuser        — удалить пользователя
    sharelink     — ссылки и QR-коды для пользователя
    userlist      — список клиентов

    editrepo      — настройка репозитория и токена
    pushsubs      — обновить подписки в репозитории
    sharesubs     — показать ссылки на подписки

    exportusers   — экспорт пользователей в архив
    importusers <архив> — импорт пользователей из архива

Порты:
    443  — TCP + Vision (основной)
    8443 — XHTTP (резервный)

Конфигурация: /usr/local/etc/xray/config.json
Перезагрузка:  systemctl restart xray

EOF
