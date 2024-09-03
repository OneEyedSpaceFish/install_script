#!/bin/bash
set -e

confirm() {
    read -p "$1 (y/n): " response
    case "$response" in
        [yY]) return 0 ;;
        *) echo "Exiting script."; exit 1 ;;
    esac
}

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

if [ ! -b /dev/nvme0n1 ]; then
  echo "NVMe drive /dev/nvme0n1 not found!"
  exit 1
fi

timedatectl set-ntp true

DRIVE_SIZE_MB=$(blockdev --getsize64 /dev/nvme0n1 | awk '{print int($1/1024/1024)}')
confirm "Drive size: ${DRIVE_SIZE_MB}MB. Continue?"

EFI_SIZE=1024
SWAP_SIZE=32768
MAIN_PARTITION_SIZE=$(echo "($DRIVE_SIZE_MB - $EFI_SIZE - $SWAP_SIZE) * 0.9" | bc | awk '{print int($1)}')
RESERVED_SIZE=$(echo "$DRIVE_SIZE_MB - $EFI_SIZE - $SWAP_SIZE - $MAIN_PARTITION_SIZE" | bc)

echo "Calculated partition sizes:"
echo "EFI partition: ${EFI_SIZE}MB"
echo "Swap partition: ${SWAP_SIZE}MB"
echo "Main partition: ${MAIN_PARTITION_SIZE}MB"
echo "Reserved size: ${RESERVED_SIZE}MB"
confirm "Are these partition sizes acceptable?"

parted -s /dev/nvme0n1 mklabel gpt
parted -s /dev/nvme0n1 mkpart ESP fat32 1MiB 1025MiB
parted -s /dev/nvme0n1 set 1 boot on
parted -s /dev/nvme0n1 mkpart primary linux-swap 1025MiB 33793MiB
parted -s /dev/nvme0n1 mkpart primary 33793MiB 100%

confirm "Partitions created. Continue with formatting?"

mkfs.fat -F32 /dev/nvme0n1p1

mkswap -L swap /dev/nvme0n1p2
swapon /dev/nvme0n1p2

confirm "Swap setup complete. Continue with encryption setup?"

cryptsetup luksFormat --type luks2 -c aes-xts-plain64 -s 512 -h sha512 /dev/nvme0n1p3 --batch-mode
cryptsetup open /dev/nvme0n1p3 cryptlvm

confirm "Encryption setup complete. Continue with LVM setup?"

pvcreate /dev/mapper/cryptlvm
vgcreate vg0 /dev/mapper/cryptlvm
lvcreate -L 30G vg0 -n root
lvcreate -l 100%FREE vg0 -n home

confirm "LVM setup complete. Continue with formatting LVM volumes?"

mkfs.ext4 -O "^has_journal" /dev/vg0/root
mkfs.ext4 -O "^has_journal" /dev/vg0/home

confirm "LVM volumes formatted. Continue with mounting partitions?"

mount /dev/vg0/root /mnt
mkdir /mnt/boot
mount /dev/nvme0n1p1 /mnt/boot
mkdir /mnt/home
mount /dev/vg0/home /mnt/home

confirm "Partitions mounted. Continue with base system installation?"

pacstrap /mnt base base-devel linux-zen linux-zen-headers linux-firmware vim amd-ucode

genfstab -U /mnt > /mnt/etc/fstab
sed -i 's/relatime/noatime,discard=async,commit=60,lazytime,errors=remount-ro/' /mnt/etc/fstab

confirm "Base system installed and fstab generated. Continue with system configuration?"

arch-chroot /mnt /bin/bash << 'EOF'
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
hwclock --systohc

echo "en_GB.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_GB.UTF-8" > /etc/locale.conf

echo "KEYMAP=uk" > /etc/vconsole.conf

echo "usagi" > /etc/hostname

echo "root:password" | chpasswd

pacman -Sy --noconfirm reflector
reflector --latest 200 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
sed -i '4,$d' /etc/pacman.d/mirrorlist
pacman -Rns --noconfirm reflector

bootctl install
cat << BOOTLOADER > /boot/loader/loader.conf
default arch
timeout 3
editor 0
BOOTLOADER

PARTUUID=$(blkid -s PARTUUID -o value /dev/nvme0n1p3)
cat << BOOTLOADER > /boot/loader/entries/arch.conf
title Arch Linux
linux /vmlinuz-linux-zen
initrd /amd-ucode.img
initrd /initramfs-linux-zen.img
options cryptdevice=PARTUUID=$PARTUUID:cryptlvm root=/dev/vg0/root quiet rw elevator=none
BOOTLOADER

sed -i 's/^HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)/HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -p linux-zen

# Install necessary packages from official repositories
packages=(iwd sudo tlp xf86-video-amdgpu vulkan-radeon libva-mesa-driver mesa-vdpau corectrl cpupower)

pacman -S --noconfirm "${packages[@]}"
if [ $? -ne 0 ]; then
    echo "Error: Failed to install necessary packages from official repositories. Exiting."
    exit 1
fi

# Install aura AUR helper
pacman -S --noconfirm git go
git clone https://aur.archlinux.org/aura-bin.git /tmp/aura-bin
cd /tmp/aura-bin
makepkg -si --noconfirm
if [ $? -ne 0 ]; then
    echo "Error: Failed to install aura. Exiting."
    exit 1
fi

# Install preload using aura
aura -A --noconfirm preload
if [ $? -ne 0 ]; then
    echo "Error: Failed to install preload from AUR. Exiting."
    exit 1
fi

# Enable necessary services
systemctl enable iwd.service || echo "iwd.service not found, ensure package 'iwd' is installed."
systemctl enable tlp.service || echo "tlp.service not found, ensure package 'tlp' is installed."
systemctl enable preload.service || echo "preload.service not found, ensure package 'preload' is installed."
systemctl enable cpupower.service || echo "cpupower.service not found, ensure package 'cpupower' is installed."

echo "CPU_SCALING_GOVERNOR_ON_AC=performance" >> /etc/tlp.conf
echo "CPU_SCALING_GOVERNOR_ON_BAT=performance" >> /etc/tlp.conf

echo "governor='performance'" > /etc/default/cpupower

echo "vm.swappiness=1" > /etc/sysctl.d/99-swappiness.conf

echo "cryptlvm UUID=$(blkid -s UUID -o value /dev/nvme0n1p3) none luks,discard" >> /etc/crypttab

sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 5/' /etc/pacman.conf

sed -i 's/#MAKEFLAGS="-j2"/MAKEFLAGS="-j$(nproc)"/' /etc/makepkg.conf

useradd -m -G wheel -s /bin/bash gawain
useradd -m -G wheel -s /bin/bash g
echo "gawain:password" | chpasswd
echo "g:password" | chpasswd

echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel

EOF

confirm "System configuration complete. Ready to unmount and reboot?"

umount -R /mnt
swapoff -a
sync
reboot
