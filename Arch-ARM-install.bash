#!/bin/bash
set -euo pipefail

# ------------------------------------------------------
# НАСТРАИВАЕМЫЕ ПАРАМЕТРЫ
# ------------------------------------------------------
BOOT_PART_SIZE="+200M"  # Размер раздела /boot
ARCH_URL="http://os.archlinuxarm.org/os/ArchLinuxARM-rpi-aarch64-latest.tar.gz"
ARCH_SUM_URL="${ARCH_URL}.md5"  # MD5-файл

# ------------------------------------------------------
# ПРОВЕРКА ЗАПУСКА ОТ ROOT
# ------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    zenity --error --title="Ошибка" --text="Пожалуйста, запустите скрипт от имени root (или через sudo)." --width=300
    exit 1
fi

# ------------------------------------------------------
# ФУНКЦИИ ДЛЯ ZENITY (GUI)
# ------------------------------------------------------
zenity_info() {
    local message="$1"
    zenity --info --title="Информация" --text="$message" --width=400 2>/dev/null
}

zenity_error() {
    local message="$1"
    zenity --error --title="Ошибка" --text="$message" --width=400 2>/dev/null
}

zenity_confirm() {
    local message="$1"
    if zenity --question --title="Подтверждение" --text="$message" --width=400 2>/dev/null; then
        return 0  # Yes
    else
        return 1  # No
    fi
}

# ------------------------------------------------------
# ПРОВЕРКА И УСТАНОВКА УТИЛИТ
# ------------------------------------------------------
install_utility() {
    local util="$1"
    if ! command -v "$util" &>/dev/null; then
        # Показываем сообщение, что пытаемся установить утилиту
        zenity_info "Утилита <b>$util</b> не найдена. Пытаемся установить..."
        if [ -n "${TERMUX_VERSION:-}" ]; then
            pkg install -y "$util"
        elif command -v apt-get &>/dev/null; then
            apt-get update -y
            apt-get install -y "$util"
        elif command -v yum &>/dev/null; then
            yum install -y "$util"
        elif command -v pacman &>/dev/null; then
            pacman -Sy --noconfirm "$util"
        else
            zenity_error "Не удалось установить <b>$util</b> автоматически. Установите её вручную."
            exit 1
        fi
    fi
}

REQUIRED_UTILS=(
    zenity      # графический интерфейс
    fdisk
    mkfs.fat
    mkfs.ext4
    curl
    md5sum
    bsdtar
    useradd
    chpasswd
    lsblk
)

for util in "${REQUIRED_UTILS[@]}"; do
    install_utility "$util"
done

