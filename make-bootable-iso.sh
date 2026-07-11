#!/bin/bash
# =============================================================================
# make-bootable-iso.sh - Linux 内核一键打包启动工具
#                        (支持编译内核 + 自动生成 BusyBox initramfs + 虚拟硬盘)
# =============================================================================
# 用法:
#   ./make-bootable-iso.sh                    # 进入交互式菜单
#   ./make-bootable-iso.sh --help             # 显示帮助
# =============================================================================

set -e

# ---- 颜色定义 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color
WHITE='\033[1;37m'
BG_RED='\033[41m'
BG_GREEN='\033[42m'
BG_YELLOW='\033[43m'

# ---- 工具函数 ----
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
bold()  { echo -e "${BOLD}$*${NC}"; }
step()  { echo -e "${BLUE}▶${NC} $*"; }

# ---- 清理函数 ----
cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
    if [ -n "$AUTO_INITRD_FILE" ] && [ -f "$AUTO_INITRD_FILE" ]; then
        rm -f "$AUTO_INITRD_FILE"
    fi
}
trap cleanup EXIT

# ---- 默认配置 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_SRC="$SCRIPT_DIR"
KERNEL_BZIMAGE="${KERNEL_SRC}/arch/x86/boot/bzImage"
INITRAMFS=""
INITRAMFS_BUILTIN=""
OUTPUT_ISO="${KERNEL_SRC}/linux.iso"
QEMU_MEM="512M"
QEMU_SMP="2"
QEMU_CMDLINE=""
FORCE=false
RUN_ONLY=false
NO_QEMU=false
NO_KVM=false
USE_EFI=false
SERIAL_CONSOLE=false
DEBUG=false
AUTO_INITRD=true
AUTO_INITRD_FILE=""
USE_DISK=false
DISK_SIZE="5G"
DISK_FILE="${KERNEL_SRC}/disk.qcow2"
DISK_ONLY=false
DISK_FORMAT="qcow2"

# ---- 内核编译配置 ----
KERNEL_CONFIG=""                    # 内核配置文件 (如: defconfig, menuconfig)
KERNEL_JOBS=$(nproc 2>/dev/null || echo 4)  # 并行编译数

# ---- 菜单模式标志 ----
MENU_MODE=false

# ---- 辅助函数: 解析大小 (支持 M, G) ----
parse_size() {
    local input="$1"
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        echo "${input}M"
    else
        echo "$input"
    fi
}

# ---- 内核编译函数 ----
compile_kernel() {
    echo ""
    bold "${CYAN}═══════════ 编译 Linux 内核 ═══════════${NC}"
    echo ""
    
    # 检查是否在源码目录
    if [ ! -f "${KERNEL_SRC}/Makefile" ]; then
        error "当前目录不是 Linux 内核源码目录"
        info "请确保在 Linux 内核源码目录中运行"
        return 1
    fi
    
    # 显示当前配置
    if [ -f "${KERNEL_SRC}/.config" ]; then
        ok "检测到已有配置文件 .config"
    else
        warn "未检测到配置文件，将使用默认配置"
    fi
    
    echo ""
    echo "请选择编译方式:"
    echo "  1) 使用默认配置 (make defconfig) + 编译"
    echo "  2) 使用 menuconfig 配置 + 编译"
    echo "  3) 使用已有 .config + 编译"
    echo "  4) 仅编译 (不清理)"
    echo "  5) 清理并重新编译 (make clean + make)"
    echo "  6) 完全清理 (make mrproper)"
    echo "  0) 返回主菜单"
    echo ""
    
    read -p "请选择 [1]: " compile_choice
    compile_choice=${compile_choice:-1}
    
    case "$compile_choice" in
        0) return 0 ;;
        1) 
            step "使用默认配置..."
            make -C "$KERNEL_SRC" defconfig
            ;;
        2)
            step "启动 menuconfig..."
            make -C "$KERNEL_SRC" menuconfig
            ;;
        3)
            if [ ! -f "${KERNEL_SRC}/.config" ]; then
                error "没有 .config 文件"
                return 1
            fi
            ok "使用已有配置"
            ;;
        5)
            step "清理旧的编译文件..."
            make -C "$KERNEL_SRC" clean
            ;;
        6)
            step "完全清理 (mrproper)..."
            make -C "$KERNEL_SRC" mrproper
            ok "清理完成"
            read -p "按 Enter 继续..."
            return 0
            ;;
        *)
            error "无效选项"
            return 1
            ;;
    esac
    
    # 询问并行编译数
    echo ""
    read -p "并行编译数 (默认: $KERNEL_JOBS): " input_jobs
    if [ -n "$input_jobs" ]; then
        KERNEL_JOBS="$input_jobs"
    fi
    
    echo ""
    info "开始编译内核 (使用 $KERNEL_JOBS 个并行任务)..."
    echo -e "${YELLOW}这可能需要几分钟到几十分钟，请耐心等待...${NC}"
    echo ""
    
    # 编译内核
    local start_time=$(date +%s)
    
    if make -C "$KERNEL_SRC" -j"$KERNEL_JOBS" bzImage; then
        local end_time=$(date +%s)
        local elapsed=$((end_time - start_time))
        local minutes=$((elapsed / 60))
        local seconds=$((elapsed % 60))
        
        echo ""
        ok "内核编译成功！"
        info "用时: ${minutes}分${seconds}秒"
        
        if [ -f "$KERNEL_BZIMAGE" ]; then
            local size=$(du -h "$KERNEL_BZIMAGE" | cut -f1)
            ok "内核文件: $KERNEL_BZIMAGE ($size)"
        fi
        
        # 编译模块（可选）
        echo ""
        read -p "是否编译内核模块? (y/N): " build_modules
        if [[ "$build_modules" =~ ^[Yy]$ ]]; then
            step "编译内核模块..."
            make -C "$KERNEL_SRC" -j"$KERNEL_JOBS" modules
            ok "内核模块编译完成"
            
            # 安装模块到临时目录（可选）
            echo ""
            read -p "是否安装模块到临时目录? (y/N): " install_modules
            if [[ "$install_modules" =~ ^[Yy]$ ]]; then
                local mod_dir="${KERNEL_SRC}/_modules_install"
                mkdir -p "$mod_dir"
                step "安装模块到 $mod_dir ..."
                make -C "$KERNEL_SRC" modules_install INSTALL_MOD_PATH="$mod_dir"
                ok "模块安装完成"
                info "模块位置: $mod_dir"
            fi
        fi
    else
        error "内核编译失败！"
        return 1
    fi
    
    echo ""
    read -p "按 Enter 继续..."
    return 0
}

