#!/bin/bash

set -e

echo "Installing dependencies..."
apt-get update -qq
apt-get install -y toilet figlet procps lsb-release whiptail > /dev/null

echo "Creating MOTD config..."
CONFIG_FILE="/etc/rw-motd.conf"
cat <<EOF > "$CONFIG_FILE"
SHOW_LOGO=true
SHOW_CPU=true
SHOW_MEM=true
SHOW_NET=true
SHOW_DOCKER=true
SHOW_FIREWALL=true
EOF

echo "Installing main MOTD script..."
mkdir -p /etc/update-motd.d

cat << 'EOF' > /etc/update-motd.d/00-remnawave
#!/bin/bash

source /etc/rw-motd.conf

COLOR_TITLE="\e[1;37m"
COLOR_LABEL="\e[0;36m"
COLOR_VALUE="\e[0;37m"
COLOR_GREEN="\e[0;32m"
COLOR_RED="\e[0;31m"
COLOR_YELLOW="\e[0;33m"
RESET="\e[0m"

[ "$SHOW_LOGO" = true ] && {
  clear
  echo -e "${COLOR_TITLE}"
  toilet -f standard "remnawave"
  echo -e "${RESET}"
}

LAST_LOGIN=$(last -i -w $(whoami) | grep -v "still logged in" | grep -v "0.0.0.0" | grep -v "127.0.0.1" | sed -n 2p)
LAST_DATE=$(echo "$LAST_LOGIN" | awk '{print $4, $5, $6, $7}')
LAST_IP=$(echo "$LAST_LOGIN" | awk '{print $3}')

echo -e "${COLOR_TITLE}=== Session Info ===${RESET}"
printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s ${COLOR_YELLOW}from $LAST_IP${RESET}\n" "Last login:" "$LAST_DATE"
printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "User:" "$(whoami)"
printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "Uptime:" "$(uptime -p | sed 's/up //')"

echo -e "\n${COLOR_TITLE}=== System Info ===${RESET}"
printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "Hostname:" "$(hostname)"
printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "OS:" "$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "Kernel:" "$(uname -r)"
EXTERNAL_IP="$(hostname -I | awk '{print $1}')"
printf "${COLOR_LABEL}%-22s${COLOR_YELLOW}%s${RESET}\n" "External IP:" "$EXTERNAL_IP"

if [ "$SHOW_CPU" = true ]; then
  echo -e "\n${COLOR_TITLE}=== CPU ===${RESET}"
  CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d ':' -f2 | sed 's/^ //')
  CPU_IDLE=$(vmstat 1 2 | tail -1 | awk '{print $15}')
  CPU_USAGE=$((100 - CPU_IDLE))
  LOAD_AVG=$(cat /proc/loadavg | awk '{print $1 " / " $2 " / " $3}')

  # CPU usage bar
  BAR_LENGTH=30
  FILLED=$((CPU_USAGE * BAR_LENGTH / 100))
  EMPTY=$((BAR_LENGTH - FILLED))
  if (( CPU_USAGE < 50 )); then BAR_COLOR=$COLOR_GREEN
  elif (( CPU_USAGE < 80 )); then BAR_COLOR=$COLOR_YELLOW
  else BAR_COLOR=$COLOR_RED; fi
  CPU_BAR="${BAR_COLOR}$(printf '■%.0s' $(seq 1 $FILLED))${RESET}$(printf '·%.0s' $(seq 1 $EMPTY))"

  printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "Model:" "$CPU_MODEL"
  printf "${COLOR_LABEL}%-22s%s %s%%${RESET}\n" "Usage:" "$CPU_BAR" "$CPU_USAGE"
  printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "Load average:" "$LOAD_AVG"
fi

