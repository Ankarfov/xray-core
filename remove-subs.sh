#!/bin/bash

if [ "$(id -u)" -ne 0 ]; then
  echo "Скрипт нужно запускать от root"
  exit 1
fi

echo "Удаляю команды подписок..."

rm -f /usr/local/bin/editrepo
rm -f /usr/local/bin/pushsubs
rm -f /usr/local/bin/sharesubs
rm -f /usr/local/bin/_gen_sub
rm -f /usr/local/bin/importusers
rm -f /usr/local/etc/xray/.repo
rm -f /usr/local/etc/xray/.submap

# === newuser с QR ===
cat << 'EOF' > /usr/local/bin/newuser
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
KEYS="/usr/local/etc/xray/.keys"

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

pbk=$(awk -F': ' '/Password/ {print $2}' "$KEYS")
sid=$(awk -F': ' '/shortsid/ {print $2}' "$KEYS")
ip=$(curl -4 -s icanhazip.com)

INBOUND_COUNT=$(jq '.inbounds | length' "$CONFIG")
for (( i=0; i<INBOUND_COUNT; i++ )); do
    network=$(jq -r --argjson idx "$i" '.inbounds[$idx].streamSettings.network' "$CONFIG")
    port=$(jq -r --argjson idx "$i" '.inbounds[$idx].port' "$CONFIG")
    sni=$(jq -r --argjson idx "$i" '.inbounds[$idx].streamSettings.realitySettings.serverNames[0]' "$CONFIG")
    new_uuid=$(jq -r --argjson idx "$i" --arg email "$email" '.inbounds[$idx].settings.clients[] | select(.email == $email) | .id' "$CONFIG")
    flow=$(jq -r --argjson idx "$i" --arg email "$email" '.inbounds[$idx].settings.clients[] | select(.email == $email) | .flow // ""' "$CONFIG")

    if [ -z "$new_uuid" ]; then continue; fi

    if [ "$network" = "tcp" ]; then
        link="vless://$new_uuid@$ip:$port?security=reality&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=/&type=tcp&flow=$flow&encryption=none#$email"
        echo ""
        echo "=== TCP (порт $port) ==="
    elif [ "$network" = "xhttp" ]; then
        path=$(jq -r --argjson idx "$i" '.inbounds[$idx].streamSettings.xhttpSettings.path' "$CONFIG")
        link="vless://$new_uuid@$ip:$port?security=reality&path=$(echo $path | sed 's|/|%2F|g')&mode=auto&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=%2F&type=xhttp&encryption=none#$email"
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
chmod +x /usr/local/bin/newuser

# === rmuser без автопуша ===
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

systemctl restart xray
echo "Клиент $selected_email удалён."
EOF
chmod +x /usr/local/bin/rmuser

echo ""
echo "Откат завершён."
echo "Удалены: editrepo, pushsubs, sharesubs, importusers"
echo "Восстановлены: newuser (с QR), rmuser (без автопуша)"