# ---- 显示菜单 ----
show_menu() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                              ║"
    echo "║     🐧 Linux 内核启动工具 - 交互式菜单                       ║"
    echo "║                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${BOLD}当前状态:${NC}"
    if [ -f "$KERNEL_BZIMAGE" ]; then
        local size=$(du -h "$KERNEL_BZIMAGE" 2>/dev/null | cut -f1)
        echo -e "  ${GREEN}✓${NC} 内核: 已编译 (${size})"
    else
        echo -e "  ${RED}✗${NC} 内核: 未编译"
    fi
    if [ -f "$OUTPUT_ISO" ]; then
        local size=$(du -h "$OUTPUT_ISO" 2>/dev/null | cut -f1)
        echo -e "  ${GREEN}✓${NC} ISO: 已生成 (${size})"
    else
        echo -e "  ${YELLOW}○${NC} ISO: 未生成"
    fi
    if [ -f "$DISK_FILE" ]; then
        local size=$(du -h "$DISK_FILE" 2>/dev/null | cut -f1)
        echo -e "  ${GREEN}✓${NC} 硬盘: 已创建 (${size})"
    else
        echo -e "  ${YELLOW}○${NC} 硬盘: 未创建"
    fi
    echo -e "  ${CYAN}ℹ${NC}  CPU: $KERNEL_JOBS 核可用"
    echo ""
    
    echo -e "${BOLD}请选择操作:${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC}) 🔨 编译内核"
    echo -e "  ${GREEN}2${NC}) 📦 构建 ISO 并启动"
    echo -e "  ${GREEN}3${NC}) 💾 构建 ISO + 创建硬盘并启动"
    echo -e "  ${GREEN}4${NC}) 💾 构建 ISO + 使用已有硬盘启动"
    echo -e "  ${GREEN}5${NC}) 📀 仅构建 ISO (不启动)"
    echo -e "  ${GREEN}6${NC}) 💾 仅创建虚拟硬盘"
    echo -e "  ${GREEN}7${NC}) ▶️  运行已有的 ISO"
    echo -e "  ${GREEN}8${NC}) ⚙️  高级设置"
    echo -e "  ${GREEN}9${NC}) 📊 查看文件状态"
    echo -e "  ${RED}0${NC}) 🚪 退出"
    echo ""
}

# =============================================================================
# 核心函数
# =============================================================================

