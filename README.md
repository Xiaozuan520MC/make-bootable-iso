# make-bootable-iso.sh 使用手册

## 概述

`make-bootable-iso.sh` 是一个用于将编译好的 Linux 内核（`bzImage`）打包为可启动 ISO 镜像，并自动使用 QEMU 启动的辅助工具。  
**核心特性**：当未提供 initramfs 时，脚本**自动生成一个基于 BusyBox 的最小 initramfs**，确保内核能够正常启动到 shell，避免“VFS: Unable to mount root fs”恐慌。

---

##请将下载的文件放入linux内核的源代码文件夹中

## 依赖安装

### Ubuntu / Debian 系统

```bash
sudo apt update
sudo apt install xorriso grub-pc-bin grub-efi-amd64-bin qemu-system-x86 \
                 mtools dosfstools busybox-static cpio
```

- **强制依赖**：`xorriso`, `grub-mkimage`, `qemu-system-x86_64`
- **UEFI 模式**：`mtools`, `dosfstools`
- **自动生成 initramfs**：`busybox-static`, `cpio`

### 其他发行版

请使用对应包管理器安装等效软件包。

---

## 快速开始

### 1. 编译内核（前提）

在 Linux 源码目录中执行：

```bash
make defconfig
```

```bash
make -j$(nproc)
```

确保生成 `arch/x86/boot/bzImage`。

### 2. 直接运行脚本（自动生成 initramfs）

```bash
cd /path/to/linux-source
./make-bootable-iso.sh
```

- 脚本会自动检测 `bzImage`。
- 如果未指定 `-i` 且未检测到内置 initramfs，会自动生成 BusyBox initramfs。
- 生成 `linux.iso` 并启动 QEMU（默认使用串口控制台）。

---

## 命令行选项

| 选项 | 说明 |
|------|------|
| `-b, --bzimage <文件>` | 指定内核 `bzImage` 路径（默认：`arch/x86/boot/bzImage`） |
| `-i, --initrd <文件>`   | 指定外部 initramfs（cpio 格式）。若提供，则**禁用**自动生成 |
| `-o, --output <文件>`   | 指定输出 ISO 路径（默认：`linux.iso`） |
| `-m, --mem <大小>`      | QEMU 内存大小（默认：`512M`） |
| `-s, --smp <CPU数>`     | QEMU CPU 核心数（默认：`2`） |
| `-c, --cmdline <参数>`  | 附加内核启动参数（如 `root=/dev/sda1`） |
| `-e, --efi`             | 使用 UEFI 启动（默认：BIOS） |
| `-k, --no-kvm`          | 禁用 KVM 加速 |
| `-r, --run-only`        | 仅运行已有的 ISO（不重新生成） |
| `-n, --no-qemu`         | 仅生成 ISO，不启动 QEMU |
| `-f, --force`           | 强制覆盖已有 ISO 文件 |
| `-d, --debug`           | 调试模式（显示详细命令输出） |
| `--no-auto-initrd`      | **禁用**自动生成 BusyBox initramfs（若未提供 initrd 则添加 `root=/dev/sr0`） |
| `-h, --help`            | 显示帮助信息 |

---

## 使用示例

### 1. 默认使用（自动生成 initramfs）

```bash
./make-bootable-iso.sh
```

自动生成 BusyBox initramfs，启动后进入 shell。

### 2. 指定自定义 initramfs

```bash
./make-bootable-iso.sh -i /boot/initrd.img-$(uname -r)
```

使用系统现有的 initramfs（可能依赖特定模块）。

### 3. 生成 UEFI 启动 ISO（不启动 QEMU）

```bash
./make-bootable-iso.sh -e -n
```

生成 `linux.iso`，支持 UEFI + BIOS 双启动。

### 4. 仅运行已有 ISO（图形界面）

```bash
./make-bootable-iso.sh -r
```

默认使用串口控制台。如需图形窗口，可手动运行：

```bash
qemu-system-x86_64 -cdrom linux.iso -m 512M -vga std
```

### 5. 禁用自动生成 initramfs（仅测试内核）

```bash
./make-bootable-iso.sh --no-auto-initrd -f
```

