#!/bin/bash

set -e

# --- Статические определения ---
INSTALL_DIR="/opt/rw-backup-restore"
BACKUP_DIR="$INSTALL_DIR/backup"
CONFIG_FILE="$INSTALL_DIR/config.env"
SCRIPT_NAME="backup-restore.sh" # Имя самого файла скрипта
SCRIPT_PATH="$INSTALL_DIR/$SCRIPT_NAME" # Канонический путь к скрипту после установки
RETAIN_BACKUPS_DAYS=7
SYMLINK_PATH="/usr/local/bin/rw-backup"
REMNALABS_ROOT_DIR="/opt/remnawave"
ENV_NODE_FILE=".env-node"
SCRIPT_REPO_URL="https://raw.githubusercontent.com/distillium/test/main/backup-restore.sh" # УРЛ для обновлений

# --- Цвета и ASCII Art ---
COLOR="\e[1;37m"
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m" # НОВОЕ: для предупреждений
RESET="\e[0m"

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

# --- Функции ---

# УЛУЧШЕНО: Функция для создания/проверки символической ссылки
setup_symlink() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${YELLOW}⚠️  Для управления символической ссылкой $SYMLINK_PATH требуются права root.${RESET}"
        return 1
    fi

    # Проверка, существует ли ссылка и указывает ли она на правильный скрипт
    if [[ -L "$SYMLINK_PATH" && "$(readlink -f "$SYMLINK_PATH")" == "$SCRIPT_PATH" ]]; then
        # echo "ℹ️ Символическая ссылка $SYMLINK_PATH уже существует и корректна." # Можно раскомментировать для отладки
        return 0
    fi

    echo "🔗 Создание/Обновление символической ссылки $SYMLINK_PATH..."
    # Удаляем, если существует (может быть обычным файлом или неправильной ссылкой)
    rm -f "$SYMLINK_PATH"
    if [[ -d "$(dirname "$SYMLINK_PATH")" ]]; then
        ln -s "$SCRIPT_PATH" "$SYMLINK_PATH" && echo -e "${GREEN}✅ Символическая ссылка $SYMLINK_PATH успешно настроена.${RESET}" || {
            echo -e "${RED}❌ Ошибка: не удалось создать символическую ссылку $SYMLINK_PATH.${RESET}"
            return 1
        }
    else
        echo -e "${RED}❌ Ошибка: каталог $(dirname "$SYMLINK_PATH") не найден. Символическая ссылка не создана.${RESET}"
        return 1
    fi
    return 0
}

install_dependencies() {
    echo "Проверка и установка необходимых пакетов..."
    # Существующая проверка EUID внутри функции install_dependencies остается
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Этот скрипт требует прав root для установки зависимостей.${RESET}"
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
    echo -e "${YELLOW}⚠️  В файле конфигурации отсутствуют необходимые переменные.${RESET}"
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
    echo -e "${GREEN}✅ Конфигурация дополнена и сохранена в $CONFIG_FILE${RESET}"
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

    # Исправлено: получение HTTP кода из api_response
    local http_code="${api_response: -3}" 

    if [[ "$http_code" == "200" ]]; then # Сравнение как строка
        return 0
    else
        echo "❌ Telegram API вернул ошибку HTTP. Код: $http_code. Ответ: $api_response"
        return 1
    fi
}

