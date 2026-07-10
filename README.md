# make-bootable-iso.sh 使用手册

## 概述

make-bootable-iso.sh 是一个用于将编译好的 Linux 内核（bzImage）打包为可启动 ISO 镜像，并自动使用 QEMU 启动的辅助工具。
核心特性：
- 当未提供 initramfs 时，脚本自动生成一个基于 BusyBox 的最小 initramfs，确保内核能够正常启动到 shell
- 支持虚拟硬盘，可创建并挂载 qcow2 格式的虚拟硬盘
- 图形界面支持，默认使用 VGA 图形窗口启动 QEMU
- UEFI 双启动，支持 BIOS + UEFI 启动模式


## 文件位置

请将 make-bootable-iso.sh 放入 Linux 内核源代码文件夹中。


## 依赖安装

### Ubuntu / Debian 系统

sudo apt update
sudo apt install xorriso grub-pc-bin grub-efi-amd64-bin qemu-system-x86 \
                 mtools dosfstools busybox-static cpio qemu-utils

- 强制依赖：xorriso, grub-mkimage, qemu-system-x86_64
- UEFI 模式：mtools, dosfstools
- 自动生成 initramfs：busybox-static, cpio
- 虚拟硬盘支持：qemu-utils（提供 qemu-img 命令）

### 其他发行版

请使用对应包管理器安装等效软件包。


## 快速开始

### 1. 编译内核（前提）

在 Linux 源码目录中执行：

# 生成默认配置
make defconfig

# 编译内核
make -j$(nproc)

确保生成 arch/x86/boot/bzImage。

### 2. 直接运行脚本（自动生成 initramfs）

cd /path/to/linux-source
./make-bootable-iso.sh

- 脚本会自动检测 bzImage。
- 如果未指定 -i 且未检测到内置 initramfs，会自动生成 BusyBox initramfs。
- 生成 linux.iso 并启动 QEMU（默认使用图形窗口）。


## 命令行选项

| 选项 | 说明 |
|------|------|
| -b, --bzimage <文件> | 指定内核 bzImage 路径（默认：arch/x86/boot/bzImage） |
| -i, --initrd <文件>   | 指定外部 initramfs（cpio 格式）。若提供，则禁用自动生成 |
| -o, --output <文件>   | 指定输出 ISO 路径（默认：linux.iso） |
| -m, --mem <大小>      | QEMU 内存大小（默认：512M） |
| -s, --smp <CPU数>     | QEMU CPU 核心数（默认：2） |
| -c, --cmdline <参数>  | 附加内核启动参数（如 root=/dev/sda1） |
| -e, --efi             | 使用 UEFI 启动（默认：BIOS） |
| -k, --no-kvm          | 禁用 KVM 加速 |
| -r, --run-only        | 仅运行已有的 ISO（不重新生成） |
| -n, --no-qemu         | 仅生成 ISO，不启动 QEMU |
| -f, --force           | 强制覆盖已有 ISO 文件 |
| -d, --debug           | 调试模式（显示详细命令输出） |
| -g, --graphic         | 使用图形窗口启动 QEMU（默认） |
| --serial              | 使用串口控制台启动 QEMU |
| --no-auto-initrd      | 禁用自动生成 BusyBox initramfs |
| --disk <大小>         | 创建/使用虚拟硬盘（如：5G, 10G） |
| --disk-file <文件>    | 指定硬盘文件路径（默认：disk.qcow2） |
| --disk-only           | 仅创建硬盘，不启动 QEMU |
| -h, --help            | 显示帮助信息 |


## 使用示例

### 1. 默认使用（自动生成 initramfs + 图形窗口）

./make-bootable-iso.sh

自动生成 BusyBox initramfs，启动后进入 shell。

### 2. 创建虚拟硬盘并启动

./make-bootable-iso.sh --disk 5G

创建 5GB 虚拟硬盘并自动挂载，内核将尝试挂载 /dev/sda1 作为根分区。

### 3. 仅创建硬盘（不启动 QEMU）

./make-bootable-iso.sh --disk-only 5G

### 4. 使用自定义硬盘文件

./make-bootable-iso.sh --disk 10G --disk-file /path/to/mydisk.qcow2

