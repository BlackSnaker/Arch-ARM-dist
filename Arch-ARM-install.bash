#!/bin/bash

# Функция для вывода сообщений
print_message() {
    local GREEN='\033[0;32m'
    local RED='\033[0;31m'
    local NC='\033[0m' # No Color
    if [ "$1" == "error" ]; then
        echo -e "${RED}Ошибка: $2${NC}"
    else
        echo -e "${GREEN}>> $1${NC}"
    fi
}

# Функция для проверки успешности выполнения команды
check_command_success() {
    if [ $? -ne 0 ]; then
        print_message "error" "$1"
        exit 1
    fi
}

# Функция для запроса у пользователя имени устройства
prompt_for_device() {
    local device_name=""
    while [ -z "$device_name" ]; do
        read -p "Введите имя вашего устройства SD-карты (например, sdX): " device_name
    done
    DEVICE="/dev/$device_name"
    echo $DEVICE
}

# Функция для запроса имени пользователя и пароля
prompt_for_user() {
    local username=""
    local password=""
    while [ -z "$username" ]; do
        read -p "Введите имя нового пользователя: " username
    done
    while [ -z "$password" ]; do
        read -sp "Введите пароль для пользователя $username: " password
        echo ""
        read -sp "Повторите пароль: " password2
        echo ""
        if [ "$password" != "$password2" ]; then
            print_message "error" "Пароли не совпадают. Попробуйте снова."
            password=""
        fi
    done
    echo "$username:$password"
}

# Функция для установки утилиты, если она отсутствует
install_utility() {
    local utility=$1
    if ! command -v "$utility" >/dev/null 2>&1; then
        print_message "Установка утилиты $utility..."
        if [ -n "$TERMUX_VERSION" ]; then
            pkg install -y "$utility"
            check_command_success "Ошибка при установке утилиты $utility."
        elif [ -x "$(command -v apt-get)" ]; then
            apt-get install -y "$utility"
            check_command_success "Ошибка при установке утилиты $utility."
        elif [ -x "$(command -v yum)" ]; then
            yum install -y "$utility"
            check_command_success "Ошибка при установке утилиты $utility."
        elif [ -x "$(command -v pacman)" ]; then
            pacman -S --noconfirm "$utility"
            check_command_success "Ошибка при установке утилиты $utility."
        else
            print_message "error" "Не удалось установить утилиту $utility."
            exit 1
        fi
    fi
}

# Проверка, выполняется ли скрипт от имени root
if [ "$EUID" -ne 0 ]; then
    print_message "error" "Пожалуйста, запустите этот скрипт от имени root или с помощью sudo."
    exit 1
fi

# Проверка доступности утилит
print_message "Проверка доступности утилит..."
for util in fdisk mkfs.fat mkfs.ext4 curl md5sum bsdtar useradd chpasswd; do
    install_utility "$util"
done

# Создание нового пользователя
create_user() {
    local user_info=$1
    IFS=':' read -r username password <<< "$user_info"
    useradd -m -G wheel "$username"
    if [ $? -ne 0 ]; then
        print_message "error" "Ошибка при создании пользователя."
        exit 1
    fi
    echo "$username:$password" | chpasswd
    check_command_success "Ошибка при создании пользователя."
    print_message "Пользователь $username успешно создан."
}

# Вывод стартового сообщения
print_message "Начало автоматической установки..."

# Запрос у пользователя имени устройства
print_message "Убедитесь, что заменили /dev/sdX на соответствующее имя устройства."
device=$(prompt_for_device)

# Проверка существования устройства
if [ ! -e "$device" ]; then
    print_message "error" "Устройство $device не найдено. Пожалуйста, введите допустимое имя устройства."
    exit 1
fi

# Проверка существующих монтирований
if [ -d "/mnt/boot" ] || [ -d "/mnt/root" ]; then
    print_message "error" "Каталоги монтирования (/mnt/boot или /mnt/root) уже существуют. Пожалуйста, удалите их перед выполнением скрипта."
    exit 1
fi

# Создание нового пользователя
print_message "Создание нового пользователя..."
user_info=$(prompt_for_user)
create_user "$user_info"

# Разбиение SD-карты на разделы
print_message "Разбиение SD-карты на разделы..."
fdisk "$device" <<EOF
o
n
p
1

+200M
t
c
n
p
2


w
EOF
check_command_success "Ошибка при разбиении SD-карты."

# Форматирование разделов
print_message "Форматирование разделов..."
mkfs.fat -F32 "${device}1"
check_command_success "Ошибка при форматировании раздела загрузки."
mkfs.ext4 "${device}2"
check_command_success "Ошибка при форматировании корневого раздела."

# Монтирование разделов
print_message "Монтирование разделов..."
mkdir -p /mnt/boot /mnt/root
mount "${device}1" /mnt/boot
check_command_success "Ошибка при монтировании раздела загрузки."
mount "${device}2" /mnt/root
check_command_success "Ошибка при монтировании корневого раздела."

# Загрузка Arch Linux ARM
print_message "Загрузка Arch Linux ARM..."
curl -JLO http://os.archlinuxarm.org/os/ArchLinuxARM-rpi-aarch64-latest.tar.gz
curl -JLO http://os.archlinuxarm.org/os/ArchLinuxARM-rpi-aarch64-latest.tar.gz.md5
check_command_success "Ошибка при загрузке Arch Linux ARM."

# Проверка загрузки
print_message "Проверка загрузки..."
md5sum -c ArchLinuxARM-rpi-aarch64-latest.tar.gz.md5
check_command_success "Ошибка при проверке загрузки."

# Извлечение загруженного архива
print_message "Извлечение загруженного архива..."
bsdtar -xpf ArchLinuxARM-rpi-aarch64-latest.tar.gz -C /mnt/root
check_command_success "Ошибка при извлечении архива."

# Перемещение файлов загрузки
print_message "Перемещение файлов загрузки..."
mv /mnt/root/boot/* /mnt/boot/
check_command_success "Ошибка при перемещении файлов загрузки."

# Размонтирование разделов
print_message "Размонтирование разделов..."
umount /mnt/boot /mnt/root
check_command_success "Ошибка при размонтировании разделов."

# Очистка
print_message "Очистка..."
rm -rf /mnt/boot /mnt/root ArchLinuxARM-rpi-aarch64-latest.tar.gz ArchLinuxARM-rpi-aarch64-latest.tar.gz.md5
check_command_success "Ошибка при очистке."

print_message "Установка завершена успешно!"
