# make-bootable-iso - Linux 内核一键启动工具

一个将编译好的 Linux 内核打包为可启动 ISO，并用 QEMU 快速启动的辅助脚本。

## ✨ 特性

- 🔨 **一键编译内核** - 集成 make defconfig/menuconfig + 编译
- 📦 **自动打包 ISO** - 将内核 `bzImage` 打包成可启动 ISO
- 🐚 **自动生成 initramfs** - 无需手动制作，自动生成 BusyBox initramfs
- 💾 **虚拟硬盘支持** - 自动创建和管理 qcow2 虚拟硬盘（支持 MB/GB 单位）
- 🖥️ **图形界面支持** - 默认使用 VGA 图形窗口，也可切换串口控制台
- 🎛️ **交互式菜单** - 无需记忆命令，菜单操作更简单
- 🔧 **UEFI 双启动** - 支持 BIOS + UEFI 启动模式
- ⚡ **KVM 加速** - 自动检测并启用 KVM 硬件加速
- 🎨 **彩色输出** - 清晰的信息分级显示

---

## 📢 更新公告 (v3.0)

### 🎯 重大更新：集成内核编译功能

**🔨 一键编译内核**
- 直接在菜单中编译内核，无需手动执行 make 命令
- 支持 defconfig / menuconfig / 已有配置
- 支持清理编译 (clean / mrproper)
- 自动检测 CPU 核心数，优化编译速度
- 显示编译用时统计
- 支持编译和安装内核模块

**📋 菜单更新**
- 新增选项 1: 编译内核
- 选项重新编号，功能分类更清晰
- 状态栏显示 CPU 核心数

**⚙️ 高级设置增强**
- 可调整编译并行数 (默认自动检测)
- 所有设置统一管理

---

## 📥 安装

### 1. 下载脚本

将 `make-bootable-iso.sh` 放入 Linux 内核源码目录：

```bash
cp make-bootable-iso.sh /path/to/linux-source/
cd /path/to/linux-source
chmod +x make-bootable-iso.sh
2. 安装依赖
Ubuntu / Debian
bash
sudo apt update
sudo apt install xorriso grub-pc-bin grub-efi-amd64-bin \
                 qemu-system-x86 qemu-utils \
                 mtools dosfstools busybox-static cpio \
                 build-essential bc bison flex libssl-dev
依赖说明
依赖	用途
xorriso	生成 ISO 镜像
grub-pc-bin	GRUB BIOS 启动支持
grub-efi-amd64-bin	GRUB UEFI 启动支持
qemu-system-x86	QEMU 虚拟机
qemu-utils	qemu-img (创建虚拟硬盘)
busybox-static	自动生成 initramfs
cpio	打包 initramfs
mtools	UEFI 模式支持
dosfstools	UEFI 模式支持
build-essential	编译内核所需 (gcc, make 等)
bc, bison, flex	内核编译依赖
libssl-dev	内核编译依赖 (OpenSSL)
🚀 快速开始
bash
# 进入交互式菜单
bash make-bootable-iso.sh
典型工作流程

1. 运行 bash make-bootable-iso.sh
2. 选择 1 → 编译内核
3. 选择配置方式 (推荐: 1 = defconfig)
4. 等待编译完成
5. 选择 2 或 3 → 构建 ISO 并启动
📖 使用指南
交互式菜单选项
选项	功能	说明
1	🔨 编译内核	进入内核编译子菜单
2	📦 构建 ISO 并启动	自动生成 initramfs，启动 QEMU
3	💾 构建 ISO + 创建硬盘并启动	创建虚拟硬盘并启动
4	💾 构建 ISO + 使用已有硬盘启动	使用已有硬盘启动
5	📀 仅构建 ISO	只生成 ISO，不启动
6	💾 仅创建虚拟硬盘	只创建硬盘文件
7	▶️ 运行已有的 ISO	直接启动 ISO
8	⚙️ 高级设置	内存/CPU/启动模式等
9	📊 查看文件状态	查看所有文件状态
0	🚪 退出	退出程序
编译内核子菜单
选项	功能
1	使用默认配置 + 编译 (make defconfig)
2	使用 menuconfig 配置 + 编译
3	使用已有 .config + 编译
4	仅编译 (不清理)
5	清理并重新编译 (make clean)
6	完全清理 (make mrproper)
0	返回主菜单

📄 许可证
GNU GPL v2

Happy Hacking! 🐧
