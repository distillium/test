#!/bin/bash

set -e

INSTALL_DIR="/opt/rw-backup-restore"
BACKUP_DIR="$INSTALL_DIR/backup"
CONFIG_FILE="$INSTALL_DIR/config.env"
SCRIPT_NAME="backup-restore.sh" 
SCRIPT_PATH="$INSTALL_DIR/$SCRIPT_NAME"
RETAIN_BACKUPS_DAYS=7
SYMLINK_PATH="/usr/local/bin/rw-backup"

if [[ "$0" != "$SCRIPT_PATH" && ! -f "$SCRIPT_PATH" ]]; then
    echo "📥 Сохраняем скрипт в $SCRIPT_PATH..."
    rm -f "$SYMLINK_PATH"
    mkdir -p "$INSTALL_DIR" || { echo "Ошибка создания $INSTALL_DIR"; exit 1; }
    curl -fsSL https://raw.githubusercontent.com/distillium/remnawave-backup-restore/main/backup-restore.sh -o "$SCRIPT_PATH" || { echo "Не удалось сохранить скрипт."; exit 1; }
    chmod +x "$SCRIPT_PATH"
fi

COLOR="\033[1;37m"
RED="\033[0;31m"
GREEN="\033[0;32m"
RESET="\033[0m"

print_ascii_art() {
    if command -v toilet &> /dev/null; then
        echo -e "$COLOR"
        toilet -f standard -F metal "remnawave"
        echo -e "$RESET"
    else
        echo "remnawave"
        echo "---------------------------"
    fi
}

install_dependencies() {
    echo "Проверка и установка необходимых пакетов..."
    if [[ $EUID -ne 0 ]]; then
        echo "Этот скрипт требует прав root для установки зависимостей."
        echo "Пожалуйста, запустите его с sudo или от пользователя root."
        exit 1
    fi

    if command -v apt-get &> /dev/null; then
        apt-get update -qq > /dev/null 2>&1 || { echo "Ошибка при обновлении списка пакетов."; exit 1; }
        apt-get install -y toilet figlet procps lsb-release whiptail curl gzip > /dev/null 2>&1 || { echo "Ошибка при установке необходимых пакетов."; exit 1; }
        echo "Необходимые пакеты установлены или уже присутствуют."
    else
        echo "Не удалось найти apt-get. Пожалуйста, установите toilet, curl, docker.io и gzip вручную."
        command -v curl &> /dev/null || { echo "curl не найден. Установите его."; exit 1; }
        command -v docker &> /dev/null || { echo "docker не найден. Установите его."; exit 1; }
        command -v gzip &> /dev/null || { echo "gzip не найден. Установите его."; exit 1; }
        echo "Необходимые пакеты (кроме toilet) найдены."
    fi
}

load_or_create_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "Загрузка конфигурации из $CONFIG_FILE..."
source "$CONFIG_FILE"

if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" || -z "$DB_USER" ]]; then
    echo "⚠️  В файле конфигурации отсутствуют необходимые переменные."
    echo "▶️  Пожалуйста, введите недостающие данные:"

    [[ -z "$BOT_TOKEN" ]] && read -rp "Введите Telegram Bot Token: " BOT_TOKEN
    [[ -z "$CHAT_ID" ]] && read -rp "Введите Telegram Chat ID: " CHAT_ID
    [[ -z "$DB_USER" ]] && read -rp "Введите имя пользователя PostgreSQL (по умолчанию postgres): " DB_USER
    DB_USER=${DB_USER:-postgres}

    cat > "$CONFIG_FILE" <<EOF
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
DB_USER="$DB_USER"
EOF

    chmod 600 "$CONFIG_FILE" || { echo "Ошибка при установке прав доступа для $CONFIG_FILE."; exit 1; }
    echo "✅ Конфигурация дополнена и сохранена в $CONFIG_FILE"
