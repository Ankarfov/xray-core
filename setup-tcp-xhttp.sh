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
    "policy": {"levels": {"0": {"handshake": 3, "connIdle": 60}}}
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
ip="$2"
if [ -z "$email" ]; then exit 1; fi

if [ -z "$ip" ]; then
    ip=$(timeout 3 curl -4 -s icanhazip.com)
fi

pbk=$(awk -F': ' '/Password/ {print $2}' "$KEYS")
sid=$(awk -F': ' '/shortsid/ {print $2}' "$KEYS")

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

WORK_DIR="/tmp/xray-subs-work"
rm -rf "$WORK_DIR"

echo "Загружаю репозиторий..."
git clone "https://x-access-token:${token}@github.com/${repo}.git" "$WORK_DIR" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "Ошибка: не удалось клонировать репозиторий."
    rm -rf "$WORK_DIR"
    exit 1
fi

cd "$WORK_DIR"
git config user.email "xray@server"
git config user.name "xray"

# Сканируем репозиторий — строим submap
> "$SUBMAP"
for f in "$WORK_DIR"/*.txt; do
    [ -f "$f" ] || continue
    filename=$(basename "$f")
    first_link=$(base64 -d "$f" 2>/dev/null | head -1)
    if [ -z "$first_link" ]; then continue; fi
    email=$(echo "$first_link" | grep -oP '(?<=#)[^#]+$')
    if [ -z "$email" ]; then continue; fi
    echo "${email}=${filename}" >> "$SUBMAP"
done

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
    rm -rf "$WORK_DIR"
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
    rm -rf "$WORK_DIR"
    exit 1
fi

existing_files=$(ls "$WORK_DIR"/*.txt 2>/dev/null | xargs -I{} basename {} | sort)

SERVER_IP=$(timeout 3 curl -4 -s icanhazip.com)

for email in "${selected_emails[@]}"; do
    existing_file=$(grep "^${email}=" "$SUBMAP" 2>/dev/null | cut -d= -f2)
    if [ -n "$existing_file" ]; then
        filename="$existing_file"
    else
        while true; do
            filename="$(openssl rand -hex 10).txt"
            if ! echo "$existing_files" | grep -qx "$filename"; then
                break
            fi
        done
        echo "${email}=${filename}" >> "$SUBMAP"
        existing_files="${existing_files}\n${filename}"
    fi

    new_links=$(/usr/local/bin/_gen_sub "$email" "$SERVER_IP")

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

# === importusers (из git) ===
cat << 'EOF' > /usr/local/bin/importusers
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
REPO_FILE="/usr/local/etc/xray/.repo"
SUBMAP="/usr/local/etc/xray/.submap"

if [ ! -f "$REPO_FILE" ]; then
    echo "Репозиторий не настроен. Выполните editrepo."
    exit 1
fi

source "$REPO_FILE"

WORK_DIR="/tmp/xray-import-work"
rm -rf "$WORK_DIR"

echo "Загружаю репозиторий..."
git clone "https://x-access-token:${token}@github.com/${repo}.git" "$WORK_DIR" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "Ошибка: не удалось клонировать репозиторий."
    rm -rf "$WORK_DIR"
    exit 1
fi

declare -A user_uuid
declare -A user_file
user_emails=()

for f in "$WORK_DIR"/*.txt; do
    [ -f "$f" ] || continue
    filename=$(basename "$f")
    first_link=$(base64 -d "$f" 2>/dev/null | head -1)
    if [ -z "$first_link" ]; then continue; fi
    email=$(echo "$first_link" | grep -oP '(?<=#)[^#]+$')
    uuid=$(echo "$first_link" | grep -oP '(?<=://)[^@]+')
    if [ -z "$email" ] || [ -z "$uuid" ]; then continue; fi
    user_uuid["$email"]="$uuid"
    user_file["$email"]="$filename"
    user_emails+=("$email")
done

if [[ ${#user_emails[@]} -eq 0 ]]; then
    echo "В репозитории не найдено пользователей."
    rm -rf "$WORK_DIR"
    exit 1
fi

echo ""
echo "Найденные пользователи:"
for i in "${!user_emails[@]}"; do
    email="${user_emails[$i]}"
    exists=$(jq --arg email "$email" '.inbounds[0].settings.clients[] | select(.email == $email)' "$CONFIG")
    if [ -n "$exists" ]; then
        echo "$((i+1)). $email (уже существует)"
    else
        echo "$((i+1)). $email"
    fi
done
echo "a. Все новые пользователи"
echo ""
read -p "Выберите: " choice

selected_emails=()
if [ "$choice" = "a" ] || [ "$choice" = "A" ]; then
    for email in "${user_emails[@]}"; do
        exists=$(jq --arg email "$email" '.inbounds[0].settings.clients[] | select(.email == $email)' "$CONFIG")
        if [ -z "$exists" ]; then
            selected_emails+=("$email")
        fi
    done
elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#user_emails[@]} )); then
    selected_email="${user_emails[$((choice - 1))]}"
    exists=$(jq --arg email "$selected_email" '.inbounds[0].settings.clients[] | select(.email == $email)' "$CONFIG")
    if [ -n "$exists" ]; then
        echo "Пользователь $selected_email уже существует."
        rm -rf "$WORK_DIR"
        exit 1
    fi
    selected_emails+=("$selected_email")
else
    echo "Ошибка: неверный выбор."
    rm -rf "$WORK_DIR"
    exit 1
fi

if [[ ${#selected_emails[@]} -eq 0 ]]; then
    echo "Нет новых пользователей для импорта."
    rm -rf "$WORK_DIR"
    exit 0
fi

for email in "${selected_emails[@]}"; do
    uuid="${user_uuid[$email]}"
    filename="${user_file[$email]}"

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

    echo "${email}=${filename}" >> "$SUBMAP"
    echo "Импортирован: $email"
done

rm -rf "$WORK_DIR"
systemctl restart xray

echo ""
echo "Импорт завершён. Импортировано: ${#selected_emails[@]}"
echo "Используйте pushsubs для обновления подписок."
EOF
chmod +x /usr/local/bin/importusers

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
fi

systemctl restart xray
echo "Клиент $selected_email удалён."

if [ -n "$sub_filename" ] && [ -f "$REPO_FILE" ]; then
    source "$REPO_FILE"
    WORK_DIR="/tmp/xray-subs-work"
    rm -rf "$WORK_DIR"
    echo "Удаляю подписку из репозитория..."
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

# === mainuser ===
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

# === userlist ===
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

# === sharelink ===
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
    importusers   — импорт пользователей из git-репозитория

Порты:
    443  — TCP + Vision (основной)
    8443 — XHTTP (резервный)

Конфигурация: /usr/local/etc/xray/config.json
Перезагрузка:  systemctl restart xray

EOF