create_backup() {
    echo "💾 Запись резервной копии..."

    TIMESTAMP=$(date +%Y-%m-%d"_"%H_%M_%S)
    BACKUP_FILE_DB="dump_${TIMESTAMP}.sql.gz"
    BACKUP_FILE_FINAL="remnawave_backup_${TIMESTAMP}.tar.gz"
    ENV_NODE_PATH="$REMNALABS_ROOT_DIR/$ENV_NODE_FILE"

    mkdir -p "$BACKUP_DIR" || { echo "Ошибка при создании каталога бэкапов $BACKUP_DIR."; send_telegram_message "❌ Ошибка: Не удалось создать каталог бэкапов $BACKUP_DIR." "None"; exit 1; }

    if ! docker inspect remnawave-db > /dev/null 2>&1 || ! docker container inspect -f '{{.State.Running}}' remnawave-db 2>/dev/null | grep -q "true"; then
        echo "Ошибка: Контейнер 'remnawave-db' не найден или не запущен."
        send_telegram_message "❌ Ошибка: Контейнер 'remnawave-db' не найден или не запущен. Не удалось создать бэкап." "None"; exit 1
    fi

    echo "[INFO] Создание PostgreSQL дампа и сжатие..."
    if ! docker exec -t "remnawave-db" pg_dumpall -c -U "$DB_USER" | gzip -9 > "$BACKUP_DIR/$BACKUP_FILE_DB"; then
        STATUS=$?
        echo "❌ Ошибка при создании дампа PostgreSQL. Код выхода: $STATUS"
        send_telegram_message "❌ Ошибка при создании дампа PostgreSQL. Код выхода: ${STATUS}" "None"; exit $STATUS
    fi

    echo "[INFO] Архивирование бэкапа..."
    if [ -f "$ENV_NODE_PATH" ]; then
        echo "[INFO] Обнаружен файл $ENV_NODE_FILE. Добавляем его в архив."
        cp "$ENV_NODE_PATH" "$BACKUP_DIR/" || { echo "❌ Ошибка при копировании $ENV_NODE_FILE."; send_telegram_message "❌ Ошибка: Не удалось скопировать ${ENV_NODE_FILE} для бэкапа." "None"; exit 1; }
        if ! tar -czf "$BACKUP_DIR/$BACKUP_FILE_FINAL" -C "$BACKUP_DIR" "$BACKUP_FILE_DB" "$ENV_NODE_FILE"; then
            STATUS=$?
            echo "❌ Ошибка при архивировании бэкапа (включая $ENV_NODE_FILE). Код выхода: $STATUS"
            send_telegram_message "❌ Ошибка при архивировании бэкапа (включая ${ENV_NODE_FILE}). Код выхода: ${STATUS}" "None"; exit $STATUS
        fi
        rm -f "$BACKUP_DIR/$ENV_NODE_FILE"
    else
        echo "[INFO] Файл $ENV_NODE_FILE не найден по пути $ENV_NODE_PATH. Продолжаем без него."
        if ! tar -czf "$BACKUP_DIR/$BACKUP_FILE_FINAL" -C "$BACKUP_DIR" "$BACKUP_FILE_DB"; then
            STATUS=$?
            echo "❌ Ошибка при архивировании бэкапа. Код выхода: $STATUS"
            send_telegram_message "❌ Ошибка при архивировании бэкапа. Код выхода: ${STATUS}" "None"; exit $STATUS
        fi
    fi

    echo "[INFO] Очистка промежуточного дампа..."
    rm -f "$BACKUP_DIR/$BACKUP_FILE_DB"

    echo -e "${GREEN}✅ Бэкап успешно создан и находится по пути:\n $BACKUP_DIR/$BACKUP_FILE_FINAL${RESET}"

    echo -e "Применение политики хранения бэкапов\n(оставляем за последние $RETAIN_BACKUPS_DAYS дней)..."
    find "$BACKUP_DIR" -maxdepth 1 -name "remnawave_backup_*.tar.gz" -mtime +$RETAIN_BACKUPS_DAYS -delete

    echo "Отправка бэкапа в Telegram..."
    local DATE=$(date +'%Y-%m-%d %H:%M:%S')
    local caption_text=$'💾#backup_success\n➖➖➖➖➖➖➖➖➖\n✅ *The backup has been created*\n📅Date: '"${DATE}"

    if [[ -f "$BACKUP_DIR/$BACKUP_FILE_FINAL" ]]; then
        if send_telegram_document "$BACKUP_DIR/$BACKUP_FILE_FINAL" "$caption_text"; then
            echo -e "${GREEN}✅ Успешно отправлен в Telegram.${RESET}"
        else
            echo -e "${RED}❌ Ошибка при отправке бэкапа в Telegram. Подробности выше.${RESET}"
        fi
    else
        echo -e "${RED}❌ Ошибка: Файл бэкапа не найден после создания: $BACKUP_DIR/$BACKUP_FILE_FINAL${RESET}"
        send_telegram_message "❌ Ошибка: Файл бэкапа не найден после создания: ${BACKUP_FILE_FINAL}" "None"; exit 1
    fi
}