if [ "$SHOW_MEM" = true ]; then
  echo -e "\n${COLOR_TITLE}=== Memory & Disk ===${RESET}"

  read MEM_USED MEM_TOTAL <<< $(free -m | awk '/^Mem:/ {print $3, $2}')
  MEM_PERC=$((100 * MEM_USED / MEM_TOTAL))
  FILLED=$((MEM_PERC * BAR_LENGTH / 100))
  EMPTY=$((BAR_LENGTH - FILLED))
  [ "$MEM_PERC" -lt 50 ] && BAR_COLOR=$COLOR_GREEN || [ "$MEM_PERC" -lt 80 ] && BAR_COLOR=$COLOR_YELLOW || BAR_COLOR=$COLOR_RED
  MEM_BAR="${BAR_COLOR}$(printf '■%.0s' $(seq 1 $FILLED))${RESET}$(printf '·%.0s' $(seq 1 $EMPTY))"
  printf "${COLOR_LABEL}%-22s%s %s%%${RESET}\n" "Memory Usage:" "$MEM_BAR" "$MEM_PERC"

  DISK_INFO=$(df -m / | awk 'NR==2{print $3, $2}')
  DISK_USED=${DISK_INFO%% *}
  DISK_TOTAL=${DISK_INFO##* }
  DISK_PERC=$((100 * DISK_USED / DISK_TOTAL))
  FILLED=$((DISK_PERC * BAR_LENGTH / 100))
  EMPTY=$((BAR_LENGTH - FILLED))
  [ "$DISK_PERC" -lt 50 ] && BAR_COLOR=$COLOR_GREEN || [ "$DISK_PERC" -lt 80 ] && BAR_COLOR=$COLOR_YELLOW || BAR_COLOR=$COLOR_RED
  DISK_BAR="${BAR_COLOR}$(printf '■%.0s' $(seq 1 $FILLED))${RESET}$(printf '·%.0s' $(seq 1 $EMPTY))"
  printf "${COLOR_LABEL}%-22s%s %s%%${RESET}\n" "Disk Usage (/):" "$DISK_BAR" "$DISK_PERC"
fi

if [ "$SHOW_NET" = true ]; then
  echo -e "\n${COLOR_TITLE}=== Network ===${RESET}"
  NET_IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
  if [ -n "$NET_IFACE" ]; then
    RX_BYTES=$(cat /sys/class/net/$NET_IFACE/statistics/rx_bytes)
    TX_BYTES=$(cat /sys/class/net/$NET_IFACE/statistics/tx_bytes)
    human_readable() {
      local BYTES=$1
      local UNITS=('B' 'KB' 'MB' 'GB' 'TB')
      local UNIT=0
      while (( BYTES > 1024 && UNIT < 4 )); do
        BYTES=$((BYTES / 1024))
        ((UNIT++))
      done
      echo "${BYTES} ${UNITS[$UNIT]}"
    }
    RX_HR=$(human_readable $RX_BYTES)
    TX_HR=$(human_readable $TX_BYTES)
    printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "Interface:" "$NET_IFACE"
    printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "Received:" "$RX_HR"
    printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "Transmitted:" "$TX_HR"
  else
    printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "Network:" "Interface not found"
  fi
fi

if [ "$SHOW_FIREWALL" = true ]; then
  echo -e "\n${COLOR_TITLE}=== Firewall ===${RESET}"
  if command -v ufw &>/dev/null; then
    STATUS_LINE=$(ufw status | head -1)
    if echo "$STATUS_LINE" | grep -iq "active"; then
      STATUS_COLORED="${COLOR_GREEN}${STATUS_LINE}${RESET}"
    else
      STATUS_COLORED="${COLOR_RED}${STATUS_LINE}${RESET}"
    fi
    printf "${COLOR_LABEL}%-22s%s\n" "UFW Status:" "$STATUS_COLORED"
  else
    printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "UFW:" "not installed"
  fi
fi

if [ "$SHOW_DOCKER" = true ]; then
  echo -e "\n${COLOR_TITLE}=== Docker ===${RESET}"
  if command -v docker &>/dev/null; then
    RUNNING_CONTAINERS=$(docker ps -q | wc -l)
    TOTAL_CONTAINERS=$(docker ps -a -q | wc -l)
    printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "Containers (running/total):" "$RUNNING_CONTAINERS / $TOTAL_CONTAINERS"
    if [ "$RUNNING_CONTAINERS" -gt 0 ]; then
      docker ps --format '{{.Names}}' | paste - - | while read line; do
        printf "  ${COLOR_VALUE}%-30s%-30s${RESET}\n" $line
      done
    fi
  else
    printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "Docker:" "not installed"
  fi
fi

echo
EOF

chmod +x /etc/update-motd.d/00-remnawave
rm -f /etc/motd
ln -sf /var/run/motd /etc/motd
ln -sf /etc/update-motd.d/00-remnawave /usr/local/bin/rw-motd

echo "Installing 'rw-motd-set' menu..."

cat << 'EOF' > /usr/local/bin/rw-motd-set
#!/bin/bash

CONFIG="/etc/rw-motd.conf"

CHOICES=$(whiptail --title "MOTD Settings" --checklist \
"Выберите, что отображать в MOTD:" 20 60 10 \
"SHOW_LOGO" "Показывать логотип" $(grep -q 'SHOW_LOGO=true' "$CONFIG" && echo ON || echo OFF) \
"SHOW_CPU" "Загрузка CPU" $(grep -q 'SHOW_CPU=true' "$CONFIG" && echo ON || echo OFF) \
"SHOW_MEM" "Память и диск" $(grep -q 'SHOW_MEM=true' "$CONFIG" && echo ON || echo OFF) \
"SHOW_NET" "Сетевой трафик" $(grep -q 'SHOW_NET=true' "$CONFIG" && echo ON || echo OFF) \
"SHOW_FIREWALL" "Статус UFW" $(grep -q 'SHOW_FIREWALL=true' "$CONFIG" && echo ON || echo OFF) \
"SHOW_DOCKER" "Контейнеры Docker" $(grep -q 'SHOW_DOCKER=true' "$CONFIG" && echo ON || echo OFF) \
3>&1 1>&2 2>&3)

for VAR in SHOW_LOGO SHOW_CPU SHOW_MEM SHOW_NET SHOW_FIREWALL SHOW_DOCKER; do
  if echo "$CHOICES" | grep -q "$VAR"; then
    sed -i "s/^$VAR=.*/$VAR=true/" "$CONFIG"
  else
    sed -i "s/^$VAR=.*/$VAR=false/" "$CONFIG"
  fi
done

echo "Настройки обновлены. Проверь командой: rw-motd"
EOF

chmod +x /usr/local/bin/rw-motd-set

echo "✅ Установка завершена. Используйте команду 'rw-motd' для ручного вывода или 'rw-motd-set' для настройки отображения."