# 构建 ISO (通用函数)
build_iso() {
    local force="$1"
    local no_qemu="$2"
    local use_disk="$3"
    local disk_file="$4"
    local serial="$5"
    
    # 检查依赖
    if ! command -v xorriso &>/dev/null || ! command -v grub-mkimage &>/dev/null; then
        error "缺少依赖，请安装: sudo apt install xorriso grub-pc-bin"
        return 1
    fi
    
    # 检查内核
    if [ ! -f "$KERNEL_BZIMAGE" ]; then
        error "未找到内核文件: $KERNEL_BZIMAGE"
        echo ""
        info "请先编译内核:"
        echo "  选择菜单选项 ${GREEN}1${NC} 编译内核"
        echo "  或手动执行: make -j\$(nproc)"
        return 1
    fi
    
    # 强制覆盖
    if [ "$force" = true ] && [ -f "$OUTPUT_ISO" ]; then
        rm -f "$OUTPUT_ISO"
    fi
    
    if [ -f "$OUTPUT_ISO" ] && [ "$force" != true ]; then
        error "ISO 已存在: $OUTPUT_ISO"
        info "使用 -f 强制覆盖"
        return 1
    fi
    
    # 处理 initramfs
    local initramfs_file=""
    if [ -n "$INITRAMFS" ] && [ -f "$INITRAMFS" ]; then
        initramfs_file="$INITRAMFS"
    elif [ -f "${KERNEL_SRC}/usr/initramfs_data.cpio" ]; then
        local cpio_size=$(stat -c%s "${KERNEL_SRC}/usr/initramfs_data.cpio" 2>/dev/null || echo 0)
        if [ "$cpio_size" -gt 1024 ]; then
            initramfs_file="${KERNEL_SRC}/usr/initramfs_data.cpio"
            ok "使用内核内置 initramfs"
        fi
    elif [ "$AUTO_INITRD" = true ]; then
        info "自动生成 BusyBox initramfs..."
        local busybox_dir="$(mktemp -d)"
        mkdir -p "$busybox_dir"/{bin,dev,etc,lib,proc,sys,tmp}
        ln -s /bin/busybox "$busybox_dir/bin/sh"
        cp "$(which busybox)" "$busybox_dir/bin/"
        cat > "$busybox_dir/init" << 'EOF'
#!/bin/sh
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev
echo "=== BusyBox initramfs 启动成功 ==="
exec /bin/busybox sh
EOF
        chmod +x "$busybox_dir/init"
        AUTO_INITRD_FILE="$(mktemp)"
        (cd "$busybox_dir" && find . -print0 | cpio --null -o --format=newc > "$AUTO_INITRD_FILE")
        rm -rf "$busybox_dir"
        initramfs_file="$AUTO_INITRD_FILE"
        ok "自动生成 initramfs 完成"
    fi
    
    # 创建 ISO 目录
    TEMP_DIR="$(mktemp -d)"
    ISO_DIR="${TEMP_DIR}/iso-root"
    mkdir -p "$ISO_DIR"/boot/grub
    
    # 复制内核
    cp "$KERNEL_BZIMAGE" "$ISO_DIR/boot/vmlinuz"
    ok "复制内核"
    
    # 复制 initramfs
    if [ -n "$initramfs_file" ] && [ -f "$initramfs_file" ]; then
        cp "$initramfs_file" "$ISO_DIR/boot/initrd.img"
        ok "复制 initramfs"
        INITRD_LINE="initrd /boot/initrd.img"
    else
        INITRD_LINE=""
    fi
    
    # 生成 GRUB 配置
    CMDLINE=""
    if [ "$serial" = true ]; then
        CMDLINE="console=ttyS0,115200 earlyprintk=serial"
    else
        CMDLINE="console=tty0"
    fi
    
    if [ "$use_disk" = true ] && [ -f "$disk_file" ]; then
        CMDLINE="$CMDLINE root=/dev/sda1"
        info "添加 root=/dev/sda1 (硬盘模式)"
    fi
    
    if [ -n "$QEMU_CMDLINE" ]; then
        CMDLINE="$CMDLINE $QEMU_CMDLINE"
    fi
    
    cat > "$ISO_DIR/boot/grub/grub.cfg" << 'GRUB_EOF'
set timeout=5
set default=0
insmod all_video
insmod part_msdos
insmod ext2
insmod gzio
menuentry "Linux Custom Kernel" {
    linux /boot/vmlinuz
GRUB_EOF

    if [ -n "$INITRD_LINE" ]; then
        echo "    $INITRD_LINE" >> "$ISO_DIR/boot/grub/grub.cfg"
    fi

    cat >> "$ISO_DIR/boot/grub/grub.cfg" << GRUB_EOF
    echo "Booting custom Linux kernel..."
}
GRUB_EOF

    if [ -n "$CMDLINE" ]; then
        sed -i "s|linux /boot/vmlinuz|linux /boot/vmlinuz $CMDLINE|" "$ISO_DIR/boot/grub/grub.cfg"
    fi
    
    # UEFI 支持
    if [ "$USE_EFI" = true ]; then
        mkdir -p "$ISO_DIR/EFI/BOOT"
        cp "$ISO_DIR/boot/grub/grub.cfg" "$ISO_DIR/EFI/BOOT/"
    fi
    
    # 创建 GRUB BIOS 启动
    BIOS_BOOT_IMG="/usr/lib/grub/i386-pc/cdboot.img"
    if [ ! -f "$BIOS_BOOT_IMG" ]; then
        error "未找到 GRUB BIOS 启动镜像"
        return 1
    fi
    
    # 生成 core.img
    CORE_IMG="${TEMP_DIR}/core.img"
    grub-mkimage -O i386-pc -o "$CORE_IMG" -p /boot/grub \
        iso9660 biosdisk part_msdos normal configfile boot linux \
        search search_fs_file echo test gzio all_video 2>/dev/null
    
    if [ ! -f "$CORE_IMG" ]; then
        error "grub-mkimage 执行失败"
        return 1
    fi
    
    cat "$BIOS_BOOT_IMG" "$CORE_IMG" > "$ISO_DIR/boot/grub/eltorito.img"
    
    # xorriso 参数
    XORRISO_OPTS=(
        "-b" "boot/grub/eltorito.img"
        "-no-emul-boot"
        "-boot-load-size" "4"
        "-boot-info-table"
        "--grub2-boot-info"
    )
    
    # UEFI 模式
    if [ "$USE_EFI" = true ]; then
        EFI_BINARY="${TEMP_DIR}/BOOTx64.EFI"
        if command -v grub-mkstandalone &>/dev/null; then
            grub-mkstandalone -O x86_64-efi -o "$EFI_BINARY" -p "/boot/grub" \
                boot/grub/grub.cfg="$ISO_DIR/boot/grub/grub.cfg" 2>/dev/null
        fi
        if [ ! -f "$EFI_BINARY" ]; then
            grub-mkimage -O x86_64-efi -o "$EFI_BINARY" -p "/boot/grub" \
                iso9660 part_gpt part_msdos ext2 fat normal configfile \
                boot linux chain search search_fs_file 2>/dev/null
        fi
        
        if [ -f "$EFI_BINARY" ]; then
            EFI_IMG="$ISO_DIR/boot/grub/efi.img"
            dd if=/dev/zero of="$EFI_IMG" bs=1K count=4096 2>/dev/null
            mkfs.vfat "$EFI_IMG" 2>/dev/null
            mmd -i "$EFI_IMG" ::/EFI 2>/dev/null
            mmd -i "$EFI_IMG" ::/EFI/BOOT 2>/dev/null
            mcopy -i "$EFI_IMG" "$EFI_BINARY" ::/EFI/BOOT/BOOTx64.EFI 2>/dev/null
            XORRISO_OPTS+=(
                "-eltorito-alt-boot"
                "-e" "boot/grub/efi.img"
                "-no-emul-boot"
                "-isohybrid-gpt-basdat"
            )
        fi
    fi
    
    # 生成 ISO
    xorriso -as mkisofs "${XORRISO_OPTS[@]}" -o "$OUTPUT_ISO" "$ISO_DIR" 2>/dev/null
    
    if [ ! -f "$OUTPUT_ISO" ]; then
        error "ISO 生成失败"
        return 1
    fi
    
    ok "ISO 生成成功: $OUTPUT_ISO ($(du -h "$OUTPUT_ISO" | cut -f1))"
    return 0
}