setup_auto_send() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Для настройки cron требуются права root. Пожалуйста, запустите с sudo.${RESET}"
        read -rp "Нажмите Enter для продолжения..."
        return
    fi
    while true; do
        echo ""
        echo "=== Настройка автоматической отправки ==="
        echo "1) Включить"
        echo "2) Выключить"
        echo "3) Вернуться назад"
        read -rp "Выберите пункт: " choice
        case $choice in
            1)
                read -rp "Введите время отправки (например, 03:00 или несколько через пробел 03:00 15:00): " times
                valid_times_cron=()
                user_friendly_times=""
                invalid_format=false
                IFS=' ' read -ra arr <<< "$times"
                for t in "${arr[@]}"; do
                    if [[ $t =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
                        hour=${BASH_REMATCH[1]}
                        min=${BASH_REMATCH[2]}
                        # Приводим к числу для корректного сравнения
                        hour_val=$((10#$hour))
                        min_val=$((10#$min))
                        if (( hour_val >= 0 && hour_val <= 23 && min_val >= 0 && min_val <= 59 )); then
                            valid_times_cron+=("$min_val $hour_val") # Формат для cron: минуты часы
                            user_friendly_times+="$t "
                        else
                            echo -e "${RED}Неверное значение времени: $t (часы 0-23, минуты 0-59)${RESET}"
                            invalid_format=true
                            break
                        fi
                    else
                        echo -e "${RED}Неверный формат времени: $t (ожидается HH:MM)${RESET}"
                        invalid_format=true
                        break
                    fi
                done

                if [ "$invalid_format" = true ] || [ ${#valid_times_cron[@]} -eq 0 ]; then
                    echo -e "${RED}Автоматическая отправка не настроена из-за ошибок ввода времени.${RESET}"
                    continue
                fi

                echo "⏳ Настройка времени..."
                (crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH backup") | crontab - # Используем -F для точного совпадения строки

                for time_entry in "${valid_times_cron[@]}"; do
                    (crontab -l 2>/dev/null; echo "$time_entry * * * $SCRIPT_PATH backup") | crontab -
                done

                # Удаляем старую запись CRON_TIMES и добавляем новую
                if grep -q "^CRON_TIMES=" "$CONFIG_FILE"; then
                    sed -i '/^CRON_TIMES=/d' "$CONFIG_FILE"
                fi
                echo "CRON_TIMES=\"${user_friendly_times% }\"" >> "$CONFIG_FILE" # Сохраняем удобный для пользователя формат
                echo -e "${GREEN}✅ Автоматическая отправка установлена на: ${user_friendly_times% }${RESET}"
                ;;
            2)
                echo "Отключение автоматической отправки..."
                (crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH backup") | crontab -
                if grep -q "^CRON_TIMES=" "$CONFIG_FILE"; then
                    sed -i '/^CRON_TIMES=/d' "$CONFIG_FILE"
                fi
                echo "Автоматическая отправка отключена."
                ;;
            3) break ;;
            *) echo "Неверный ввод." ;;
        esac
        read -rp "Нажмите Enter для продолжения..."
    done
}

restore_backup() {
    echo -e ""
    echo -e "=== Восстановление из бэкапа ==="
    echo -e "${RED}!!! ВНИМАНИЕ: Восстановление полностью перезапишет базу данных Remnawave и удалит ее том !!!${RESET}"
    echo -e "Поместите файл бэкапа (*.tar.gz) в папку: $BACKUP_DIR"
    echo -e "Убедитесь, что выбрали правильный файл бэкапа"
    echo -e ""

    ENV_NODE_RESTORE_PATH="$REMNALABS_ROOT_DIR/$ENV_NODE_FILE"

    echo "Доступные файлы бэкапов в $BACKUP_DIR:"
    # Улучшено: проверка на наличие файлов перед использованием find
    if ! compgen -G "$BACKUP_DIR/remnawave_backup_*.tar.gz" > /dev/null; then
        echo "Не найдено файлов бэкапов в $BACKUP_DIR."
        read -rp "Нажмите Enter для продолжения..."
        return
    fi

    # Используем find для сортировки по времени изменения (новые вверху)
    # и readarray для безопасного чтения в массив
    readarray -t SORTED_BACKUP_FILES < <(find "$BACKUP_DIR" -maxdepth 1 -name "remnawave_backup_*.tar.gz" -printf "%T@ %p\n" | sort -nr | cut -d' ' -f2-)

    if [ ${#SORTED_BACKUP_FILES[@]} -eq 0 ]; then
        echo "Не найдено файлов бэкапов в $BACKUP_DIR."
        read -rp "Нажмите Enter для продолжения..."
        return
    fi

    echo "Выберите файл для восстановления:"
    select SELECTED_BACKUP in "${SORTED_BACKUP_FILES[@]}"; do
        if [[ -n "$SELECTED_BACKUP" ]]; then
            echo "Выбран файл: $SELECTED_BACKUP"
            break
        else
            echo "Неверный выбор."
        fi
    done

    echo -e $'Вы уверены, что хотите восстановить базу данных? Это удалит текущие данные.\nВведите '"${GREEN}Y${RESET}"$' для подтверждения: '
    read -r confirm_restore

    if [[ "${confirm_restore,,}" != "y" ]]; then
        echo "Восстановление отменено."
        return
    fi

    echo "Начало процесса полного сброса и восстановления базы данных..."

    echo "Остановка Remnawave и удаление тома базы данных..."
    if ! cd "$REMNALABS_ROOT_DIR"; then # Улучшено: используем переменную
        echo "Ошибка: Не удалось перейти в каталог $REMNALABS_ROOT_DIR. Убедитесь, что файл docker-compose.yml находится там."
        return
    fi

    docker compose down || {
        echo "Предупреждение: Не удалось корректно остановить сервисы Docker Compose."
    }

    if docker volume ls -q | grep -q "remnawave-db-data"; then # Имя тома может отличаться, лучше сделать настраиваемым
        if ! docker volume rm remnawave-db-data; then
            echo "Критическая ошибка: Не удалось удалить том 'remnawave-db-data'. Восстановление невозможно."
            return
        fi
        echo "Том 'remnawave-db-data' успешно удален."
    else
        echo "Том 'remnawave-db-data' не найден, пропуск удаления."
    fi

    echo "Запуск контейнера 'remnawave-db'..."
    if ! docker compose up -d remnawave-db; then
        echo "Критическая ошибка: Не удалось запустить контейнер 'remnawave-db'. Восстановление невозможно."
        return
    fi
    echo "Ожидание запуска контейнера 'remnawave-db'..."
    sleep 10

    if ! docker container inspect -f '{{.State.Running}}' remnawave-db 2>/dev/null | grep -q "true"; then
        echo "Критическая ошибка: Контейнер 'remnawave-db' все еще не запущен после попытки старта. Восстановление невозможно."
        return
    fi

    echo ""
    echo -e "${GREEN}!!! ВНИМАНИЕ !!!${RESET}"
    echo "Пожалуйста, убедитесь, что имя пользователя PostgreSQL (DB_USER), пароль и база данных"
    echo "точно прописаны в файле .env (или в конфигурации Docker Compose), так как это было на предыдущем сервере."
    echo "Это крайне важно для успешного восстановления."
    echo -e $'Вы проверили и подтверждаете, что настройки БД верны?\nВведите '"${GREEN}Y${RESET}"$' для продолжения или '"${RED}N${RESET}"$' для отмены: '
    read -r confirm_db_settings

    if [[ "${confirm_db_settings,,}" != "y" ]]; then
        echo "Восстановление отменено пользователем."
        return
    fi

    if ! docker exec -i remnawave-db psql -U "$DB_USER" -d postgres -c "SELECT 1;" > /dev/null 2>&1; then
        echo "Ошибка: Не удалось подключиться к базе данных 'postgres' в контейнере 'remnawave-db' с пользователем '$DB_USER'."
        echo "Проверьте имя пользователя БД в $CONFIG_FILE и доступность контейнера."
        return
    fi

    echo "[ИНФО] Распаковка архива..."
    local temp_restore_dir="$BACKUP_DIR/restore_temp_$$" # УЛУЧШЕНО: временная папка для распаковки
    mkdir -p "$temp_restore_dir"
    if ! tar -xzf "$SELECTED_BACKUP" -C "$temp_restore_dir"; then
        STATUS=$?
        echo "❌ Ошибка при распаковке архива. Код выхода: $STATUS"
        send_telegram_message "❌ Ошибка при распаковке архива: ${SELECTED_BACKUP##*/}. Код выхода: ${STATUS}" "None"
        rm -rf "$temp_restore_dir" # Очистка
        exit $STATUS
    fi

    if [ -f "$temp_restore_dir/$ENV_NODE_FILE" ]; then
        echo "[ИНФО] Обнаружен файл $ENV_NODE_FILE в архиве. Перемещаем его в $ENV_NODE_RESTORE_PATH."
        mv "$temp_restore_dir/$ENV_NODE_FILE" "$ENV_NODE_RESTORE_PATH" || { 
            echo "❌ Ошибка при перемещении $ENV_NODE_FILE."
            send_telegram_message "❌ Ошибка: Не удалось переместить ${ENV_NODE_FILE} при восстановлении." "None"
            rm -rf "$temp_restore_dir" # Очистка
            exit 1; 
        }
    else
        echo "[ИНФО] Файл $ENV_NODE_FILE не найден в архиве. Продолжаем без него."
    fi

    DUMP_FILE_GZ=$(find "$temp_restore_dir" -name "dump_*.sql.gz" | sort | tail -n 1)

    if [ ! -f "$DUMP_FILE_GZ" ]; then
        echo "[ОШИБКА] Не найден файл дампа (*.sql.gz) после распаковки."
        send_telegram_message "❌ Ошибка: Не найден файл дампа после распаковки из ${SELECTED_BACKUP##*/}" "None"
        rm -rf "$temp_restore_dir" # Очистка
        exit 1
    fi

    echo "[ИНФО] Распаковка SQL-дампа: $DUMP_FILE_GZ"
    if ! gunzip "$DUMP_FILE_GZ"; then
        STATUS=$?
        echo "❌ Ошибка при распаковке SQL-дампа. Код выхода: $STATUS"
        send_telegram_message "❌ Ошибка при распаковке SQL-дампа: ${DUMP_FILE_GZ##*/}. Код выхода: ${STATUS}" "None"
        rm -rf "$temp_restore_dir" # Очистка
        exit $STATUS
    fi

    SQL_FILE="${DUMP_FILE_GZ%.gz}" # Путь к распакованному .sql файлу

    if [ ! -f "$SQL_FILE" ]; then
        echo "[ОШИБКА] Распакованный SQL-файл не найден."
        send_telegram_message "❌ Ошибка: Распакованный SQL-файл не найден." "None"
        rm -rf "$temp_restore_dir" # Очистка
        exit 1
    fi

    echo "[ИНФО] Восстановление базы данных из файла: $SQL_FILE"
    if cat "$SQL_FILE" | docker exec -i "remnawave-db" psql -U "$DB_USER"; then # Добавлено -d postgres по умолчанию, если в дампе нет CREATE DATABASE
        echo -e "${GREEN}✅ Импорт базы данных успешно завершен.${RESET}"
        local restore_success_prefix="✅ Восстановление Remnawave DB успешно завершено из файла: "
        local restored_filename="${SELECTED_BACKUP##*/}"
        send_telegram_message "${restore_success_prefix}${restored_filename}"
    else
        STATUS=$?
        echo -e "${RED}❌ Ошибка при импорте базы данных. Код выхода: $STATUS${RESET}"
        local restore_error_prefix="❌ Ошибка при импорте Remnawave DB из файла: "
        local restored_filename_error="${SELECTED_BACKUP##*/}"
        local error_suffix=". Код выхода: ${STATUS}"
        send_telegram_message "${restore_error_prefix}${restored_filename_error}${error_suffix}"
        echo "[ОШИБКА] Восстановление завершилось с ошибкой. SQL-файл не удалён: $SQL_FILE (в $temp_restore_dir)"
        # Не удаляем temp_restore_dir для анализа ошибки
        return
    fi

    echo "[ИНФО] Очистка временных файлов восстановления..."
    rm -rf "$temp_restore_dir"

    echo "Перезапуск всех сервисов Remnawave и вывод логов..."
    if ! docker compose down; then
        echo "Предупреждение: Не удалось остановить сервисы Docker Compose перед полным запуском."
    fi

    # Запускаем все сервисы, кроме remnawave-db, затем его (если он не был в списке изначально)
    # Или просто docker compose up -d
    if ! docker compose up -d; then # Упрощено до docker compose up -d
        echo "Критическая ошибка: Не удалось запустить все сервисы Docker Compose после восстановления."
        return
    else
        echo -e "${GREEN}✅ Все сервисы Remnawave запущены.${RESET}"
    fi

    echo "[ИНФО] Сброс суперпользователя Remnawave..."
    if ! docker exec -i remnawave node <<'EOF'
const { PrismaClient } = require('@prisma/client');
const prisma = new PrismaClient();

(async () => {
  try {
    const superadmin = await prisma.admin.findFirst();
    if (!superadmin) {
      console.error("❌ Суперпользователь не найден.");
      // Не выходим с ошибкой, если суперпользователя просто нет
      process.exit(0); 
    }

    await prisma.admin.delete({
      where: { uuid: superadmin.uuid },
    });

    console.log(`✅ Суперпользователь '${superadmin.username}' успешно удалён.`);
  } catch (err) {
    console.error("❌ Ошибка при удалении суперпользователя:", err);
    process.exit(1);
  } finally {
    await prisma.$disconnect();
  }
})();
EOF
    then
        echo -e "${RED}❌ Ошибка при сбросе суперпользователя.${RESET}"
        send_telegram_message "❌ Ошибка при сбросе суперпользователя Remnawave." "None"
    else
        echo -e "${GREEN}✅ Суперпользователь успешно сброшен (или не найден).${RESET}"
        send_telegram_message "✅ Суперпользователь Remnawave успешно сброшен (или не найден)." "None"
    fi

    echo -e "\n--- Логи Remnawave ---"
    docker compose logs -f -t --since 5m # Показываем логи за последние 5 минут и новые
    echo -e "--- Конец логов ---"
}

# УЛУЧШЕНО: функция обновления скрипта
update_script() {
    echo "🔄 Обновление скрипта..."
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}⛔ Для обновления скрипта требуются права root. Пожалуйста, запустите с sudo.${RESET}"
        read -rp "Нажмите Enter для продолжения..."
        return
    fi

    TEMP_SCRIPT_PATH="${INSTALL_DIR}/backup-restore.sh.tmp"
    echo "Загрузка последней версии скрипта с GitHub ($SCRIPT_REPO_URL)..."

    if curl -fsSL "$SCRIPT_REPO_URL" -o "$TEMP_SCRIPT_PATH"; then
        # Проверка, что загруженный файл не пустой и является bash-скриптом
        if [[ -s "$TEMP_SCRIPT_PATH" ]] && head -n 1 "$TEMP_SCRIPT_PATH" | grep -q -e '^#!.*bash'; then
            # Проверка, отличается ли новый скрипт от текущего
            if cmp -s "$SCRIPT_PATH" "$TEMP_SCRIPT_PATH"; then
                echo -e "${GREEN}ℹ️ У вас уже установлена последняя версия скрипта.${RESET}"
                rm -f "$TEMP_SCRIPT_PATH"
                read -rp "Нажмите Enter для продолжения..."
                return
            fi

            echo "🔬 Проверка загруженного скрипта: OK."
            BACKUP_PATH_SCRIPT="${SCRIPT_PATH}.bak.$(date +%s)"
            echo "Создание резервной копии текущего скрипта в $BACKUP_PATH_SCRIPT..."
            cp "$SCRIPT_PATH" "$BACKUP_PATH_SCRIPT" || {
                echo -e "${RED}❌ Не удалось создать резервную копию $SCRIPT_PATH. Обновление отменено.${RESET}"
                rm -f "$TEMP_SCRIPT_PATH"
                read -rp "Нажмите Enter для продолжения..."
                return
            }

            mv "$TEMP_SCRIPT_PATH" "$SCRIPT_PATH" || {
                echo -e "${RED}❌ Ошибка перемещения временного файла в $SCRIPT_PATH.${RESET}"
                echo "Восстановление из резервной копии $BACKUP_PATH_SCRIPT..."
                mv "$BACKUP_PATH_SCRIPT" "$SCRIPT_PATH" # mv, а не cp
                rm -f "$TEMP_SCRIPT_PATH"
                read -rp "Нажмите Enter для продолжения..."
                return
            }
            chmod +x "$SCRIPT_PATH"
            echo -e "${GREEN}✅ Скрипт успешно обновлен до последней версии.${RESET}"
            echo "🔁 Для применения изменений скрипт будет перезапущен..."
            read -rp "Нажмите Enter для перезапуска."
            exec "$SCRIPT_PATH" "$@" # Перезапуск скрипта с текущими аргументами
            exit 0 # Не должно быть достигнуто
        else
            echo -e "${RED}❌ Ошибка: Загруженный файл пуст или не является исполняемым bash-скриптом.${RESET}"
            rm -f "$TEMP_SCRIPT_PATH"
        fi
    else
        echo -e "${RED}❌ Ошибка при загрузке новой версии с GitHub.${RESET}"
        rm -f "$TEMP_SCRIPT_PATH" # Удалить временный файл, если он был создан частично
    fi
    read -rp "Нажмите Enter для продолжения..."
}

# УЛУЧШЕНО: функция удаления скрипта
remove_script() {
    echo -e "${RED}❌ ВНИМАНИЕ! Это действие полностью удалит скрипт, его конфигурацию, все локальные резервные копии и cron-задачи.${RESET}"
    echo "Будут удалены:"
    echo "  - Скрипт: $SCRIPT_PATH"
    echo "  - Каталог установки: $INSTALL_DIR (включая конфигурацию $CONFIG_FILE и все бэкапы в $BACKUP_DIR)"
    echo "  - Символическая ссылка: $SYMLINK_PATH (если существует)"
    echo "  - Задачи cron, связанные с $SCRIPT_PATH backup"
    echo ""
    read -rp "Вы уверены, что хотите продолжить? Введите 'да' для подтверждения: " confirm
    if [[ "${confirm,,}" != "да" && "${confirm,,}" != "yes" ]]; then
        echo "Удаление отменено."
        read -rp "Нажмите Enter для продолжения..."
        return
    fi

    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}⛔ Для полного удаления требуются права root. Пожалуйста, запустите с sudo.${RESET}"
        read -rp "Нажмите Enter для продолжения..."
        return
    fi

    echo "🗑️ Удаление cron-задач..."
    if crontab -l 2>/dev/null | grep -qF "$SCRIPT_PATH backup"; then # -F для точного совпадения строки
        (crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH backup") | crontab -
        echo -e "${GREEN}✅ Задачи cron для автоматического бэкапа удалены.${RESET}"
    else
        echo "ℹ️ Задачи cron для автоматического бэкапа не найдены."
    fi

    echo "🗑️ Удаление символической ссылки..."
    if [[ -L "$SYMLINK_PATH" ]]; then
        rm -f "$SYMLINK_PATH" && echo -e "${GREEN}✅ Символическая ссылка $SYMLINK_PATH удалена.${RESET}" || echo -e "${YELLOW}⚠️  Не удалось удалить символическую ссылку $SYMLINK_PATH.${RESET}"
    elif [[ -e "$SYMLINK_PATH" ]]; then
        echo -e "${YELLOW}⚠️  $SYMLINK_PATH существует, но не является символической ссылкой. Рекомендуется проверить вручную.${RESET}"
    else
        echo "ℹ️ Символическая ссылка $SYMLINK_PATH не найдена."
    fi

    echo "🗑️ Удаление каталога установки и всех данных..."
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR" && echo -e "${GREEN}✅ Каталог установки $INSTALL_DIR (включая скрипт, конфигурацию, бэкапы) удален.${RESET}" || echo -e "${RED}❌ Ошибка при удалении каталога $INSTALL_DIR.${RESET}"
    else
        echo "ℹ️ Каталог установки $INSTALL_DIR не найден."
    fi

    echo -e "${GREEN}✅ Процесс удаления завершен.${RESET}"
    echo "👋 Скрипт удален. Выход."
    # Важно: после удаления скрипта и его данных, нужно выйти, т.к. сам файл скрипта удален
    exit 0
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
        # УЛУЧШЕНО: Проверка существования симлинка перед отображением подсказки
        if [[ -L "$SYMLINK_PATH" && "$(readlink -f "$SYMLINK_PATH")" == "$SCRIPT_PATH" ]]; then
            echo -e "-  🚀 Быстрый запуск: ${GREEN}rw-backup${RESET} доступен из любой точки системы"
        else
            echo -e "-  🚀 Быстрый запуск: ${YELLOW}rw-backup (символическая ссылка не настроена или некорректна)${RESET}"
        fi
        read -rp "Выберите пункт: " choice
        case $choice in
            1) create_backup ; read -rp "Нажмите Enter для продолжения..." ;;
            2) setup_auto_send ;; # Внутри есть проверка root
            3) restore_backup ; read -rp "Нажмите Enter для продолжения..." ;;
            4) update_script ;; # Внутри есть проверка root и exec
            5) remove_script ;; # Внутри есть проверка root и exit
            6) echo "Выход..."; exit 0 ;;
            *) echo "Неверный ввод." ; read -rp "Нажмите Enter для продолжения..." ;;
        esac
    done
}