fi
    else
        echo "=== Конфигурация не найдена, создаем новую ==="
        read -rp "Введите Telegram Bot Token: " BOT_TOKEN
        read -rp "Введите Telegram Chat ID: " CHAT_ID
        read -rp "Введите имя пользователя PostgreSQL (по умолчанию postgres): " DB_USER
        DB_USER=${DB_USER:-postgres}

        mkdir -p "$INSTALL_DIR" || { echo "Ошибка при создании каталога $INSTALL_DIR."; exit 1; }
        mkdir -p "$BACKUP_DIR" || { echo "Ошибка при создании каталога $BACKUP_DIR."; exit 1; }

        cat > "$CONFIG_FILE" <<EOF
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
DB_USER="$DB_USER"
EOF

        chmod 600 "$CONFIG_FILE" || { echo "Ошибка при установке прав доступа для $CONFIG_FILE."; exit 1; }
        echo "Конфигурация сохранена в $CONFIG_FILE"
    fi
}

escape_markdown_v2() {
    local text="$1"
    echo "$text" | sed \
        -e 's/\\/\\\\/g' \
        -e 's/_/\\_/g' \
        -e 's/\[/\\[/g' \
        -e 's/\]/\\]/g' \
        -e 's/(/\\(/g' \
        -e 's/)/\\)/g' \
        -e 's/~/\~/g' \
        -e 's/`/\\`/g' \
        -e 's/>/\\>/g' \
        -e 's/#/\\#/g' \
        -e 's/+/\\+/g' \
        -e 's/-/\\-/g' \
        -e 's/=/\\=/g' \
        -e 's/|/\\|/g' \
        -e 's/{/\\{/g' \
        -e 's/}/\\}/g' \
        -e 's/\./\\./g' \
        -e 's/!/\!/g'
}

send_telegram_message() {
    local message="$1"
    local parse_mode="${2:-MarkdownV2}"
    local escaped_message
    escaped_message=$(escape_markdown_v2 "$message")

    local http_code=$(curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d text="$escaped_message" \
        -d parse_mode="$parse_mode" \
        -w "%{http_code}" -o /dev/null 2>&1)

    if [[ "$http_code" -eq 200 ]]; then
        return 0
    else
        echo "Ошибка отправки сообщения в Telegram. HTTP код: $http_code"
        return 1
    fi
}

