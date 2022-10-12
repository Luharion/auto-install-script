#!/bin/sh
# ++-- Artix Linux Minimal Encrypted Install Script --++

# Proper usage checks.
[ -z "$1" ] && echo "Usage:
artix-luks-base-install dev/name encrypt3dpassw0rd" && exit
[ -z "$(ls /sys/firmware/efi/efivars)" ] && echo "EFI only installation; Please boot with EFI." && exit
[ $(id -u) != 0 ] && echo "Root privileges required." && exit
[ -z "$(connmanctl state | grep -e online -e ready)" ] && \
	echo "No network connection." && exit

# Parameters.
targetdisk=$1
[ -z "$targetdisk" ] && echo "No target disk specified." && exit
cryptpass=$2
[ -z "$cryptpass" ] && echo "No encryption password provided." && exit

cvg=CryptVolGroup

echo "+-- Artix Installation Parameters --+"
echo "Target disk   : \"$targetdisk\""
echo "Crypto pass   : \"$cryptpass\""
echo "Cryptvol group: \"$cvg\""
echo -n "Correct?" && read

# Reset/init.
pacman -Sy --noconfirm parted
swapoff /dev/$cvg/swap 2>/dev/null
umount -R /mnt 2>/dev/null
vgchange -a n 2>/dev/null
cryptsetup close cryptlvm 2>/dev/null
killall -s 9 cryptsetup 2>/dev/null

set -xe
# Partition the disk.
parted -s -a optimal $targetdisk mklabel gpt
parted -s -a optimal $targetdisk mkpart "BOOT" fat32 0% 512MiB
parted -s -a optimal $targetdisk set 1 esp on
parted -s -a optimal $targetdisk mkpart "CRYPT" ext4 512MiB 100%

# Set up LUKS encrypted container.
echo -ne "$cryptpass" | cryptsetup luksFormat ${targetdisk}2 -d -
echo -ne "$cryptpass" | cryptsetup open ${targetdisk}2 cryptlvm -d -

# Create logical volumes.
pvcreate /dev/mapper/cryptlvm
vgcreate $cvg /dev/mapper/cryptlvm
lvcreate -L 16G $cvg -n swap
lvcreate -L 150G $cvg -n root
lvcreate -l 100%FREE $cvg -n home

# Make filesystems.
mkfs.fat -F32 ${targetdisk}1
mkswap -f /dev/$cvg/swap
mkfs.ext4 -qF /dev/$cvg/root
mkfs.ext4 -qF /dev/$cvg/home

# Mount filesystems.
mount /dev/$cvg/root /mnt
mkdir /mnt/boot
mkdir /mnt/home
mount ${targetdisk}1 /mnt/boot
mount /dev/$cvg/home /mnt/home
swapon /dev/$cvg/swap

# Basestrap the system and install lvm hooks.
basestrap /mnt openrc elogind-openrc base base-devel networkmanager networkmanager-openrc neovim git
basestrap /mnt linux linux-firmware
fstabgen -U /mnt > /mnt/etc/fstab
sed -s 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block \
encrypt keyboard keymap lvm2 resume filesystems fsck)/g' -i /mnt/etc/mkinitcpio.conf
basestrap /mnt cryptsetup lvm2 mkinitcpio grub efibootmgr

# Install grub.
cryptuuid=$(blkid -s UUID -o value ${targetdisk}2)
swapuuid=$(blkid -s UUID -o value /dev/$cvg/swap)
sed -s "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"\
cryptdevice=UUID=$cryptuuid:lvm-system loglevel=3 quiet resume=UUID=$swapuuid net.ifnames=0\"/g" \
	-i /mnt/etc/default/grub
sed -s 's/^#GRUB_ENABLE_CRYPTODISK=y/GRUB_ENABLE_CRYPTODISK=y/g' -i /mnt/etc/default/grub
artix-chroot /mnt sh -c 'grub-install --target=x86_64-efi --efi-directory=/boot \
--bootloader-id=grub && grub-mkconfig -o /boot/grub/grub.cfg'

# Set root password and sudoers.
artix-chroot /mnt sh -c 'echo root:ZWwVJ4tM7u | chpasswd'
sed -s 's/# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL \
Defaults rootpw,pwfeedback/g' -i /mnt/etc/sudoers

# Set hosts and link NetworkManager.
echo "home" > /mnt/etc/hostname
echo '127.0.0.1 localhost
::1 localhost
127.0.1.1 home.localdomain home' >> /mnt/etc/hosts
artix-chroot /mnt sh -c 'rc-update add NetworkManager && rc-service NetworkManager start'

# Set locale and default timezone.
echo 'LANG="en_US.UTF-8"
LC_COLLATE="C"' > /mnt/etc/locale.conf
sed -s 's/#en_US/en_US/g' -i /mnt/etc/locale.gen
artix-chroot /mnt sh -c 'locale-gen'
artix-chroot /mnt sh -c 'ln -sf /usr/share/zoneinfo/America/Chicago /etc/localtime && hwclock -w'

# Perform cleanups.
swapoff /dev/$cvg/swap
umount -R /mnt
vgchange -a n
cryptsetup close cryptlvm

set +x
echo
echo '+---------------------------------------------------------------+'
echo '| Installation completed, you can log in with root password 123 |'
echo '+---------------------------------------------------------------+'
