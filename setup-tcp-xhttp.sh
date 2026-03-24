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

bash -c "$(curl -4 -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
[ -f /usr/local/etc/xray/.keys ] && rm /usr/local/etc/xray/.keys
touch /usr/local/etc/xray/.keys
echo "shortsid: $(openssl rand -hex 8)" >> /usr/local/etc/xray/.keys
echo "uuid: $(xray uuid)" >> /usr/local/etc/xray/.keys
xray x25519 >> /usr/local/etc/xray/.keys

export uuid=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/uuid/ {print $2}')
export privatkey=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/PrivateKey/ {print $2}')
export shortsid=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/shortsid/ {print $2}')

cat << EOF > /usr/local/etc/xray/config.json
{
    "log": {"loglevel": "warning"},
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {"type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block"},
            {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}
        ]
    },
    "inbounds": [
        {
            "listen": "0.0.0.0", "port": 443, "protocol": "vless", "tag": "vless-tcp",
            "settings": {"clients": [{"email": "main", "id": "$uuid", "flow": "xtls-rprx-vision"}], "decryption": "none"},
            "streamSettings": {
                "network": "tcp", "security": "reality",
                "realitySettings": {
                    "show": false, "dest": "github.com:443", "xver": 0,
                    "serverNames": ["github.com", "www.github.com"],
                    "privateKey": "$privatkey", "shortIds": ["$shortsid"]
                }
            },
            "sniffing": {"enabled": true, "destOverride": ["http","tls","quic","fakedns"]}
        },
        {
            "listen": "0.0.0.0", "port": 8443, "protocol": "vless", "tag": "vless-xhttp",
            "settings": {"clients": [{"email": "main", "id": "$uuid", "flow": ""}], "decryption": "none"},
            "streamSettings": {
                "network": "xhttp", "xhttpSettings": {"path": "/"},
                "security": "reality",
                "realitySettings": {
                    "show": false, "dest": "github.com:443", "xver": 0,
                    "serverNames": ["github.com", "www.github.com"],
                    "privateKey": "$privatkey", "shortIds": ["$shortsid"]
                }
            },
            "sniffing": {"enabled": true, "destOverride": ["http","tls","quic","fakedns"]}
        }
    ],
    "outbounds": [
        {"protocol": "freedom", "tag": "direct"},
        {"protocol": "blackhole", "tag": "block"}
    ],
    "policy": {"levels": {"0": {"handshake": 3, "connIdle": 180}}}
}
EOF

touch /usr/local/etc/xray/.submap

# === editrepo ===
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

# === _gen_sub ===
cat << 'EOF' > /usr/local/bin/_gen_sub
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
KEYS="/usr/local/etc/xray/.keys"

email="$1"
if [ -z "$email" ]; then exit 1; fi

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

    if [ -z "$uuid" ]; then continue; fi

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

echo -e "$links"
EOF
chmod +x /usr/local/bin/_gen_sub

# === pushsubs ===
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
    echo "Неполные настройки. Выполните editrepo."
    exit 1
fi

emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG"))

