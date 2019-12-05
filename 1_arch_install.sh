#!/bin/bash

echo "Encryption assphrase"
read encryption_passphrase

echo "root_password"
read root_password
echo "user password"
read user_password
echo "hostname"
read hostname
echo "user name"
read user_name
echo "Continent/City (Europe/Copenhagen)"
read continent_city
echo "sway size (number)"
read swap_size

echo "Updating system clock"
timedatectl set-ntp true

echo "Creating partition tables"
printf "n\n1\n4096\n+512M\nef00\nw\ny\n" | gdisk /dev/sda
printf "n\n2\n\n\n8e00\nw\ny\n" | gdisk /dev/sda

echo "Zeroing partitions"
#cat /dev/zero > /dev/nvme0n1p1
#cat /dev/zero > /dev/nvme0n1p2

echo "Building EFI filesystem"
yes | mkfs.fat -F32 /dev/sda1

echo "Setting up cryptographic volume"
printf "%s" "$encryption_passphrase" | cryptsetup -c aes-xts-plain64 -h sha512 -s 512 --use-random --type luks2 --label LVMPART luksFormat /dev/sda2
printf "%s" "$encryption_passphrase" | cryptsetup luksOpen /dev/sda2 cryptoVols

echo "Setting up LVM"
pvcreate /dev/mapper/cryptoVols
vgcreate Arch /dev/mapper/cryptoVols
lvcreate -L +"$swap_size"GB Arch -n swap
lvcreate -l +100%FREE Arch -n root

echo "Building filesystems for root and swap"
yes | mkswap /dev/mapper/Arch-swap
yes | mkfs.ext4 /dev/mapper/Arch-root

echo "Mounting root/boot and enabling swap"
mount /dev/mapper/Arch-root /mnt
mkdir /mnt/boot
mount /dev/sda1 /mnt/boot
swapon /dev/mapper/Arch-swap

echo "Installing Arch Linux"
yes '' | pacstrap /mnt base base-devel intel-ucode networkmanager wget reflector

echo "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

echo "Configuring new system"
arch-chroot /mnt /bin/bash <<EOF
echo "Setting system clock"
ln -fs /usr/share/zoneinfo/$continent_city /etc/localtime
hwclock --systohc --localtime

echo "Setting locales"
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "LANG=en_US.UTF-8" >> /etc/locale.conf
locale-gen

echo "Setting hostname"
echo $hostname > /etc/hostname

echo "Setting root password"
echo -en "$root_password\n$root_password" | passwd

echo "Creating new user"
useradd -m -G wheel -s /bin/bash $user_name
echo -en "$user_password\n$user_password" | passwd $user_name

echo "Generating initramfs"
sed -i 's/^HOOKS.*/HOOKS=(base udev keyboard autodetect modconf block keymap encrypt lvm2 resume filesystems fsck)/' /etc/mkinitcpio.conf
sed -i 's/^MODULES.*/MODULES=(ext4 intel_agp i915)/' /etc/mkinitcpio.conf
mkinitcpio -p linux

echo "Setting up systemd-boot"
bootctl --path=/boot install

mkdir -p /boot/loader/
touch /boot/loader/loader.conf
tee -a /boot/loader/loader.conf << END
default arch
timeout 0
editor 0
END

mkdir -p /boot/loader/entries/
touch /boot/loader/entries/arch.conf
tee -a /boot/loader/entries/arch.conf << END
title ArchLinux
linux /vmlinuz-linux
initrd /intel-ucode.img
initrd /initramfs-linux.img
options cryptdevice=LABEL=LVMPART:cryptoVols root=/dev/mapper/Arch-root resume=/dev/mapper/Arch-swap quiet rw
END

echo "Updating mirrors list"
cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.BAK
reflector --latest 200 --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

touch /etc/pacman.d/hooks/mirrors-update.hook
tee -a /etc/pacman.d/hooks/mirrors-update.hook << END
[Trigger]
Operation = Upgrade
Type = Package
Target = pacman-mirrorlist

[Action]
Description = Updating pacman-mirrorlist with reflector
When = PostTransaction
Depends = reflector
Exec = /bin/sh -c "reflector --latest 200 --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist"
END

echo "Enabling periodic TRIM"
#systemctl enable fstrim.timer

echo "Enabling NetworkManager"
#systemctl enable NetworkManager

echo "Adding user as a sudoer"
echo '%wheel ALL=(ALL) ALL' | EDITOR='tee -a' visudo
EOF

umount -R /mnt
swapoff -a

echo "ArchLinux is ready. You can reboot now!"