# --- ОСНОВНОЙ ПОТОК ВЫПОЛНЕНИЯ ---

# УЛУЧШЕНО: Логика первоначальной установки и самоопределения пути
# Эта часть выполняется самой первой.
# Если скрипт запущен не из $SCRIPT_PATH, он попытается себя туда "установить" и перезапуститься.
CURRENT_EXECUTED_SCRIPT_PATH=$(readlink -f "$0")

if [[ "$CURRENT_EXECUTED_SCRIPT_PATH" != "$SCRIPT_PATH" ]]; then
    echo "🚀 Обнаружен запуск скрипта не из стандартной установочной директории."
    echo "   Текущее расположение: $CURRENT_EXECUTED_SCRIPT_PATH"
    echo "   Ожидаемое расположение: $SCRIPT_PATH"

    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}⛔ Для первоначальной установки скрипта в $INSTALL_DIR и создания символической ссылки требуются права root.${RESET}"
        echo "   Пожалуйста, запустите скрипт с использованием sudo:"
        echo "   sudo $CURRENT_EXECUTED_SCRIPT_PATH $*"
        exit 1
    fi

    echo "🔧 Выполняется первоначальная настройка/перемещение скрипта..."
    mkdir -p "$INSTALL_DIR" || { echo -e "${RED}❌ Ошибка: не удалось создать каталог $INSTALL_DIR. Установка прервана.${RESET}"; exit 1; }
    
    # Копируем (перезаписывая, если существует) текущий запущенный скрипт в целевой путь
    cp "$CURRENT_EXECUTED_SCRIPT_PATH" "$SCRIPT_PATH" || { echo -e "${RED}❌ Ошибка: не удалось скопировать скрипт в $SCRIPT_PATH. Установка прервана.${RESET}"; exit 1; }
    chmod +x "$SCRIPT_PATH"
    echo -e "${GREEN}✅ Скрипт успешно скопирован в $SCRIPT_PATH и сделан исполняемым.${RESET}"

    setup_symlink # Эта функция вызовет ln -sf, которая перезапишет ссылку если нужно