if [[ ${#emails[@]} -eq 0 ]]; then
    echo "Нет клиентов."
    exit 1
fi

echo ""
echo "Список клиентов:"
for i in "${!emails[@]}"; do
    echo "$((i+1)). ${emails[$i]}"
done
echo "a. Все пользователи"
echo ""
read -p "Выберите: " choice

selected_emails=()
if [ "$choice" = "a" ] || [ "$choice" = "A" ]; then
    selected_emails=("${emails[@]}")
elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#emails[@]} )); then
    selected_emails=("${emails[$((choice - 1))]}")
else
    echo "Ошибка: неверный выбор."
    exit 1
fi

echo ""
echo "Режим:"
echo "1. Перезаписать (только ссылки этого сервера)"
echo "2. Дописать (добавить ссылки к существующим)"
echo ""
read -p "Выберите режим (1/2): " mode

if [ "$mode" != "1" ] && [ "$mode" != "2" ]; then
    echo "Ошибка: выберите 1 или 2."
    exit 1
fi

WORK_DIR="/tmp/xray-subs-work"
rm -rf "$WORK_DIR"

git clone "https://x-access-token:${token}@github.com/${repo}.git" "$WORK_DIR" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "Ошибка: не удалось клонировать репозиторий."
    rm -rf "$WORK_DIR"
    exit 1
fi

cd "$WORK_DIR"
git config user.email "xray@server"
git config user.name "xray"
cp "$SUBMAP" /usr/local/etc/xray/.submap.old 2>/dev/null

for email in "${selected_emails[@]}"; do
    existing_file=$(grep "^${email}=" "$SUBMAP" 2>/dev/null | cut -d= -f2)
    if [ -n "$existing_file" ]; then
        filename="$existing_file"
    else
        filename="$(openssl rand -hex 10).txt"
        echo "${email}=${filename}" >> "$SUBMAP"
    fi

    new_links=$(/usr/local/bin/_gen_sub "$email")

    if [ "$mode" = "2" ] && [ -f "${WORK_DIR}/${filename}" ]; then
        existing_links=$(base64 -d "${WORK_DIR}/${filename}" 2>/dev/null || echo "")
        if [ -n "$existing_links" ]; then
            combined="${existing_links}\n${new_links}"
        else
            combined="$new_links"
        fi
        echo -e "$combined" | base64 -w 0 > "${WORK_DIR}/${filename}"
    else
        echo -e "$new_links" | base64 -w 0 > "${WORK_DIR}/${filename}"
    fi
done

cp "$SUBMAP" /usr/local/etc/xray/.submap.old

git add -A
git commit -m "update subs" 2>/dev/null

if [ $? -eq 0 ]; then
    git push 2>/dev/null
    if [ $? -eq 0 ]; then
        echo ""
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

# === sharesubs ===
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
mapfile -t entries < "$SUBMAP"

if [[ ${#entries[@]} -eq 0 ]]; then
    echo "Нет подписок."
    exit 1
fi

echo ""
echo "Список клиентов:"
for i in "${!entries[@]}"; do
    email=$(echo "${entries[$i]}" | cut -d= -f1)
    echo "$((i+1)). $email"
done
echo "a. Все пользователи"
echo ""
read -p "Выберите: " choice

echo ""
if [ "$choice" = "a" ] || [ "$choice" = "A" ]; then
    for entry in "${entries[@]}"; do
        email=$(echo "$entry" | cut -d= -f1)
        filename=$(echo "$entry" | cut -d= -f2)
        echo "$email:"
        echo "  ${site_url}/${filename}"
        echo ""
    done
elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#entries[@]} )); then
    entry="${entries[$((choice - 1))]}"
    email=$(echo "$entry" | cut -d= -f1)
    filename=$(echo "$entry" | cut -d= -f2)
    echo "$email:"
    echo "  ${site_url}/${filename}"
    echo ""
else
    echo "Ошибка: неверный выбор."
    exit 1
fi
EOF
chmod +x /usr/local/bin/sharesubs

# === newuser (без QR) ===
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
echo "Используйте pushsubs для обновления подписок."
EOF
chmod +x /usr/local/bin/newuser

# === rmuser ===
cat << 'EOF' > /usr/local/bin/rmuser
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
REPO_FILE="/usr/local/etc/xray/.repo"
SUBMAP="/usr/local/etc/xray/.submap"

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

INBOUND_COUNT=$(jq '.inbounds | length' "$CONFIG")
for (( i=0; i<INBOUND_COUNT; i++ )); do
    jq --argjson idx "$i" --arg email "$selected_email" \
       '(.inbounds[$idx].settings.clients) |= map(select(.email != $email))' \
       "$CONFIG" > tmp && mv tmp "$CONFIG"
done

sub_filename=$(grep "^${selected_email}=" "$SUBMAP" 2>/dev/null | cut -d= -f2)

if [ -f "$SUBMAP" ]; then
    sed -i "/^${selected_email}=/d" "$SUBMAP"
    cp "$SUBMAP" /usr/local/etc/xray/.submap.old
fi

systemctl restart xray
echo "Клиент $selected_email удалён."

if [ -n "$sub_filename" ] && [ -f "$REPO_FILE" ]; then
    source "$REPO_FILE"
    WORK_DIR="/tmp/xray-subs-work"
    rm -rf "$WORK_DIR"
    git clone "https://x-access-token:${token}@github.com/${repo}.git" "$WORK_DIR" 2>/dev/null
    if [ $? -eq 0 ]; then
        cd "$WORK_DIR"
        git config user.email "xray@server"
        git config user.name "xray"
        rm -f "${WORK_DIR}/${sub_filename}"
        git add -A
        git commit -m "remove $selected_email" 2>/dev/null
        git push 2>/dev/null && echo "Подписка удалена из репозитория."
    fi
    rm -rf "$WORK_DIR"
fi
EOF
chmod +x /usr/local/bin/rmuser

# === exportusers ===
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
echo "Экспорт завершён! Файл: $ARCHIVE"
echo "  scp $ARCHIVE root@NEW_SERVER_IP:~/"
echo "  importusers ~/$(basename $ARCHIVE)"
EOF
chmod +x /usr/local/bin/exportusers

# === importusers ===
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

IMPORT_DIR="/tmp/xray-import"
rm -rf "$IMPORT_DIR"
mkdir -p "$IMPORT_DIR"
tar -xzf "$1" -C "$IMPORT_DIR"

if [[ ! -f "$IMPORT_DIR/clients.json" || ! -f "$IMPORT_DIR/.keys" ]]; then
    echo "Ошибка: архив повреждён"
    rm -rf "$IMPORT_DIR"
    exit 1
fi

CLIENT_COUNT=$(jq 'length' "$IMPORT_DIR/clients.json")
echo "Найдено клиентов: $CLIENT_COUNT"

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

cp "$IMPORT_DIR/.keys" "$KEYS"
[ -f "$IMPORT_DIR/.submap" ] && cp "$IMPORT_DIR/.submap" /usr/local/etc/xray/.submap && cp "$IMPORT_DIR/.submap" /usr/local/etc/xray/.submap.old

PRIVKEY=$(awk -F': ' '/PrivateKey/ {print $2}' "$KEYS")
SHORTSID=$(awk -F': ' '/shortsid/ {print $2}' "$KEYS")

for (( i=0; i<INBOUND_COUNT; i++ )); do
    jq --argjson idx "$i" --arg pk "$PRIVKEY" --arg sid "$SHORTSID" \
       '.inbounds[$idx].streamSettings.realitySettings.privateKey = $pk |
        .inbounds[$idx].streamSettings.realitySettings.shortIds = [$sid]' \
       "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
done

rm -rf "$IMPORT_DIR"
systemctl restart xray
echo "Импорт завершён! Используйте pushsubs для обновления подписок."
EOF
chmod +x /usr/local/bin/importusers

echo ""
echo "=============================="
echo "Установлены команды:"
echo "  editrepo  — настройка репозитория и токена"
echo "  pushsubs  — обновить подписки (выбор пользователей + режим)"
echo "  sharesubs — показать ссылки на подписки"
echo "  exportusers / importusers"
echo ""
echo "Обновлены: newuser (без QR), rmuser (с удалением подписки)"
echo ""
echo "Выполните editrepo для начала работы."
echo "=============================="

systemctl restart xray

echo ""
echo "=============================="
echo "Xray-core успешно установлен"
echo "TCP+Vision на порту 443"
echo "XHTTP на порту 8443"
echo "=============================="
echo ""
echo "Выполните editrepo для настройки подписок."
echo ""
mainuser

cat << 'EOF' > $HOME/help

Команды для управления Xray:

    mainuser      — ссылки основного пользователя
    newuser       — создать нового пользователя
    rmuser        — удалить пользователя
    sharelink     — ссылки и QR-коды для пользователя
    userlist      — список клиентов

    editrepo      — настройка репозитория и токена
    pushsubs      — обновить подписки (выбор пользователей + режим)
    sharesubs     — показать ссылки на подписки

    exportusers   — экспорт пользователей в архив
    importusers <архив> — импорт пользователей из архива

Порты:
    443  — TCP + Vision (основной)
    8443 — XHTTP (резервный)

Конфигурация: /usr/local/etc/xray/config.json
Перезагрузка:  systemctl restart xray

EOF
