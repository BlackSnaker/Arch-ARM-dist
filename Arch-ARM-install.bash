#!/bin/bash

# Функция для вывода сообщений
print_message() {
    local GREEN='\033[0;32m'
    local NC='\033[0m' # No Color
    echo -e "${GREEN}>> $1${NC}"
}

# Функция для проверки успешности выполнения команды
check_command_success() {
    if [ $? -ne 0 ]; then
        print_message "Ошибка: $1"
        exit 1
    fi
}

# Функция для запроса у пользователя имени устройства
prompt_for_device() {
    read -p "Введите имя вашего устройства SD-карты (например, sdX): " device_name
    DEVICE="/dev/$device_name"
    echo $DEVICE
}

# Проверка, выполняется ли скрипт от имени root
if [ "$EUID" -ne 0 ]; then
    print_message "Пожалуйста, запустите этот скрипт от имени root или с помощью sudo."
    exit 1
fi

# Вывод стартового сообщения
print_message "Начало автоматической установки..."

# Запрос у пользователя имени устройства
print_message "Убедитесь, что заменили /dev/sdX на соответствующее имя устройства."
device=$(prompt_for_device)

# Проверка существования устройства
while [ ! -e "$device" ]; do
    print_message "Устройство $device не найдено. Пожалуйста, введите допустимое имя устройства."
    device=$(prompt_for_device)
done

# Проверка предварительных условий
print_message "Проверка предварительных условий..."
# Добавьте сюда любые проверки предварительных условий, если необходимо

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
curl -JLO http://os.archlinuxarm.org/os/ArchLinuxARM-rpi-armv7-latest.tar.gz
curl -JLO http://os.archlinuxarm.org/os/ArchLinuxARM-rpi-armv7-latest.tar.gz.md5
check_command_success "Ошибка при загрузке Arch Linux ARM."

# Проверка загрузки
print_message "Проверка загрузки..."
md5sum -c ArchLinuxARM-rpi-armv7-latest.tar.gz.md5
check_command_success "Ошибка при проверке загрузки."

# Извлечение загруженного архива
print_message "Извлечение загруженного архива..."
bsdtar -xpf ArchLinuxARM-rpi-armv7-latest.tar.gz -C /mnt/root
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
rm -rf /mnt/boot /mnt/root ArchLinuxARM-rpi-armv7-latest.tar.gz ArchLinuxARM-rpi-armv7-latest.tar.gz.md5
check_command_success "Ошибка при очистке."

print_message "Установка завершена успешно!"
