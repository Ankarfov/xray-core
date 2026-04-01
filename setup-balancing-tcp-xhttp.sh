#!/bin/bash
export NEEDRESTART_MODE=a
export DEBIAN_FRONTEND=noninteractive
echo "=============================="
echo "Установка RU-сервера (балансировщик + RU-прокси)"
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
chmod 600 /usr/local/etc/xray/.keys

export uuid=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/uuid/ {print $2}')
export privatkey=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/PrivateKey/ {print $2}')
export shortsid=$(cat /usr/local/etc/xray/.keys | awk -F': ' '/shortsid/ {print $2}')

# Начальный конфиг — только inbound'ы и direct/block
# outbound'ы с серверами добавит pullconfig
cat << EOF > /usr/local/etc/xray/config.json
{
    "log": {"loglevel": "warning"},
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {"type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block"},
            {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
            {"type": "field", "inboundTag": ["vless-ru"], "outboundTag": "direct"},
            {"type": "field", "inboundTag": ["vless-vpn-tcp", "vless-vpn-xhttp"], "domain": ["geosite:category-ru", "domain:.рф"], "outboundTag": "direct"},
            {"type": "field", "inboundTag": ["vless-vpn-tcp", "vless-vpn-xhttp"], "ip": ["geoip:ru"], "outboundTag": "direct"}
        ]
    },
    "inbounds": [
        {
            "listen": "0.0.0.0", "port": 443, "protocol": "vless", "tag": "vless-vpn-tcp",
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
            "listen": "0.0.0.0", "port": 8443, "protocol": "vless", "tag": "vless-vpn-xhttp",
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
        },
        {
            "listen": "0.0.0.0", "port": 9443, "protocol": "vless", "tag": "vless-ru",
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
touch /usr/local/etc/xray/.serverlink

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
    tag=$(jq -r --argjson idx "$i" '.inbounds[$idx].tag' "$CONFIG")

    if [ -z "$uuid" ]; then continue; fi

    if [ "$network" = "tcp" ]; then
        if [ "$tag" = "vless-ru" ]; then
            label="${email}|RU"
        else
            label="${email}|VPN|TCP"
        fi
        link="vless://$uuid@$ip:$port?security=reality&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=/&type=tcp&flow=$flow&encryption=none#$label"
    elif [ "$network" = "xhttp" ]; then
        path=$(jq -r --argjson idx "$i" '.inbounds[$idx].streamSettings.xhttpSettings.path' "$CONFIG")
        label="${email}|VPN|XHTTP"
        link="vless://$uuid@$ip:$port?security=reality&path=$(echo $path | sed 's|/|%2F|g')&mode=auto&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=%2F&type=xhttp&encryption=none#$label"
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

# === pullconfig (серверы + пользователи) ===
cat << 'EOF' > /usr/local/bin/pullconfig
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
REPO_FILE="/usr/local/etc/xray/.repo"
SUBMAP="/usr/local/etc/xray/.submap"
SERVERLINK="/usr/local/etc/xray/.serverlink"
SERVER_EMAIL="ru-server"

if [ ! -f "$REPO_FILE" ]; then
    echo "Репозиторий не настроен. Выполните editrepo."
    exit 1
fi

source "$REPO_FILE"

WORK_DIR="/tmp/xray-pullconfig-work"
trap "rm -rf $WORK_DIR" EXIT
rm -rf "$WORK_DIR"

echo "Загружаю репозиторий..."
git clone "https://x-access-token:${token}@github.com/${repo}.git" "$WORK_DIR" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "Ошибка: не удалось клонировать репозиторий."
    rm -rf "$WORK_DIR"
    exit 1
fi

# --- Фаза 1: поиск серверной подписки и построение outbound'ов ---
echo ""
echo "=== Поиск серверов ==="

server_links=()
server_filename=""

for f in "$WORK_DIR"/*.txt; do
    [ -f "$f" ] || continue
    filename=$(basename "$f")
    decoded=$(base64 -d "$f" 2>/dev/null)
    if [ -z "$decoded" ]; then continue; fi

    first_link=$(echo "$decoded" | head -1)
    email=$(echo "$first_link" | grep -oP '(?<=#)[^|#]+')

    if [ "$email" = "$SERVER_EMAIL" ]; then
        server_filename="$filename"
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            server_links+=("$line")
        done <<< "$decoded"
        break
    fi
done

if [ ${#server_links[@]} -eq 0 ]; then
    echo "Серверная подписка ($SERVER_EMAIL) не найдена в репозитории."
    echo "Outbound'ы не обновлены."
else
    echo "$server_filename" > "$SERVERLINK"
    echo "Найдено ссылок: ${#server_links[@]}"

    # Строим outbound'ы из VLESS-ссылок
    outbounds='[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"block"}'
    balancer_tags=()
    idx=0

    for link in "${server_links[@]}"; do
        idx=$((idx + 1))

        uuid=$(echo "$link" | grep -oP '(?<=://)[^@]+')
        address=$(echo "$link" | grep -oP '(?<=@)[^:]+')
        port=$(echo "$link" | grep -oP '(?<=:)[0-9]+(?=\?)')
        security=$(echo "$link" | grep -oP '(?<=security=)[^&]+')
        sni=$(echo "$link" | grep -oP '(?<=sni=)[^&]+')
        fp=$(echo "$link" | grep -oP '(?<=fp=)[^&]+')
        pbk=$(echo "$link" | grep -oP '(?<=pbk=)[^&]+')
        sid=$(echo "$link" | grep -oP '(?<=sid=)[^&]+')
        type=$(echo "$link" | grep -oP '(?<=type=)[^&]+')
        flow=$(echo "$link" | grep -oP '(?<=flow=)[^&]+')
        path=$(echo "$link" | grep -oP '(?<=path=)[^&]+' | sed 's|%2F|/|g')

        tag="proxy-${idx}"
        balancer_tags+=("\"$tag\"")

        if [ "$type" = "tcp" ]; then
            outbound=$(cat << OUTBOUND
,{
    "protocol": "vless", "tag": "$tag",
    "settings": {"vnext": [{"address": "$address", "port": $port, "users": [{"id": "$uuid", "flow": "$flow", "encryption": "none"}]}]},
    "streamSettings": {
        "network": "tcp", "security": "reality",
        "realitySettings": {"serverName": "$sni", "fingerprint": "$fp", "publicKey": "$pbk", "shortId": "$sid"}
    }
}
OUTBOUND
)
        elif [ "$type" = "xhttp" ]; then
            outbound=$(cat << OUTBOUND
,{
    "protocol": "vless", "tag": "$tag",
    "settings": {"vnext": [{"address": "$address", "port": $port, "users": [{"id": "$uuid", "flow": "", "encryption": "none"}]}]},
    "streamSettings": {
        "network": "xhttp", "xhttpSettings": {"path": "$path"},
        "security": "reality",
        "realitySettings": {"serverName": "$sni", "fingerprint": "$fp", "publicKey": "$pbk", "shortId": "$sid"}
    }
}
OUTBOUND
)
        else
            echo "  Неизвестный тип: $type, пропуск"
            continue
        fi

        outbounds="${outbounds}${outbound}"
        echo "  $tag: $address:$port ($type)"
    done

    outbounds="${outbounds}]"

    # Обновляем outbound'ы
    echo "$outbounds" | jq '.' > /tmp/xray_outbounds.json
    jq --slurpfile ob /tmp/xray_outbounds.json '.outbounds = $ob[0]' "$CONFIG" > /tmp/xray_new.json && mv /tmp/xray_new.json "$CONFIG"
    rm -f /tmp/xray_outbounds.json

    # Строим балансировщик
    selector=$(IFS=,; echo "${balancer_tags[*]}")
    jq --argjson sel "[$selector]" '
        .routing.balancers = [{"tag": "balancer", "selector": $sel, "strategy": {"type": "leastPing"}}] |
        .observatory = {"subjectSelector": $sel, "probeURL": "https://www.google.com/generate_204", "probeInterval": "1m"}
    ' "$CONFIG" > /tmp/xray_new.json && mv /tmp/xray_new.json "$CONFIG"

    # Добавляем правило балансировки (если ещё нет)
    has_balancer=$(jq '.routing.rules[] | select(.balancerTag == "balancer")' "$CONFIG")
    if [ -z "$has_balancer" ]; then
        jq '.routing.rules += [{"type": "field", "inboundTag": ["vless-vpn-tcp", "vless-vpn-xhttp"], "balancerTag": "balancer"}]' \
           "$CONFIG" > /tmp/xray_new.json && mv /tmp/xray_new.json "$CONFIG"
    fi

    echo "Outbound'ы обновлены."
fi

# --- Фаза 2: импорт пользователей ---
echo ""
echo "=== Импорт пользователей ==="

declare -A user_uuid
declare -A user_file
user_emails=()

for f in "$WORK_DIR"/*.txt; do
    [ -f "$f" ] || continue
    filename=$(basename "$f")

    # Пропускаем серверную подписку
    if [ "$filename" = "$server_filename" ]; then continue; fi

    first_link=$(base64 -d "$f" 2>/dev/null | head -1)
    if [ -z "$first_link" ]; then continue; fi
    email=$(echo "$first_link" | grep -oP '(?<=#)[^|#]+')
    uuid=$(echo "$first_link" | grep -oP '(?<=://)[^@]+')
    if [ -z "$email" ] || [ -z "$uuid" ]; then continue; fi

    # Не дублируем
    if [ -n "${user_uuid[$email]+x}" ]; then continue; fi

    user_uuid["$email"]="$uuid"
    user_file["$email"]="$filename"
    user_emails+=("$email")
done

if [[ ${#user_emails[@]} -eq 0 ]]; then
    echo "Нет пользователей для импорта."
else
    echo "Найденные пользователи:"
    new_count=0
    for i in "${!user_emails[@]}"; do
        email="${user_emails[$i]}"
        exists=$(jq --arg email "$email" '.inbounds[0].settings.clients[] | select(.email == $email)' "$CONFIG")
        if [ -n "$exists" ]; then
            echo "  $email (уже существует)"
        else
            echo "  $email"
        fi
    done
    echo ""
    echo "a. Все новые пользователи"
    read -p "Выберите (a / номер / n для пропуска): " choice

    selected_emails=()
    if [ "$choice" = "a" ] || [ "$choice" = "A" ]; then
        for email in "${user_emails[@]}"; do
            exists=$(jq --arg email "$email" '.inbounds[0].settings.clients[] | select(.email == $email)' "$CONFIG")
            if [ -z "$exists" ]; then
                selected_emails+=("$email")
            fi
        done
    elif [ "$choice" = "n" ] || [ "$choice" = "N" ]; then
        echo "Импорт пользователей пропущен."
        selected_emails=()
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#user_emails[@]} )); then
        selected_email="${user_emails[$((choice - 1))]}"
        exists=$(jq --arg email "$selected_email" '.inbounds[0].settings.clients[] | select(.email == $email)' "$CONFIG")
        if [ -n "$exists" ]; then
            echo "Пользователь $selected_email уже существует."
        else
            selected_emails+=("$selected_email")
        fi
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
        echo "  Импортирован: $email"
    done

    if [[ ${#selected_emails[@]} -gt 0 ]]; then
        echo "Импортировано: ${#selected_emails[@]}"
    fi
fi

rm -rf "$WORK_DIR"
systemctl restart xray

echo ""
echo "pullconfig завершён."
echo "Используйте pushsubs для обновления подписок пользователей."
EOF
chmod +x /usr/local/bin/pullconfig

# === pushsubs (с защитой .serverlink) ===
cat << 'EOF' > /usr/local/bin/pushsubs
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
REPO_FILE="/usr/local/etc/xray/.repo"
SUBMAP="/usr/local/etc/xray/.submap"
SERVERLINK="/usr/local/etc/xray/.serverlink"

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

# Читаем защищённый файл серверной подписки
protected_file=""
if [ -f "$SERVERLINK" ]; then
    protected_file=$(cat "$SERVERLINK" | tr -d '[:space:]')
fi

WORK_DIR="/tmp/xray-subs-work"
trap "rm -rf $WORK_DIR" EXIT
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

# Сканируем репозиторий — строим submap (пропуская серверную подписку)
> "$SUBMAP"
for f in "$WORK_DIR"/*.txt; do
    [ -f "$f" ] || continue
    filename=$(basename "$f")

    # Пропускаем серверную подписку
    if [ "$filename" = "$protected_file" ]; then continue; fi

    first_link=$(base64 -d "$f" 2>/dev/null | head -1)
    if [ -z "$first_link" ]; then continue; fi
    email=$(echo "$first_link" | grep -oP '(?<=#)[^|#]+')
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
            # Не допускаем совпадения с серверной подпиской
            if [ "$filename" = "$protected_file" ]; then continue; fi
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

# === newuser ===
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
    tag=$(jq -r --argjson idx "$i" '.inbounds[$idx].tag' "$CONFIG")
    sni=$(jq -r --argjson idx "$i" '.inbounds[$idx].streamSettings.realitySettings.serverNames[0]' "$CONFIG")
    flow=$(jq -r --argjson idx "$i" '.inbounds[$idx].settings.clients[0].flow // ""' "$CONFIG")

    if [ "$tag" = "vless-ru" ]; then
        label="RU-прокси"
    elif [ "$network" = "xhttp" ]; then
        label="VPN XHTTP"
    else
        label="VPN TCP"
    fi

    if [ "$network" = "tcp" ]; then
        link="vless://$uuid@$ip:$port?security=reality&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=/&type=tcp&flow=$flow&encryption=none#$ip"
    elif [ "$network" = "xhttp" ]; then
        path=$(jq -r --argjson idx "$i" '.inbounds[$idx].streamSettings.xhttpSettings.path' "$CONFIG")
        link="vless://$uuid@$ip:$port?security=reality&path=$(echo $path | sed 's|/|%2F|g')&mode=auto&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=%2F&type=xhttp&encryption=none#$ip"
    else
        continue
    fi

    echo ""
    echo "=== $label (порт $port) ==="
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
    tag=$(jq -r --argjson idx "$i" '.inbounds[$idx].tag' "$CONFIG")
    sni=$(jq -r --argjson idx "$i" '.inbounds[$idx].streamSettings.realitySettings.serverNames[0]' "$CONFIG")
    uuid=$(jq -r --argjson idx "$i" --arg email "$selected_email" '.inbounds[$idx].settings.clients[] | select(.email == $email) | .id' "$CONFIG")
    flow=$(jq -r --argjson idx "$i" --arg email "$selected_email" '.inbounds[$idx].settings.clients[] | select(.email == $email) | .flow // ""' "$CONFIG")

    if [ -z "$uuid" ]; then continue; fi

    if [ "$tag" = "vless-ru" ]; then
        label="${selected_email}|RU"
    elif [ "$network" = "xhttp" ]; then
        label="${selected_email}|VPN|XHTTP"
    else
        label="${selected_email}|VPN|TCP"
    fi

    if [ "$network" = "tcp" ]; then
        link="vless://$uuid@$ip:$port?security=reality&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=/&type=tcp&flow=$flow&encryption=none#$label"
        if [ "$tag" = "vless-ru" ]; then
            echo ""
            echo "=== RU-прокси (порт $port) ==="
        else
            echo ""
            echo "=== VPN TCP (порт $port) ==="
        fi
    elif [ "$network" = "xhttp" ]; then
        path=$(jq -r --argjson idx "$i" '.inbounds[$idx].streamSettings.xhttpSettings.path' "$CONFIG")
        link="vless://$uuid@$ip:$port?security=reality&path=$(echo $path | sed 's|/|%2F|g')&mode=auto&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=%2F&type=xhttp&encryption=none#$label"
        echo ""
        echo "=== VPN XHTTP (порт $port) ==="
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

# --- Мониторинг Xray + сброс соединений ---
cat >/usr/local/bin/check_xray.sh <<'EOF'
#!/bin/bash

# Проверяем активен ли Xray
if ! systemctl is-active --quiet xray; then
    systemctl restart xray
    exit 0
fi

# Сбрасываем соединения если их слишком много
CONNS=$(ss -tnp | grep xray | wc -l)
if [ "$CONNS" -gt 5000 ]; then
    systemctl restart xray
fi
EOF

chmod +x /usr/local/bin/check_xray.sh

cat >/etc/systemd/system/xray-monitor.service <<'EOF'
[Unit]
Description=Мониторинг Xray
After=network.target

[Service]
ExecStart=/usr/local/bin/check_xray.sh
Type=oneshot
StandardOutput=null
StandardError=journal
EOF

cat >/etc/systemd/system/xray-monitor.timer <<'EOF'
[Unit]
Description=Проверка состояния Xray каждые 30 секунд

[Timer]
OnBootSec=10s
OnUnitActiveSec=30s
Unit=xray-monitor.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now xray-monitor.timer

# --- Очистка диска раз в 7 дней ---
cat >/usr/local/bin/cleanup_disk.sh <<'EOF'
#!/bin/bash
apt clean
journalctl --vacuum-size=100M
EOF

chmod +x /usr/local/bin/cleanup_disk.sh

cat >/etc/systemd/system/cleanup-disk.service <<'EOF'
[Unit]
Description=Очистка apt-кэша и журналов

[Service]
ExecStart=/usr/local/bin/cleanup_disk.sh
Type=oneshot
EOF

cat >/etc/systemd/system/cleanup-disk.timer <<'EOF'
[Unit]
Description=Очистка диска раз в 7 дней

[Timer]
OnBootSec=1h
OnUnitActiveSec=7d

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now cleanup-disk.timer

# --- Ограничиваем размер journald ---
JOURNALD_CONF="/etc/systemd/journald.conf"
if ! grep -q "^SystemMaxUse=" "$JOURNALD_CONF"; then
    echo "SystemMaxUse=100M" >> "$JOURNALD_CONF"
    systemctl restart systemd-journald
    echo "Журнал ограничен до 100 МБ."
fi

systemctl restart xray

echo ""
echo "=============================="
echo "RU-сервер успешно установлен"
echo "VPN TCP на порту 443"
echo "VPN XHTTP на порту 8443"
echo "RU-прокси на порту 9443"
echo "=============================="
echo ""
echo "Следующие шаги:"
echo "1. editrepo    — настройте репозиторий"
echo "2. pullconfig  — загрузите серверы и пользователей"
echo "3. pushsubs    — обновите подписки"
echo ""
mainuser

cat << 'EOF' > $HOME/help

Команды для управления RU-сервером:

    mainuser      — ссылки основного пользователя
    newuser       — создать нового пользователя
    rmuser        — удалить пользователя
    sharelink     — ссылки и QR-коды для пользователя
    userlist      — список клиентов

    editrepo      — настройка репозитория и токена
    pullconfig    — загрузить серверы + импорт пользователей из git
    pushsubs      — обновить подписки пользователей
    sharesubs     — показать ссылки на подписки

Порты:
    443  — VPN TCP + Vision
    8443 — VPN XHTTP
    9443 — RU-прокси (весь трафик напрямую)

Маршрутизация (VPN):
    .ru / .рф     → напрямую
    остальное     → заграничные серверы (балансировщик)

Конфигурация: /usr/local/etc/xray/config.json
Перезагрузка:  systemctl restart xray

EOF
