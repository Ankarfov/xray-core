#!/bin/bash

# Проверка root
if [ "$(id -u)" -ne 0 ]; then
  echo "Скрипт нужно запускать от root"
  exit 1
fi

CONFIG="/usr/local/etc/xray/config.json"
KEYS="/usr/local/etc/xray/.keys"

if [ ! -f "$CONFIG" ]; then
  echo "Ошибка: конфиг Xray не найден."
  exit 1
fi

# Устанавливаем git если нет
if ! command -v git &>/dev/null; then
    apt install git -y
fi

# Создаём файл маппинга если нет
touch /usr/local/etc/xray/.submap

echo "Устанавливаю команды для управления подписками..."

# editrepo
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

# _gen_sub — внутренняя функция генерации подписки
cat << 'GENEOF' > /usr/local/bin/_gen_sub
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
KEYS="/usr/local/etc/xray/.keys"

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

# pushsubs
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

git clone "https://x-access-token:${token}@github.com/${repo}.git" "$WORK_DIR" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "Ошибка: не удалось клонировать репозиторий."
    rm -rf "$WORK_DIR"
    exit 1
fi

cd "$WORK_DIR"
git config user.email "xray@server"
git config user.name "xray"

# Удаляем старые файлы подписок
find "$WORK_DIR" -maxdepth 1 -type f ! -name '.gitkeep' -delete

# Сохраняем старый маппинг
cp "$SUBMAP" /usr/local/etc/xray/.submap.old 2>/dev/null

emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG"))

> "$SUBMAP"

for email in "${emails[@]}"; do
    existing_file=$(grep "^${email}=" /usr/local/etc/xray/.submap.old 2>/dev/null | cut -d= -f2)
    if [ -n "$existing_file" ]; then
        filename="$existing_file"
    else
        filename="$(openssl rand -hex 10).txt"
    fi

    sub_content=$(/usr/local/bin/_gen_sub "$email")
    echo "$sub_content" > "${WORK_DIR}/${filename}"

    echo "${email}=${filename}" >> "$SUBMAP"
done

cp "$SUBMAP" /usr/local/etc/xray/.submap.old

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

# sharesubs
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

# Обновляем newuser — без QR, с автопушем
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

if [ -f /usr/local/etc/xray/.repo ]; then
    pushsubs
fi
EOF
chmod +x /usr/local/bin/newuser

# Обновляем rmuser — с автопушем
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

INBOUND_COUNT=$(jq '.inbounds | length' "$CONFIG")
for (( i=0; i<INBOUND_COUNT; i++ )); do
    jq --argjson idx "$i" --arg email "$selected_email" \
       '(.inbounds[$idx].settings.clients) |= map(select(.email != $email))' \
       "$CONFIG" > tmp && mv tmp "$CONFIG"
done

SUBMAP="/usr/local/etc/xray/.submap"
if [ -f "$SUBMAP" ]; then
    sed -i "/^${selected_email}=/d" "$SUBMAP"
    cp "$SUBMAP" /usr/local/etc/xray/.submap.old
fi

systemctl restart xray
echo "Клиент $selected_email удалён."

if [ -f /usr/local/etc/xray/.repo ]; then
    pushsubs
fi
EOF
chmod +x /usr/local/bin/rmuser

echo ""
echo "=============================="
echo "Команды установлены:"
echo "  editrepo  — настройка репозитория и токена"
echo "  pushsubs  — обновить подписки"
echo "  sharesubs — показать ссылки на подписки"
echo ""
echo "Также обновлены: newuser, rmuser"
echo ""
echo "Выполните editrepo для начала работы."
echo "=============================="