# 启动 QEMU
run_qemu() {
    local use_disk="$1"
    local disk_file="$2"
    local serial="$3"
    
    if [ ! -f "$OUTPUT_ISO" ]; then
        error "ISO 文件不存在: $OUTPUT_ISO"
        return 1
    fi
    
    QEMU_ARGS=()
    QEMU_ARGS+=("-m" "$QEMU_MEM")
    QEMU_ARGS+=("-smp" "$QEMU_SMP")
    QEMU_ARGS+=("-cdrom" "$OUTPUT_ISO")
    QEMU_ARGS+=("-netdev" "user,id=net0")
    QEMU_ARGS+=("-device" "e1000,netdev=net0")
    QEMU_ARGS+=("-usb")
    QEMU_ARGS+=("-rtc" "base=localtime")
    
    if [ "$use_disk" = true ] && [ -f "$disk_file" ]; then
        QEMU_ARGS+=("-drive" "file=$disk_file,format=$DISK_FORMAT")
        ok "挂载硬盘: $disk_file"
    fi
    
    if [ "$serial" = true ]; then
        QEMU_ARGS+=("-nographic")
    else
        QEMU_ARGS+=("-vga" "std")
    fi
    
    if [ "$NO_KVM" = false ] && [ -e /dev/kvm ]; then
        QEMU_ARGS+=("-enable-kvm")
    fi
    
    if [ "$USE_EFI" = true ]; then
        for path in /usr/share/ovmf/OVMF.fd /usr/share/qemu/ovmf-x86_64.bin \
            /usr/share/edk2-ovmf/x64/OVMF_CODE.fd /usr/share/edk2-ovmf/OVMF_CODE.fd; do
            if [ -f "$path" ]; then
                QEMU_ARGS+=("-bios" "$path")
                break
            fi
        done
    fi
    
    ok "启动 QEMU (内存: $QEMU_MEM, CPU: $QEMU_SMP)"
    if [ "$serial" = true ]; then
        info "按 Ctrl+A X 退出"
    else
        info "关闭窗口即可退出"
    fi
    
    qemu-system-x86_64 "${QEMU_ARGS[@]}"
}