### 5. 指定自定义 initramfs + 硬盘

./make-bootable-iso.sh -i /boot/initrd.img-$(uname -r) --disk 5G

使用系统现有的 initramfs，并挂载虚拟硬盘。

### 6. 使用已有 ISO + 硬盘

./make-bootable-iso.sh -r --disk 5G

### 7. 生成 UEFI 启动 ISO（不启动 QEMU）

./make-bootable-iso.sh -e -n

生成 linux.iso，支持 UEFI + BIOS 双启动。

### 8. 使用串口控制台（替代图形窗口）

./make-bootable-iso.sh --serial

### 9. 调试模式

./make-bootable-iso.sh -d -f

显示 GRUB 配置、xorriso 输出、QEMU 完整命令，便于排查问题。


## 工作流程

1. 检查依赖：确保所需工具已安装。
2. 创建硬盘（可选）：如果指定 --disk，使用 qemu-img 创建 qcow2 格式虚拟硬盘。
3. 处理 initramfs：
   - 优先使用 -i 指定的外部 initramfs。
   - 否则检查内核是否内置 initramfs（usr/initramfs_data.cpio）。
   - 若以上均无且 --no-auto-initrd 未启用，则自动生成 BusyBox initramfs。
4. 构建 ISO：
   - 创建临时目录，复制 bzImage 和 initramfs（若有）。
   - 生成 GRUB 配置文件（含内核命令行）。
   - 如果检测到硬盘，自动添加 root=/dev/sda1 参数。
   - 使用 xorriso 创建可启动 ISO（支持 BIOS + 可选 UEFI）。
5. 启动 QEMU（除非 -n 指定）：
   - 配置内存、CPU、显示（图形或串口）、网络、KVM 等。
   - 挂载虚拟硬盘（如果指定）。
   - 加载 ISO 并启动虚拟机。


## 内核命令行说明

- 图形模式（默认）：自动添加 console=tty0
- 串口模式（--serial）：自动添加 console=ttyS0,115200 earlyprintk=serial
- 硬盘模式（--disk）：自动添加 root=/dev/sda1
- 用户可通过 -c 添加任意参数（如 root=/dev/sda1 init=/bin/sh）
- 若启用 --no-auto-initrd 且无 initramfs，则自动追加 root=/dev/sr0


## 显示模式切换

### 图形窗口（默认）
./make-bootable-iso.sh
# 或显式指定
./make-bootable-iso.sh -g

### 串口控制台
./make-bootable-iso.sh --serial

### 手动启动图形窗口
qemu-system-x86_64 -cdrom linux.iso -m 512M -vga std


## 虚拟硬盘管理

### 创建硬盘
# 创建 5GB 硬盘
./make-bootable-iso.sh --disk-only 5G

# 创建 10GB 硬盘到指定位置
./make-bootable-iso.sh --disk-only 10G --disk-file ~/vm/disk.qcow2

### 查看硬盘信息
qemu-img info disk.qcow2

### 调整硬盘大小
qemu-img resize disk.qcow2 +5G

### 挂载硬盘到宿主机（需要 qemu-nbd）
sudo modprobe nbd
sudo qemu-nbd -c /dev/nbd0 disk.qcow2
sudo mount /dev/nbd0p1 /mnt
# 操作完成后
sudo umount /mnt
sudo qemu-nbd -d /dev/nbd0


## 安装完整 Linux 系统到虚拟硬盘

### 方法 1：使用 Ubuntu Server ISO

# 1. 下载 Ubuntu Server ISO
wget https://releases.ubuntu.com/22.04/ubuntu-22.04.3-live-server-amd64.iso

# 2. 创建虚拟硬盘
./make-bootable-iso.sh --disk-only 10G

# 3. 用安装 ISO 启动
qemu-system-x86_64 \
    -cdrom ubuntu-22.04.3-live-server-amd64.iso \
    -drive file=disk.qcow2,format=qcow2 \
    -m 2G -vga std -enable-kvm

# 4. 按照安装向导安装系统到 /dev/sda

# 5. 安装完成后，用您的内核启动
./make-bootable-iso.sh --disk 10G -f