# --- НОВОЕ ДОБАВЛЕНИЕ: Удаление временного файла ---
    if [[ -f "$CURRENT_EXECUTED_SCRIPT_PATH" ]]; then
        # Проверяем, что временный файл не является тем же самым файлом, куда мы только что скопировали
        # Это важно, чтобы избежать удаления самого себя, если вдруг что-то пошло не так
        if [[ "$CURRENT_EXECUTED_SCRIPT_PATH" != "$SCRIPT_PATH" ]]; then
            echo "🗑️ Удаление временного файла: $CURRENT_EXECUTED_SCRIPT_PATH"
            rm -f "$CURRENT_EXECUTED_SCRIPT_PATH"
        fi
    fi

    echo -e "${GREEN}✅ Первоначальная настройка завершена.${RESET}"
    echo "🔁 Перезапуск скрипта из установочной директории: $SCRIPT_PATH $*"
    # Передаем все исходные аргументы скрипта при перезапуске
    exec "$SCRIPT_PATH" "$@"
    exit 0 # Этот exit не будет достигнут, если exec сработает
fi

# --- Если мы здесь, значит скрипт уже запущен из $SCRIPT_PATH ---

# Обеспечиваем существование базовых каталогов (на случай, если их удалили вручную)
mkdir -p "$INSTALL_DIR" "$BACKUP_DIR" || { echo -e "${RED}❌ Ошибка при создании базовых каталогов $INSTALL_DIR или $BACKUP_DIR.${RESET}"; exit 1; }