# ---- 菜单选项函数 ----
menu_compile_kernel() {
    compile_kernel
}

menu_build_iso() {
    echo -e "${CYAN}[执行]${NC} 构建 ISO 并启动"
    echo ""
    if build_iso true false false "" false; then
        run_qemu false "" false
    fi
    echo ""
    read -p "按 Enter 返回菜单..."
}

menu_build_with_disk() {
    echo -e "${CYAN}[执行]${NC} 构建 ISO + 创建硬盘并启动"
    echo ""
    read -p "请输入硬盘大小 (如: 512M, 1G, 5G, 默认: 5G): " input_size
    input_size=${input_size:-5G}
    DISK_SIZE=$(parse_size "$input_size")
    echo -e "使用大小: $DISK_SIZE"
    
    echo "选择启动模式:"
    echo "  1) 图形窗口 (推荐)"
    echo "  2) 串口控制台"
    read -p "请选择 [1]: " display_choice
    display_choice=${display_choice:-1}
    
    local serial_mode=false
    if [ "$display_choice" = "2" ]; then
        serial_mode=true
    fi
    
    # 创建硬盘
    if [ ! -f "$DISK_FILE" ]; then
        info "创建硬盘: $DISK_FILE ($DISK_SIZE)"
        qemu-img create -f "$DISK_FORMAT" "$DISK_FILE" "$DISK_SIZE" 2>/dev/null
        ok "硬盘创建成功"
    else
        ok "使用已有硬盘: $DISK_FILE"
    fi
    
    if build_iso true false true "$DISK_FILE" "$serial_mode"; then
        run_qemu true "$DISK_FILE" "$serial_mode"
    fi
    echo ""
    read -p "按 Enter 返回菜单..."
}

menu_build_with_existing_disk() {
    echo -e "${CYAN}[执行]${NC} 构建 ISO + 使用已有硬盘启动"
    echo ""
    
    if [ ! -f "$DISK_FILE" ]; then
        echo -e "${RED}[错误]${NC} 虚拟硬盘不存在: $DISK_FILE"
        read -p "按 Enter 返回菜单..."
        return
    fi
    
    echo "选择启动模式:"
    echo "  1) 图形窗口 (推荐)"
    echo "  2) 串口控制台"
    read -p "请选择 [1]: " display_choice
    display_choice=${display_choice:-1}
    
    local serial_mode=false
    if [ "$display_choice" = "2" ]; then
        serial_mode=true
    fi
    
    if build_iso true false true "$DISK_FILE" "$serial_mode"; then
        run_qemu true "$DISK_FILE" "$serial_mode"
    fi
    echo ""
    read -p "按 Enter 返回菜单..."
}

menu_build_iso_only() {
    echo -e "${CYAN}[执行]${NC} 仅构建 ISO (不启动 QEMU)"
    echo ""
    build_iso true true false "" false
    echo ""
    read -p "按 Enter 返回菜单..."
}