# ------------------------------------------------------
# 1. ВЫБОР УСТРОЙСТВА ИЗ СПИСКА
# ------------------------------------------------------
get_install_device() {
    # Сформируем список доступных устройств (тип "disk") через lsblk
    # Выведем в формате: "<выбор> <device_name> <размер>"
    # А Zenity покажет это как список с опцией --radiolist (переключатель)
    
    local IFS=$'\n'
    local devices_list=()
    while read -r line; do
        # line: sda 465.8G disk
        local dev_name=$(echo "$line" | awk '{print $1}')
        local dev_size=$(echo "$line" | awk '{print $2}')
        local dev_type=$(echo "$line" | awk '{print $3}')
        # Проверяем, что тип == disk
        # Формируем запись для zenity --list: первая колонка для радиокнопки (FALSE/TRUE)
        if [ "$dev_type" == "disk" ]; then
            devices_list+=("FALSE" "$dev_name" "$dev_size")
        fi
    done < <(lsblk -dn -o NAME,SIZE,TYPE)

    # Если список пуст, сообщим об ошибке
    if [ ${#devices_list[@]} -eq 0 ]; then
        zenity_error "Не найдено ни одного физического диска (TYPE=disk)."
        exit 1
    fi

    # Запустим Zenity --list в режиме radiolist
    local chosen_dev
    chosen_dev=$(zenity --list \
                        --title="Выберите диск" \
                        --text="Ниже перечислены устройства TYPE=disk. Выберите тот, куда установить Arch Linux ARM.\n<b>ВНИМАНИЕ:</b> Все данные на выбранном диске будут удалены!" \
                        --radiolist \
                        --column="Выбор" --column="Устройство" --column="Размер" \
                        --width=550 --height=350 \
                        "${devices_list[@]}" \
                        2>/dev/null) || {
        # Если пользователь нажал Отмена
        zenity_error "Операция отменена пользователем."
        exit 1
    }

    if [ -z "$chosen_dev" ]; then
        zenity_error "Не выбрано устройство. Прерывание."
        exit 1
    fi

    echo "/dev/$chosen_dev"
}

device="$(get_install_device)"

# ------------------------------------------------------
# 2. ПОДТВЕРЖДЕНИЕ УДАЛЕНИЯ ДАННЫХ
# ------------------------------------------------------
if ! zenity_confirm "Вы выбрали диск <b>$device</b>.\nВсе данные на нём будут <b>удалены</b>.\n\nПродолжить?"; then
    zenity_error "Операция отменена пользователем."
    exit 1
fi

# ------------------------------------------------------
# 3. ВВОД ПОЛЬЗОВАТЕЛЯ И ПАРОЛЯ (ФОРМА)
# ------------------------------------------------------
get_user_info() {
    while true; do
        # zenity --forms позволяет создать несколько полей в одном окне
        # --add-entry для текстового поля, --add-password для ввода пароля (скрыто)
        # separator=':' чтобы разделить результат
        local form_result
        form_result=$(
            zenity --forms --title="Параметры пользователя" \
                   --text="Введите имя пользователя и пароль\nПароль нужно ввести дважды для подтверждения." \
                   --separator=":" \
                   --add-entry="Имя пользователя" \
                   --add-password="Пароль" \
                   --add-password="Повтор пароля" \
                   --width=400 2>/dev/null
        ) || {
            # Нажато Отмена
            zenity_error "Операция отменена пользователем."
            exit 1
        }

        # Распарсим результат
        # form_result выглядит как "username:pass1:pass2"
        local username pass1 pass2
        IFS=":" read -r username pass1 pass2 <<< "$form_result"

        # Проверим, что поля не пусты
        if [ -z "$username" ] || [ -z "$pass1" ] || [ -z "$pass2" ]; then
            zenity_error "Поля не могут быть пустыми. Повторите ввод."
            continue
        fi

        # Проверяем совпадение паролей
        if [ "$pass1" != "$pass2" ]; then
            zenity_error "Пароли не совпадают! Повторите ввод."
            continue
        fi

        # Возвращаем "username:password"
        echo "$username:$pass1"
        return 0
    done
}

user_info="$(get_user_info)"

# ------------------------------------------------------
# 4. РАЗМЕТКА И ФОРМАТИРОВАНИЕ (С ОКНОМ ПРОГРЕССА)
# ------------------------------------------------------
(
    echo "10"
    echo "# Разметка диска $device (MBR, fdisk)..."
    fdisk "$device" <<EOF
o
n
p
1

${BOOT_PART_SIZE}
t
c
n
p
2


w
EOF

    echo "40"
    echo "# Форматирование разделов..."
    mkfs.fat -F32 "${device}1"
    mkfs.ext4 "${device}2"

    echo "70"
    echo "# Создание точек монтирования..."
    mkdir -p /mnt/boot /mnt/root
    mount "${device}1" /mnt/boot
    mount "${device}2" /mnt/root
    echo "100"
) | zenity --progress \
           --title="Разметка и форматирование" \
           --text="Выполняется разметка и форматирование..." \
           --percentage=0 --auto-close --width=500 2>/dev/null

# Если пользователь закроет окно прогресса, zenity завершится с кодом 1 → скрипт упадёт (set -e)

# ------------------------------------------------------
# 5. ЗАГРУЗКА И ПРОВЕРКА ОБРАЗА
# ------------------------------------------------------
(
    echo "0"
    echo "# Скачиваем образ Arch Linux ARM..."
    # Чтобы красиво показывать прогресс curl, нужно парсить вывод. Проще дать пульсирующий.
    # Здесь делаем просто пульсирующий режим (без точного %).
    sleep 1
) | zenity --progress --pulsate \
           --title="Загрузка образа" \
           --text="Загружается Arch Linux ARM..." \
           --auto-close --width=500 2>/dev/null

curl -JLO "$ARCH_URL"
curl -JLO "$ARCH_SUM_URL"

(
    echo "0"
    echo "# Проверка контрольной суммы (md5sum)..."
    sleep 1
) | zenity --progress --pulsate \
           --title="Проверка целостности" \
           --text="Проверяем md5sum..." \
           --auto-close --width=500 2>/dev/null

md5sum -c "$(basename "$ARCH_SUM_URL")"

# ------------------------------------------------------
# 6. РАСПАКОВКА
# ------------------------------------------------------
(
    echo "0"
    echo "# Извлечение Arch Linux ARM в /mnt/root..."
    sleep 1
) | zenity --progress --pulsate \
           --title="Распаковка" \
           --text="Извлекаем образ (bsdtar -xpf)..." \
           --auto-close --width=500 2>/dev/null

bsdtar -xpf "$(basename "$ARCH_URL")" -C /mnt/root

# Перенос boot
mv /mnt/root/boot/* /mnt/boot/

# ------------------------------------------------------
# 7. СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ В CHROOT
# ------------------------------------------------------
(
    echo "0"
    echo "# Настраиваем нового пользователя в установленной системе..."
    sleep 1
) | zenity --progress --pulsate \
           --title="Создание пользователя" \
           --text="Выполняется chroot и настройка пользователя..." \
           --auto-close --width=500 2>/dev/null

# Монтируем системные каталоги, чтобы useradd/chpasswd внутри chroot работали
mount -t proc /proc /mnt/root/proc
mount --rbind /sys /mnt/root/sys
mount --rbind /dev /mnt/root/dev

IFS=":" read -r username password <<< "$user_info"

chroot /mnt/root useradd -m -G wheel "$username"
echo "$username:$password" | chroot /mnt/root chpasswd

# Отмонтируем
umount -R /mnt/root/proc || true
umount -R /mnt/root/sys  || true
umount -R /mnt/root/dev  || true

# ------------------------------------------------------
# 8. ЗАВЕРШЕНИЕ УСТАНОВКИ
# ------------------------------------------------------
(
    echo "0"
    echo "# Финальная очистка..."
    sleep 1
) | zenity --progress --pulsate \
           --title="Очистка и размонтирование" \
           --text="Удаляем временные файлы, размонтируем разделы..." \
           --auto-close --width=500 2>/dev/null

umount /mnt/boot
umount /mnt/root
rmdir /mnt/boot /mnt/root 2>/dev/null || true

rm -f "$(basename "$ARCH_URL")" "$(basename "$ARCH_SUM_URL")"

zenity_info "<b>Установка Arch Linux ARM завершена успешно!</b>\n\nВы можете вынуть SD-карту и загрузиться с неё на Raspberry Pi."
exit 0