# Обработка вызова бэкапа по cron (аргумент "backup")
if [[ "$1" == "backup" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Запуск бэкапа по расписанию..."
    # Для cron важно, чтобы конфигурация была загружена и зависимости проверены
    # Предполагается, что cron задача запускается с правами, достаточными для чтения конфига и выполнения docker
    load_or_create_config # Загружает или предлагает создать конфиг
    install_dependencies # Проверяет и устанавливает зависимости (может требовать root)
    create_backup
    exit 0
fi

# --- Для всех остальных интерактивных операций требуются права root ---
# Этот блок выполняется, только если $1 не "backup"
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}⛔ Для интерактивной работы и большинства операций (установка, настройка cron, обновление, удаление) требуются права root.${RESET}"
    echo "   Пожалуйста, запустите скрипт с использованием sudo:"
    if [[ -L "$SYMLINK_PATH" && "$(readlink -f "$SYMLINK_PATH")" == "$SCRIPT_PATH" ]]; then
        echo "   sudo $SYMLINK_PATH"
    else
        echo "   sudo $SCRIPT_PATH"
    fi
    exit 1
fi

# --- На этом этапе мы гарантированно имеем права root для интерактивного режима ---

# Загрузка/создание конфигурации (если не было сделано для cron)
load_or_create_config

# Установка зависимостей (если не было сделано для cron)
# Функция install_dependencies сама проверяет EUID и завершится, если не root и нужно ставить пакеты.
# Но здесь мы уже root.
install_dependencies

# Проверка/создание символической ссылки (если не было сделано при первоначальной установке или удалено)
setup_symlink

# Запуск главного меню
echo "Запуск главного меню..." # Отладочное сообщение
main_menu

exit 0