menu_create_disk() {
    echo -e "${CYAN}[执行]${NC} 仅创建虚拟硬盘"
    echo ""
    read -p "请输入硬盘大小 (如: 512M, 1G, 5G, 默认: 5G): " input_size
    input_size=${input_size:-5G}
    DISK_SIZE=$(parse_size "$input_size")
    echo -e "使用大小: $DISK_SIZE"
    
    if [ -f "$DISK_FILE" ]; then
        echo -e "${YELLOW}[警告]${NC} 硬盘已存在: $DISK_FILE"
        read -p "是否覆盖? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "已取消"
            read -p "按 Enter 返回菜单..."
            return
        fi
        rm -f "$DISK_FILE"
    fi
    
    info "创建硬盘: $DISK_FILE ($DISK_SIZE)"
    qemu-img create -f "$DISK_FORMAT" "$DISK_FILE" "$DISK_SIZE" 2>/dev/null
    ok "硬盘创建成功: $DISK_FILE"
    echo ""
    read -p "按 Enter 返回菜单..."
}

menu_run_iso() {
    echo -e "${CYAN}[执行]${NC} 运行已有的 ISO"
    echo ""
    
    if [ ! -f "$OUTPUT_ISO" ]; then
        echo -e "${RED}[错误]${NC} ISO 文件不存在: $OUTPUT_ISO"
        read -p "按 Enter 返回菜单..."
        return
    fi
    
    echo "选择启动模式:"
    echo "  1) 图形窗口 (推荐)"
    echo "  2) 串口控制台"
    read -p "请选择 [1]: " display_choice
    display_choice=${display_choice:-1}
    
    local serial_mode=false
    if [ "$display_choice" = "2" ]; then
        serial_mode=true
    fi
    
    local use_disk=false
    if [ -f "$DISK_FILE" ]; then
        echo "检测到虚拟硬盘，是否挂载?"
        echo "  1) 是 (挂载硬盘)"
        echo "  2) 否 (仅 CD-ROM)"
        read -p "请选择 [1]: " disk_choice
        disk_choice=${disk_choice:-1}
        if [ "$disk_choice" = "1" ]; then
            use_disk=true
        fi
    fi
    
    run_qemu "$use_disk" "$DISK_FILE" "$serial_mode"
    echo ""
    read -p "按 Enter 返回菜单..."
}

menu_advanced() {
    echo -e "${BOLD}${CYAN}═══════════ 高级设置 ═══════════${NC}"
    echo ""
    echo "当前设置:"
    echo "  内存: $QEMU_MEM"
    echo "  CPU 核心: $QEMU_SMP"
    echo "  编译并行数: $KERNEL_JOBS"
    echo "  启动模式: $([ "$SERIAL_CONSOLE" = true ] && echo "串口控制台" || echo "图形窗口")"
    echo "  自动生成 initramfs: $([ "$AUTO_INITRD" = true ] && echo "开启" || echo "关闭")"
    echo "  KVM 加速: $([ "$NO_KVM" = false ] && echo "开启" || echo "关闭")"
    echo "  启动模式: $([ "$USE_EFI" = true ] && echo "UEFI" || echo "BIOS")"
    echo ""
    echo "  a) 修改内存大小 (当前: $QEMU_MEM)"
    echo "  b) 修改 CPU 核心数 (当前: $QEMU_SMP)"
    echo "  c) 修改编译并行数 (当前: $KERNEL_JOBS)"
    echo "  d) 切换启动模式 (图形/串口)"
    echo "  e) 切换 KVM 加速"
    echo "  f) 切换 EFI/UEFI"
    echo "  g) 切换自动生成 initramfs"
    echo "  0) 返回主菜单"
    echo ""
    read -p "请选择: " adv_choice
    
    case "$adv_choice" in
        a|A)
            read -p "输入内存大小 (如: 512M, 1G, 2G): " new_mem
            if [ -n "$new_mem" ]; then
                QEMU_MEM=$(parse_size "$new_mem")
                echo -e "${GREEN}已设置内存为: $QEMU_MEM${NC}"
            fi
            read -p "按 Enter 继续..."
            ;;
        b|B)
            read -p "输入 CPU 核心数 (如: 1, 2, 4): " new_smp
            if [ -n "$new_smp" ]; then
                QEMU_SMP="$new_smp"
                echo -e "${GREEN}已设置 CPU 核心数为: $QEMU_SMP${NC}"
            fi
            read -p "按 Enter 继续..."
            ;;
        c|C)
            read -p "输入编译并行数 (如: 2, 4, 8): " new_jobs
            if [ -n "$new_jobs" ]; then
                KERNEL_JOBS="$new_jobs"
                echo -e "${GREEN}已设置编译并行数为: $KERNEL_JOBS${NC}"
            fi
            read -p "按 Enter 继续..."
            ;;
        d|D)
            SERIAL_CONSOLE=$([ "$SERIAL_CONSOLE" = true ] && echo false || echo true)
            echo -e "${GREEN}切换到: $([ "$SERIAL_CONSOLE" = true ] && echo "串口控制台" || echo "图形窗口")${NC}"
            read -p "按 Enter 继续..."
            ;;
        e|E)
            NO_KVM=$([ "$NO_KVM" = false ] && echo true || echo false)
            echo -e "${GREEN}KVM 加速: $([ "$NO_KVM" = false ] && echo "开启" || echo "关闭")${NC}"
            read -p "按 Enter 继续..."
            ;;
        f|F)
            USE_EFI=$([ "$USE_EFI" = true ] && echo false || echo true)
            echo -e "${GREEN}切换到: $([ "$USE_EFI" = true ] && echo "UEFI" || echo "BIOS")${NC}"
            read -p "按 Enter 继续..."
            ;;
        g|G)
            AUTO_INITRD=$([ "$AUTO_INITRD" = true ] && echo false || echo true)
            echo -e "${GREEN}自动生成 initramfs: $([ "$AUTO_INITRD" = true ] && echo "开启" || echo "关闭")${NC}"
            read -p "按 Enter 继续..."
            ;;
        0) return ;;
        *) echo -e "${RED}无效选项${NC}"; read -p "按 Enter 继续..." ;;
    esac
    menu_advanced
}