send_telegram_document() {
    local file_path="$1"
    local caption="$2"
    local parse_mode="MarkdownV2"
    local escaped_caption
    escaped_caption=$(escape_markdown_v2 "$caption")

    local api_response=$(curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" \
        -F chat_id="$CHAT_ID" \
        -F document=@"$file_path" \
        -F parse_mode="$parse_mode" \
        -F caption="$escaped_caption" \
        -w "%{http_code}" -o /dev/null 2>&1)

    local curl_status=$?

    if [ $curl_status -ne 0 ]; then
        echo "❌ Ошибка CURL при отправке документа в Telegram. Код выхода: $curl_status"
        return 1
    fi

    local http_code="${api_response: -3}"

    if [[ "$http_code" -eq 200 ]]; then
        return 0
    else
        echo "❌ Telegram API вернул ошибку HTTP. Код: $http_code"
        return 1
    fi
}


create_backup() {
    clear
    print_ascii_art
    echo "💾 Запись резервной копии..."

    mkdir -p "$BACKUP_DIR" || { echo "Ошибка при создании каталога бэкапов $BACKUP_DIR."; send_telegram_message "❌ Ошибка: Не удалось создать каталог бэкапов $BACKUP_DIR." "None"; exit 1; }

CONTAINER_ID="remnawave-db"
ENV_SOURCE="/opt/remnawave/.env-node"
TIMESTAMP=$(date +%Y-%m-%d"_"%H_%M_%S)
TMP_DIR="/tmp/remnawave_backup_$TIMESTAMP"
BACKUP_FILE_DB="dump_${TIMESTAMP}.sql.gz"
BACKUP_FILE_FINAL="remnawave_backup_${TIMESTAMP}.tar.gz"
FULL_PATH="$BACKUP_DIR/$BACKUP_FILE_FINAL"

  mkdir -p "$TMP_DIR"

  echo "[INFO] Creating PostgreSQL dump and compressing..."
  docker exec -t "$CONTAINER_ID" pg_dumpall -c -U "$DB_USER" | gzip -9 > "$TMP_DIR/$BACKUP_FILE_DB"

  if [ -f "$ENV_SOURCE" ]; then
    echo "[INFO] Found .env-node, adding to backup"
    cp "$ENV_SOURCE" "$TMP_DIR/.env-node"
  else
    echo "[INFO] .env-node not found — continuing without it"
  fi

  mkdir -p "$BACKUP_DIR"
  tar -czf "$BACKUP_DIR/$BACKUP_FILE_FINAL" -C "$TMP_DIR" .

  echo "[INFO] Contents of archive:"
  tar -tzf "$BACKUP_DIR/$BACKUP_FILE_FINAL"

  echo "[INFO] Cleaning up temporary files..."
  rm -rf "$TMP_DIR"

  echo "[INFO] Removing backups older than 7 days..."
  find "$BACKUP_DIR" -type f -name "remnawave_backup_*.tar.gz" -mtime +7 -exec rm -f {} \;

  echo "[INFO] Backup completed: $BACKUP_DIR/$BACKUP_FILE_FINAL"
  echo "Отправка бэкапа в Telegram..."
    local caption_text=$'💾#backup_success\n➖➖➖➖➖➖➖➖➖\n✅ *The backup has been created*\n📅Date: '"${DATE}"

    if [[ -f "$FULL_PATH" ]]; then
        if send_telegram_document "$FULL_PATH" "$caption_text"; then
            echo "✅ Успешно"
        else
            echo "❌ Ошибка при отправке бэкапа в Telegram. Подробности выше."
        fi
    else
        echo "❌ Ошибка: Файл бэкапа не найден после создания: $FULL_PATH"
        send_telegram_message "❌ Ошибка: Файл бэкапа не найден после создания: ${FILENAME}" "None"; exit 1
    fi
}

setup_auto_send() {
    while true; do
        clear
        print_ascii_art
        echo ""
        echo "=== Настройка автоматической отправки ==="
        echo "1) Включить"
        echo "2) Выключить"
        echo "0) Вернуться назад"
        read -rp "Выберите пункт: " choice
        case $choice in
            1)
                read -rp "Введите время отправки (например, 03:00 15:00 ): " times
                valid_times=()
                invalid_format=false
                IFS=' ' read -ra arr <<< "$times"
                for t in "${arr[@]}"; do
                    if [[ $t =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
                        hour=${BASH_REMATCH[1]}
                        min=${BASH_REMATCH[2]}
                        if (( 10#$hour >= 0 && 10#$hour <= 23 && 10#$min >= 0 && 10#$min <= 59 )); then
                            valid_times+=("$min $hour")
                        else
                            echo "Неверное значение времени: $t (часы 0-23, минуты 0-59)"
                            invalid_format=true
                            break
                        fi
                    else
                        echo "Неверный формат времени: $t (ожидается HH:MM)"
                        invalid_format=true
                        break
                    fi
                done

                if [ "$invalid_format" = true ] || [ ${#valid_times[@]} -eq 0 ]; then
                    echo "Автоматическая отправка не настроена из-за ошибок ввода времени."
                    continue
                fi

                echo "⏳ Настройка времени..."
                (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH") | crontab -

                for time_entry in "${valid_times[@]}"; do
                    (crontab -l 2>/dev/null; echo "$time_entry * * * $SCRIPT_PATH backup") | crontab -
                done

                sed -i '/^CRON_TIMES=/d' "$CONFIG_FILE"
                echo "CRON_TIMES=\"$times\"" >> "$CONFIG_FILE"
                echo "✅ Автоматическая отправка установлена на: $times"
                ;;
            2)
                echo "Отключение автоматической отправки..."
                crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -
                sed -i '/^CRON_TIMES=/d' "$CONFIG_FILE"
                echo "Автоматическая отправка отключена."
                ;;
            0) break ;;
            *) echo "Неверный ввод." ;;
        esac
        read -rp "Нажмите Enter для продолжения..."
    done
}

restore_backup() {
    clear
    print_ascii_art
  COMPOSE_DIR="/opt/remnawave"
  COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
  APP_CONTAINER="remnawave"
  ENV_TARGET_DIR="/opt/remnawave"

  echo "[INFO] Stopping and removing containers..."
  docker compose -f "$COMPOSE_FILE" down

  echo "[INFO] Removing volume with DB data..."
  docker volume rm remnawave-db-data || true

  echo "[INFO] Starting DB container..."
  docker compose -f "$COMPOSE_FILE" up -d "$CONTAINER_ID"

  echo "[INFO] Waiting for DB to initialize (10 sec)..."
  sleep 10

  DUMP_ARCHIVE=$(ls -1t "$BACKUP_DIR"/remnawave_backup_*.tar.gz 2>/dev/null | head -n 1)

  if [ -z "$DUMP_ARCHIVE" ]; then
    echo "[ERROR] No remnawave_backup_*.tar.gz archive found in $BACKUP_DIR"
    return 1
  fi

  echo "[WARNING] This will restore the DB from:"
  echo "          $DUMP_ARCHIVE"
  read -p "Are you sure? [yes/no]: " CONFIRM

  if [[ "$CONFIRM" != "yes" ]]; then
    echo "[INFO] Operation canceled."
    return 0
  fi

  echo "[INFO] Extracting archive..."
  tar -xzf "$DUMP_ARCHIVE" -C "$BACKUP_DIR"

  if [ -f "$BACKUP_DIR/.env-node" ]; then
    echo "[INFO] Found .env-node. Moving to $ENV_TARGET_DIR"
    mv -f "$BACKUP_DIR/.env-node" "$ENV_TARGET_DIR/.env-node"
  else
    echo "[INFO] .env-node not found in archive. Continuing..."
  fi

  DUMP_FILE=$(find "$BACKUP_DIR" -name "dump_*.sql.gz" | sort | tail -n 1)

  if [ ! -f "$DUMP_FILE" ]; then
    echo "[ERROR] No SQL dump file found."
    return 1
  fi

  echo "[INFO] Unzipping dump: $DUMP_FILE"
  gunzip "$DUMP_FILE"

  SQL_FILE="${DUMP_FILE%.gz}"

  if [ ! -f "$SQL_FILE" ]; then
    echo "[ERROR] Unzipped SQL file not found."
    return 1
  fi

  echo "[INFO] Restoring DB from: $SQL_FILE"
  cat "$SQL_FILE" | docker exec -i "$CONTAINER_ID" psql -U "$DB_USER"
  RESTORE_EXIT_CODE=$?

  if [ $RESTORE_EXIT_CODE -eq 0 ]; then
    echo "[INFO] DB restore successful. Removing: $SQL_FILE"
    rm -f "$SQL_FILE"
  else
    echo "[ERROR] Restore failed. Keeping: $SQL_FILE"
    return $RESTORE_EXIT_CODE
  fi

  echo "[INFO] Starting all services except DB..."
  docker compose -f "$COMPOSE_FILE" up -d $(docker compose -f "$COMPOSE_FILE" config --services | grep -v "$CONTAINER_ID")

  echo "[INFO] Resetting superuser in Remnawave..."
  docker exec -i "$APP_CONTAINER" node <<'EOF'
const { PrismaClient } = require('@prisma/client');
const prisma = new PrismaClient();
(async () => {
  try {
    const superadmin = await prisma.admin.findFirst();
    if (!superadmin) {
      console.error("❌ Superuser not found.");
      process.exit(1);
    }
    await prisma.admin.delete({ where: { uuid: superadmin.uuid } });
    console.log(`✅ Superuser '${superadmin.username}' deleted.`);
  } catch (err) {
    console.error("❌ Error deleting superuser:", err);
    process.exit(1);
  } finally {
    await prisma.$disconnect();
  }
})();
EOF

  echo "[INFO] Restore completed."
}

setup_symlink() {
    if [[ -L "$SYMLINK_PATH" ]]; then
        :
    elif [[ -e "$SYMLINK_PATH" ]]; then
        rm -rf "$SYMLINK_PATH"
    fi

    if [[ -d "/usr/local/bin" && -w "/usr/local/bin" ]]; then
        ln -sf "$SCRIPT_PATH" "$SYMLINK_PATH"
    fi
}

if [[ $EUID -ne 0 ]]; then
    echo "Этот скрипт требует прав root для установки, настройки cron и создания символической ссылки."
    echo "Пожалуйста, запустите его с sudo или от пользователя root."
    exit 1
fi

mkdir -p "$INSTALL_DIR" || { echo "Ошибка при создании каталога $INSTALL_DIR."; exit 1; }
mkdir -p "$BACKUP_DIR" || { echo "Ошибка при создании каталога $BACKUP_DIR."; exit 1; }


install_dependencies

load_or_create_config

if [[ "$1" == "backup" ]]; then
    create_backup
    exit 0
fi

update_script() {
    echo "🔄 Обновление скрипта..."
    BACKUP_PATH="${SCRIPT_PATH}.bak.$(date +%s)"
    echo "Создание резервной копии текущего скрипта в $BACKUP_PATH..."
    cp "$SCRIPT_PATH" "$BACKUP_PATH" || { echo "❌ Не удалось создать резервную копию."; return; }

    echo "Загрузка последней версии скрипта..."
    if [ -f "$SCRIPT_PATH" ]; then
    rm "$SCRIPT_PATH"
    fi
    
    if curl -fsSL https://raw.githubusercontent.com/distillium/remnawave-backup-restore/main/backup-restore.sh -o "$SCRIPT_PATH"; then
        chmod +x "$SCRIPT_PATH"
        echo "✅ Скрипт успешно обновлен."
        echo "♻️ Перезапуск скрипта..."
        exec "$SCRIPT_PATH" "$@"
    else
        echo "❌ Ошибка при загрузке новой версии. Восстанавливаем резервную копию..."
        mv "$BACKUP_PATH" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        echo "✅ Восстановлена предыдущая версия скрипта."
    fi
}

remove_script() {
    prompt_text=$(echo -e "Введите ${GREEN}yes${RESET}/${RED}no${RESET} для подтверждения: ")
    read -rp "$prompt_text" confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Удаление отменено."
        read -rp "Нажмите Enter, чтобы вернуться..."
        main_menu
    fi

    echo "Удаление cron-задач..."
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -

    echo "Удаление скрипта и данных..."
    rm -f "$SYMLINK_PATH"
    rm -rf "$INSTALL_DIR"

    echo "✅ Скрипт и связанные файлы удалены."
}

main_menu() {
    while true; do
        clear
        print_ascii_art
        echo "========= Главное меню ========="
        echo "1) 💾 Сделать бэкап вручную"
        echo "2) ⏰ Настройка автоматической отправки и уведомлений"
        echo "3) ♻️ Восстановление из бэкапа"
        echo "4) 🔄 Обновить скрипт"
        echo "5) 🗑️ Удалить скрипт и cron-задачи"
        echo "6) ❌ Выход"
        echo -e "-  🚀 Быстрый запуск: \e[1mrw-backup\e[0m доступен из любой точки системы"
        read -rp "Выберите пункт: " choice
        case $choice in
            1) create_backup ; read -rp "Нажмите Enter для продолжения..." ;;
            2) setup_auto_send ;;
            3) restore_backup ; read -rp "Нажмите Enter для продолжения..." ;;
            4) update_script ; read -rp "Нажмите Enter для продолжения..." ;;
            5) remove_script ; exit 0 ;;
            6) echo "Выход..."; exit 0 ;;
            *) echo "Неверный ввод." ; read -rp "Нажмите Enter для продолжения..." ;;
        esac
    done
}

setup_symlink
echo "Starting main menu..."
main_menu