此时若没有 initramfs，内核会尝试挂载 CD-ROM（`root=/dev/sr0`），但通常因缺少用户态而 panic。

### 6. 调试模式

```bash
./make-bootable-iso.sh -d -f
```

显示 GRUB 配置、xorriso 输出、QEMU 完整命令，便于排查问题。

---

## 工作流程

1. **检查依赖**：确保所需工具已安装。
2. **处理 initramfs**：
   - 优先使用 `-i` 指定的外部 initramfs。
   - 否则检查内核是否内置 initramfs（`usr/initramfs_data.cpio`）。
   - 若以上均无且 `--no-auto-initrd` 未启用，则**自动生成 BusyBox initramfs**。
3. **构建 ISO**：
   - 创建临时目录，复制 `bzImage` 和 initramfs（若有）。
   - 生成 GRUB 配置文件（含内核命令行）。
   - 使用 `xorriso` 创建可启动 ISO（支持 BIOS + 可选 UEFI）。
4. **启动 QEMU**（除非 `-n` 指定）：
   - 配置内存、CPU、显示（串口或 VGA）、网络、KVM 等。
   - 加载 ISO 并启动虚拟机。

---

## 内核命令行说明

- 当 `SERIAL_CONSOLE=true`（默认）时，自动添加 `console=ttyS0,115200 earlyprintk=serial`，便于串口日志。
- 若启用 `--no-auto-initrd` 且无 initramfs，则自动追加 `root=/dev/sr0`。
- 用户可通过 `-c` 添加任意参数（如 `root=/dev/sda1 init=/bin/sh`）。

---

## 切换图形界面

脚本默认使用串口控制台（`-nographic`）。若希望 QEMU 弹出图形窗口，请修改脚本中的 `SERIAL_CONSOLE=false`（约第 85 行），或在启动 ISO 时直接运行：

```bash
qemu-system-x86_64 -cdrom linux.iso -m 512M -vga std
```

---

## 故障排除

### 1. 启动后仍 panic（VFS 错误）

- 检查是否使用了 `--no-auto-initrd` 且未提供 initramfs → 移除该选项让脚本自动生成。
- 若使用自定义 initramfs，确认其格式为 **cpio 新格式**（`cpio -o --format=newc`）。

### 2. `grub-mkimage` 或 `xorriso` 报错

- 确保依赖包已完全安装（尤其是 `grub-pc-bin` 和 `xorriso`）。
- 使用 `-d` 模式查看详细错误信息。

### 3. 自动生成的 initramfs 不工作

- 确认 `busybox-static` 和 `cpio` 已安装。
- 手动测试：`busybox --help` 和 `echo test | cpio -o > /dev/null` 验证工具正常。

### 4. UEFI 启动失败

- 检查是否安装了 `mtools` 和 `dosfstools`。
- 确保 OVMF 固件存在（`/usr/share/ovmf/OVMF.fd` 等）。若无，可安装 `ovmf` 包。

### 5. QEMU 无法使用 KVM

- 若 `/dev/kvm` 不存在，请确认硬件支持虚拟化，并检查用户是否在 `kvm` 组中：`sudo usermod -aG kvm $USER`（需注销重登录）。

---

## 提示与注意事项

- **内核配置建议**：为获得最佳兼容性，请将常用文件系统（`ext4`, `iso9660`）和设备驱动（`ATA`, `SCSI`, `virtio-blk`）编译进内核（`=y`），而非模块（`=m`），因为 initramfs 可能无法自动加载模块。
- **ISO 文件位置**：默认生成在当前目录下的 `linux.iso`，可用 `-o` 更改。
- **自动生成的 initramfs**仅用于测试和演示，不包含驱动、网络、持久存储等功能，适合验证内核基本启动能力。
- **安全**：以普通用户运行即可，无需 root 权限（KVM 需要用户属于 `kvm` 组）。

---

##清理编译出来的linux文件可以使用
```bash
make mrproper
```

## 版权与许可

本脚本遵循 GNU GPL v2 许可证，原作者保留所有权利。欢迎修改和使用，但请保留版权声明。

---

**Happy Hacking!** 🐧