menu_status() {
    echo -e "${BOLD}${CYAN}═══════════ 文件状态 ═══════════${NC}"
    echo ""
    
    echo -e "${BOLD}内核:${NC}"
    if [ -f "$KERNEL_BZIMAGE" ]; then
        local size=$(du -h "$KERNEL_BZIMAGE" | cut -f1)
        echo -e "  ${GREEN}✓${NC} $KERNEL_BZIMAGE ($size)"
    else
        echo -e "  ${RED}✗${NC} 未找到内核文件"
        echo "    请选择菜单选项 1 编译内核"
    fi
    echo ""
    
    echo -e "${BOLD}ISO 文件:${NC}"
    if [ -f "$OUTPUT_ISO" ]; then
        local size=$(du -h "$OUTPUT_ISO" | cut -f1)
        echo -e "  ${GREEN}✓${NC} $OUTPUT_ISO ($size)"
    else
        echo -e "  ${YELLOW}○${NC} 未生成 ISO"
    fi
    echo ""
    
    echo -e "${BOLD}虚拟硬盘:${NC}"
    if [ -f "$DISK_FILE" ]; then
        local size=$(du -h "$DISK_FILE" | cut -f1)
        echo -e "  ${GREEN}✓${NC} $DISK_FILE ($size)"
    else
        echo -e "  ${YELLOW}○${NC} 未创建虚拟硬盘"
    fi
    echo ""
    
    echo -e "${BOLD}依赖检查:${NC}"
    local deps=("xorriso" "grub-mkimage" "qemu-system-x86_64" "qemu-img" "busybox" "cpio" "make" "gcc")
    for cmd in "${deps[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $cmd"
        else
            echo -e "  ${RED}✗${NC} $cmd"
        fi
    done
    echo ""
    
    echo -e "${BOLD}内核配置:${NC}"
    if [ -f "${KERNEL_SRC}/.config" ]; then
        echo -e "  ${GREEN}✓${NC} 已配置 (.config 存在)"
    else
        echo -e "  ${YELLOW}○${NC} 未配置"
    fi
    echo ""
    
    read -p "按 Enter 返回菜单..."
}

# =============================================================================
# 命令行参数解析
# =============================================================================
usage() {
    bold "用法: $0 [选项]"
    echo ""
    echo "不带参数运行将进入交互式菜单"
    echo ""
    echo "选项:"
    echo "  -b, --bzimage <文件>     指定内核 bzImage 路径"
    echo "  -i, --initrd <文件>      指定 initramfs/initrd 路径"
    echo "  -o, --output <文件>      指定输出的 ISO 路径"
    echo "  -m, --mem <大小>         QEMU 内存大小 (默认: 512M)"
    echo "  -s, --smp <CPU数>        QEMU CPU 核心数 (默认: 2)"
    echo "  -c, --cmdline <参数>     附加内核启动参数"
    echo "  -e, --efi                使用 UEFI 启动"
    echo "  -k, --no-kvm             禁用 KVM 加速"
    echo "  -r, --run-only           仅运行已有的 ISO"
    echo "  -n, --no-qemu            仅生成 ISO，不启动 QEMU"
    echo "  -f, --force              强制覆盖已有 ISO"
    echo "  -d, --debug              调试模式"
    echo "  -g, --graphic            使用图形窗口 (默认)"
    echo "      --serial             使用串口控制台"
    echo "      --no-auto-initrd     禁用自动生成 BusyBox initramfs"
    echo "      --disk <大小>        创建/使用虚拟硬盘"
    echo "      --disk-file <文件>   指定硬盘文件路径"
    echo "      --disk-only          仅创建硬盘，不启动 QEMU"
    echo "  -h, --help               显示此帮助"
    echo ""
    echo "示例:"
    echo "  $0                        # 进入交互式菜单"
    echo "  $0 --disk 5G              # 直接构建 ISO + 硬盘并启动"
    echo "  $0 -r                     # 直接运行已有 ISO"
}