### 方法 2：使用 Alpine Linux（极小系统）

# 下载 Alpine Linux
wget https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-standard-3.19.1-x86_64.iso

# 启动安装
qemu-system-x86_64 \
    -cdrom alpine-standard-3.19.1-x86_64.iso \
    -drive file=disk.qcow2,format=qcow2 \
    -m 512M -vga std -enable-kvm


## 在 BusyBox shell 中探索

启动后，您可以在 ~ # 提示符下执行命令：

# 查看文件系统
ls /

# 查看 CPU 信息
cat /proc/cpuinfo

# 查看内存信息
cat /proc/meminfo

# 查看已加载的模块
lsmod

# 查看网络设备
ip addr

# 查看进程
ps

# 查看系统版本
uname -a

# 查看块设备
ls /dev/sd*

# 挂载 CD-ROM
mkdir /mnt
mount /dev/sr0 /mnt
ls /mnt

# 退出
poweroff


## 故障排除

### 1. 启动后报 "No root device specified"

- 原因：未提供 initramfs 或未挂载硬盘
- 解决：
  - 使用自动生成的 BusyBox initramfs（不需要硬盘）：./make-bootable-iso.sh -f
  - 或添加硬盘：./make-bootable-iso.sh --disk 5G -f

### 2. 启动后报 "VFS: Unable to mount root fs"

- 检查是否使用了 --no-auto-initrd 且未提供 initramfs → 移除该选项让脚本自动生成
- 若使用自定义 initramfs，确认其格式为 cpio 新格式（cpio -o --format=newc）
- 检查内核是否包含必要的文件系统驱动（ext4, iso9660）

### 3. grub-mkimage 或 xorriso 报错

- 确保依赖包已完全安装（尤其是 grub-pc-bin 和 xorriso）
- 使用 -d 模式查看详细错误信息

### 4. 自动生成的 initramfs 不工作

- 确认 busybox-static 和 cpio 已安装
- 手动测试：busybox --help 和 echo test | cpio -o > /dev/null

### 5. UEFI 启动失败

- 检查是否安装了 mtools 和 dosfstools
- 确保 OVMF 固件存在（/usr/share/ovmf/OVMF.fd 等）
- 安装 OVMF：sudo apt install ovmf

### 6. QEMU 无法使用 KVM

- 检查硬件虚拟化是否启用：egrep -c '(vmx|svm)' /proc/cpuinfo
- 确保用户属于 kvm 组：sudo usermod -aG kvm $USER（需注销重登录）
- 在 BIOS 中启用 VT-x/AMD-V

### 7. qemu-img 未找到

sudo apt install qemu-utils

### 8. 虚拟硬盘无法识别

- 检查是否使用了 --disk 参数
- 确认硬盘文件存在：ls -lh disk.qcow2
- 在 BusyBox 中检查：ls /dev/sd*


## 提示与注意事项

- 内核配置建议：为获得最佳兼容性，请将常用文件系统（ext4, iso9660）和设备驱动（ATA, SCSI, virtio-blk）编译进内核（=y），而非模块（=m），因为 initramfs 可能无法自动加载模块。
- ISO 文件位置：默认生成在当前目录下的 linux.iso，可用 -o 更改。
- 虚拟硬盘位置：默认生成在当前目录下的 disk.qcow2，可用 --disk-file 更改。
- 自动生成的 initramfs仅用于测试和演示，不包含驱动、网络、持久存储等功能，适合验证内核基本启动能力。
- 安全：以普通用户运行即可，无需 root 权限（KVM 需要用户属于 kvm 组）。


## 清理编译文件

清理内核编译产生的文件可以使用：

make mrproper

这会删除所有编译生成的文件和配置文件，恢复到干净的源码状态。

### 清理脚本生成的文件

# 删除 ISO 文件
rm -f linux.iso

# 删除虚拟硬盘
rm -f disk.qcow2

# 删除临时文件
rm -rf /tmp/tmp.* 2>/dev/null


## 版权与许可

本脚本遵循 GNU GPL v2 许可证，原作者保留所有权利。欢迎修改和使用，但请保留版权声明。


Happy Hacking! 🐧