# ---- 如果没有任何参数，进入菜单模式 ----
if [ $# -eq 0 ]; then
    MENU_MODE=true
fi

# ---- 解析命令行参数 ----
while [ $# -gt 0 ]; do
    case "$1" in
        -b|--bzimage)
            KERNEL_BZIMAGE="$2"; shift 2 ;;
        -i|--initrd)
            INITRAMFS="$2"; shift 2 ;;
        -o|--output)
            OUTPUT_ISO="$2"; shift 2 ;;
        -m|--mem)
            QEMU_MEM=$(parse_size "$2"); shift 2 ;;
        -s|--smp)
            QEMU_SMP="$2"; shift 2 ;;
        -c|--cmdline)
            QEMU_CMDLINE="$2"; shift 2 ;;
        -e|--efi)
            USE_EFI=true; shift ;;
        -k|--no-kvm)
            NO_KVM=true; shift ;;
        -r|--run-only)
            RUN_ONLY=true; shift ;;
        -n|--no-qemu)
            NO_QEMU=true; shift ;;
        -f|--force)
            FORCE=true; shift ;;
        -d|--debug)
            DEBUG=true; shift ;;
        -g|--graphic)
            SERIAL_CONSOLE=false; shift ;;
        --serial)
            SERIAL_CONSOLE=true; shift ;;
        --no-auto-initrd)
            AUTO_INITRD=false; shift ;;
        --disk)
            USE_DISK=true
            DISK_SIZE=$(parse_size "$2")
            shift 2 ;;
        --disk-file)
            DISK_FILE="$2"
            shift 2 ;;
        --disk-only)
            DISK_ONLY=true
            USE_DISK=true
            if [ -n "$2" ] && [[ "$2" =~ ^[0-9]+[GgMm]?$ ]]; then
                DISK_SIZE=$(parse_size "$2")
                shift
            fi
            shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            error "未知参数: $1"
            usage; exit 1 ;;
    esac
done

# ---- 如果进入菜单模式，显示菜单循环 ----
if [ "$MENU_MODE" = true ]; then
    while true; do
        show_menu
        read -p "请输入选项 [0-9]: " choice
        case "$choice" in
            1) menu_compile_kernel ;;
            2) menu_build_iso ;;
            3) menu_build_with_disk ;;
            4) menu_build_with_existing_disk ;;
            5) menu_build_iso_only ;;
            6) menu_create_disk ;;
            7) menu_run_iso ;;
            8) menu_advanced ;;
            9) menu_status ;;
            0) 
                echo -e "${GREEN}再见！${NC}"
                exit 0 
                ;;
            *) 
                echo -e "${RED}无效选项，请重新选择${NC}"
                sleep 1
                ;;
        esac
    done
fi

# =============================================================================
# 命令行模式 (不进入菜单时执行)
# =============================================================================

# 创建硬盘
if [ "$USE_DISK" = true ] && [ "$DISK_ONLY" = true ]; then
    if ! command -v qemu-img &>/dev/null; then
        error "qemu-img 未安装"
        exit 1
    fi
    info "创建硬盘: $DISK_FILE ($DISK_SIZE)"
    qemu-img create -f "$DISK_FORMAT" "$DISK_FILE" "$DISK_SIZE" 2>/dev/null
    ok "硬盘创建完成: $DISK_FILE"
    exit 0
fi

# 构建并启动
if [ "$RUN_ONLY" = true ]; then
    if [ ! -f "$OUTPUT_ISO" ]; then
        error "ISO 不存在: $OUTPUT_ISO"
        exit 1
    fi
    run_qemu "$USE_DISK" "$DISK_FILE" "$SERIAL_CONSOLE"
else
    if build_iso "$FORCE" "$NO_QEMU" "$USE_DISK" "$DISK_FILE" "$SERIAL_CONSOLE"; then
        if [ "$NO_QEMU" != true ]; then
            run_qemu "$USE_DISK" "$DISK_FILE" "$SERIAL_CONSOLE"
        fi
    fi
fi

exit 0
