#!/bin/bash
# =============================================================================
# Linux 内核快速启动工具 (基于 QEMU + BusyBox)
# 支持终端和图形双模式，内置 initramfs 自动生成
# =============================================================================

set -e

# ---- 颜色 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
bold()  { echo -e "${BOLD}$*${NC}"; }

# ---- 默认配置 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_SRC="$SCRIPT_DIR"
KERNEL_BZIMAGE="${KERNEL_SRC}/arch/x86_64/boot/bzImage"
[ ! -f "$KERNEL_BZIMAGE" ] && KERNEL_BZIMAGE="${KERNEL_SRC}/arch/x86/boot/bzImage"

QEMU_MEM="2G"
QEMU_SMP="2"
SERIAL_CONSOLE=false
NO_KVM=false
INITRAMFS_PATH=""
KERNEL_JOBS=$(nproc 2>/dev/null || echo 4)

# ---- 检测内核版本 ----
detect_kernel_version() {
    local version_file="${KERNEL_SRC}/Makefile"
    [ ! -f "$version_file" ] && echo "未知" && return 1
    local version=$(grep -E "^VERSION\s*=" "$version_file" 2>/dev/null | awk '{print $3}' | head -1)
    local patchlevel=$(grep -E "^PATCHLEVEL\s*=" "$version_file" 2>/dev/null | awk '{print $3}' | head -1)
    local sublevel=$(grep -E "^SUBLEVEL\s*=" "$version_file" 2>/dev/null | awk '{print $3}' | head -1)
    local extraversion=$(grep -E "^EXTRAVERSION\s*=" "$version_file" 2>/dev/null | awk '{print $3}' | head -1)
    local ver_str="${version}.${patchlevel}"
    [ -n "$sublevel" ] && ver_str="${ver_str}.${sublevel}"
    [ -n "$extraversion" ] && ver_str="${ver_str}${extraversion}"
    echo "$ver_str"
}

# ---- 检测 GCC 版本 ----
detect_gcc_version() {
    if command -v gcc &>/dev/null; then
        gcc --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1
    else
        echo "未安装"
    fi
}

# ---- 检查 GCC 兼容性 ----
check_gcc_compatibility() {
    local kernel_ver=$(detect_kernel_version)
    local gcc_ver=$(detect_gcc_version)
    
    local gcc_major=$(echo "$gcc_ver" | cut -d. -f1)
    local kernel_major=$(echo "$kernel_ver" | cut -d. -f1)
    local kernel_minor=$(echo "$kernel_ver" | cut -d. -f2)
    
    if [ "$gcc_ver" = "未安装" ]; then
        echo "no_gcc"
        return 1
    fi
    
    if [ "$gcc_major" -lt 9 ]; then
        echo "gcc_too_old"
        return 1
    fi
    
    if [ "$kernel_major" -lt 3 ]; then
        echo "kernel_too_old"
        return 1
    fi
    
    if [ "$kernel_major" -eq 3 ] && [ "$kernel_minor" -lt 10 ]; then
        echo "kernel_too_old"
        return 1
    fi
    
    echo "ok"
    return 0
}

# ---- 添加 QEMU 配置 ----
add_qemu_config() {
    local config_file="${KERNEL_SRC}/.config"
    [ ! -f "$config_file" ] && return 1
    
    echo "" >> "$config_file"
    echo "# QEMU 启动所需配置" >> "$config_file"
    echo "CONFIG_BLK_DEV_SR=y" >> "$config_file"
    echo "CONFIG_ISO9660_FS=y" >> "$config_file"
    echo "CONFIG_EXT4_FS=y" >> "$config_file"
    echo "CONFIG_E1000=y" >> "$config_file"
    echo "CONFIG_VIRTIO_BLK=y" >> "$config_file"
    
    ok "已添加 QEMU 支持配置"
}

parse_size() {
    local input="$1"
    if [[ "$input" =~ ^[0-9]+$ ]]; then echo "${input}M"; else echo "$input"; fi
}

check_dependencies() {
    if ! command -v qemu-system-x86_64 &> /dev/null; then
        error "QEMU not installed"
        echo "安装: sudo apt install qemu-system-x86"
        exit 1
    fi
    if ! command -v busybox &> /dev/null; then
        warn "busybox not found, installing..."
        sudo apt install -y busybox-static > /dev/null 2>&1 || true
        if ! command -v busybox &> /dev/null; then
            error "busybox installation failed"
            exit 1
        fi
    fi
}

create_initramfs() {
    info "生成 initramfs..."
    
    local initrd_dir="./initramfs_build"
    local initramfs_file="$PWD/initramfs.cpio.gz"
    
    rm -rf "$initrd_dir"
    mkdir -p $initrd_dir/{bin,dev,proc,sys,etc,root,tmp,run}
    
    cp $(which busybox) $initrd_dir/bin/
    chmod +x $initrd_dir/bin/busybox
    
    cd $initrd_dir/bin
    for cmd in sh ls cat mount umount echo ps free df dmesg modprobe mkdir; do
        ln -sf busybox $cmd 2>/dev/null || true
    done
    cd - > /dev/null
    
    cat > $initrd_dir/init << 'EOF'
#!/bin/busybox sh

/bin/busybox mount -t proc none /proc
/bin/busybox mount -t sysfs none /sys
/bin/busybox mount -t devtmpfs none /dev
/bin/busybox mount -t tmpfs none /tmp
/bin/busybox mount -t tmpfs none /run

echo ""
echo "=========================================="
echo "  Linux kernel boot successful!"
echo "  Kernel version: $(uname -r)"
echo "  Boot time: $(date)"
echo "=========================================="
echo ""
echo "Available commands: ls, cat, echo, mount, ps, free, df"
echo "Type exit or press Ctrl+D to reboot"
echo ""

exec /bin/busybox sh
EOF
    
    chmod +x $initrd_dir/init
    
    cd $initrd_dir
    find . 2>/dev/null | cpio -o -H newc 2>/dev/null | gzip > "$initramfs_file"
    cd - > /dev/null
    
    rm -rf "$initrd_dir"
    
    if [ -f "$initramfs_file" ] && [ -s "$initramfs_file" ]; then
        INITRAMFS_PATH="$initramfs_file"
        ok "initramfs: $INITRAMFS_PATH ($(du -h $INITRAMFS_PATH | cut -f1))"
    else
        error "initramfs creation failed"
        exit 1
    fi
}

start_qemu() {
    local serial="$1"
    
    if [ ! -f "$KERNEL_BZIMAGE" ]; then
        error "内核文件不存在: $KERNEL_BZIMAGE"
        exit 1
    fi
    
    if [ ! -f "$INITRAMFS_PATH" ]; then
        error "initramfs 不存在: $INITRAMFS_PATH"
        exit 1
    fi
    
    echo ""
    echo "========================================="
    echo "  QEMU Boot Configuration"
    echo "  - Kernel: $KERNEL_BZIMAGE"
    echo "  - initramfs: $INITRAMFS_PATH"
    echo "  - Memory: $QEMU_MEM"
    echo "  - CPU: $QEMU_SMP cores"
    echo "  - Mode: $([ "$serial" = true ] && echo "Serial (ttyS0)" || echo "Graphic (ttyS0 + tty0)")"
    echo "========================================="
    echo ""
    echo "Press Ctrl+A then X to exit"
    echo "========================================="
    echo ""
    
    local qemu_args=(
        -kernel "$KERNEL_BZIMAGE"
        -initrd "$INITRAMFS_PATH"
        -m "$QEMU_MEM"
        -smp cores="$QEMU_SMP"
        -no-reboot
    )
    
    if [ "$NO_KVM" = false ] && [ -e /dev/kvm ]; then
        qemu_args+=("-enable-kvm")
        qemu_args+=("-cpu" "host")
        info "KVM enabled"
    else
        qemu_args+=("-accel" "tcg")
    fi
    
    if [ "$serial" = true ]; then
        qemu_args+=("-nographic")
        qemu_args+=("-append" "console=ttyS0 nokaslr clocksource=tsc")
    else
        qemu_args+=("-vga" "std")
        qemu_args+=("-display" "gtk")
        qemu_args+=("-append" "console=ttyS0 console=tty0 nokaslr clocksource=tsc")
    fi
    
    qemu-system-x86_64 "${qemu_args[@]}"
}

# ---- 编译内核 ----
menu_compile_kernel() {
    echo ""
    bold "${CYAN}═══════ 编译内核 ═══════${NC}"
    
    [ ! -f "${KERNEL_SRC}/Makefile" ] && { error "不是内核源码目录"; read -p "按 Enter..."; return; }
    
    local kernel_ver=$(detect_kernel_version)
    local gcc_ver=$(detect_gcc_version)
    local compat=$(check_gcc_compatibility)
    
    info "内核版本: $kernel_ver"
    info "GCC 版本: $gcc_ver"
    
    if [ "$compat" != "ok" ]; then
        echo ""
        warn "兼容性问题!"
        case "$compat" in
            "no_gcc")
                error "GCC 未安装，请安装: sudo apt install build-essential"
                read -p "按 Enter..."
                return
                ;;
            "gcc_too_old")
                error "GCC 版本 < 9，请升级: sudo apt install gcc-9"
                read -p "按 Enter..."
                return
                ;;
            "kernel_too_old")
                error "内核版本 < 3.10，GCC 9+ 无法编译"
                echo ""
                info "请使用更新的内核:"
                echo "https://www.kernel.org/"
                read -p "按 Enter..."
                return
                ;;
        esac
    fi
    
    echo ""
    echo "  1) defconfig + 编译 (推荐)"
    echo "  2) menuconfig + 编译 (自定义)"
    echo "  3) 使用已有配置 + 编译"
    echo "  4) 仅编译 (不清理)"
    echo "  5) 清理 (make clean)"
    echo "  6) 完全清理 (make mrproper)"
    echo "  0) 返回"
    read -p "选择 [1]: " ch
    ch=${ch:-1}
    
    case "$ch" in
        0) return ;;
        1) 
            info "生成默认配置..."
            make -C "$KERNEL_SRC" defconfig
            add_qemu_config
            ;;
        2) 
            make -C "$KERNEL_SRC" menuconfig || {
                error "menuconfig 失败，安装: sudo apt install libncurses-dev"
                read -p "按 Enter..."
                return
            }
            ;;
        3) 
            [ -f "${KERNEL_SRC}/.config" ] || { error "无 .config"; read -p "按 Enter..."; return; }
            ok "使用已有配置"
            ;;
        5) 
            make -C "$KERNEL_SRC" clean
            read -p "按 Enter..."
            return
            ;;
        6) 
            make -C "$KERNEL_SRC" mrproper
            ok "完全清理完成"
            read -p "按 Enter..."
            return
            ;;
        *) error "无效"; read -p "按 Enter..."; return ;;
    esac
    
    read -p "并行数 [${KERNEL_JOBS}]: " jobs
    KERNEL_JOBS=${jobs:-$KERNEL_JOBS}
    
    info "编译内核 (使用 $KERNEL_JOBS 并行)..."
    local start=$(date +%s)
    
    if make -C "$KERNEL_SRC" -j"$KERNEL_JOBS" bzImage; then
        local elapsed=$(($(date +%s) - start))
        ok "编译成功！用时: $((elapsed/60))分$((elapsed%60))秒"
        ok "内核: $KERNEL_BZIMAGE ($(du -h "$KERNEL_BZIMAGE" | cut -f1))"
    else
        error "编译失败"
        echo ""
        info "常见问题:"
        echo "  1. 缺少依赖: sudo apt install build-essential libncurses-dev"
        echo "  2. 需要配置: make menuconfig"
        echo "  3. 查看日志: make -j1 V=1"
    fi
    read -p "按 Enter..."
}

show_menu() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║     🐧 Linux 内核快速启动工具 (QEMU + BusyBox)               ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    local kernel_ver=$(detect_kernel_version)
    local gcc_ver=$(detect_gcc_version)
    local compat=$(check_gcc_compatibility)
    
    echo -e "${BOLD}状态:${NC}"
    if [ -f "$KERNEL_BZIMAGE" ]; then
        echo -e "  ${GREEN}✓${NC} 内核: 已编译 (v$kernel_ver, $(du -h "$KERNEL_BZIMAGE" | cut -f1))"
    else
        echo -e "  ${YELLOW}○${NC} 内核: 未编译 (源码: v$kernel_ver)"
    fi
    echo -e "  ${CYAN}ℹ${NC}  GCC: $gcc_ver"
    echo -e "  ${CYAN}ℹ${NC}  兼容性: $([ "$compat" = "ok" ] && echo "✅ 良好" || echo "⚠️  $compat")"
    echo ""
    
    echo -e "${BOLD}请选择:${NC}"
    echo "  1) 🔨 编译内核"
    echo "  2) 🚀 启动 (图形模式)"
    echo "  3) 🚀 启动 (终端串口模式)"
    echo "  4) 🔧 重新生成 initramfs"
    echo "  5) ⚙️  高级设置"
    echo "  0) 🚪 退出"
    echo ""
}

menu_start_graphic() {
    check_dependencies
    if [ ! -f "$INITRAMFS_PATH" ]; then
        create_initramfs
    fi
    start_qemu false
    read -p "按 Enter..."
}

menu_start_serial() {
    check_dependencies
    if [ ! -f "$INITRAMFS_PATH" ]; then
        create_initramfs
    fi
    start_qemu true
    read -p "按 Enter..."
}

menu_rebuild_initramfs() {
    create_initramfs
    read -p "按 Enter..."
}

menu_advanced() {
    echo -e "${BOLD}${CYAN}═══════ 高级设置 ═══════${NC}"
    echo ""
    echo "当前设置:"
    echo "  内存: $QEMU_MEM"
    echo "  CPU 核心: $QEMU_SMP"
    echo "  编译并行数: $KERNEL_JOBS"
    echo "  KVM: $([ "$NO_KVM" = false ] && echo "启用" || echo "禁用")"
    echo ""
    
    read -p "内存 [${QEMU_MEM}]: " m && [ -n "$m" ] && QEMU_MEM=$(parse_size "$m")
    read -p "CPU 核心数 [${QEMU_SMP}]: " s && [ -n "$s" ] && QEMU_SMP="$s"
    read -p "编译并行数 [${KERNEL_JOBS}]: " j && [ -n "$j" ] && KERNEL_JOBS="$j"
    read -p "禁用 KVM? (y/N): " k && [[ "$k" =~ ^[Yy]$ ]] && NO_KVM=true || NO_KVM=false
    
    ok "设置已更新"
    read -p "按 Enter..."
}

# ---- 命令行模式 ----
usage() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -g, --graphic         图形模式启动"
    echo "  -s, --serial          串口终端模式启动"
    echo "  -m, --mem <大小>      内存大小 (默认: 2G)"
    echo "  -c, --cores <N>       CPU 核心数 (默认: 2)"
    echo "      --no-kvm          禁用 KVM"
    echo "      --rebuild-initrd  重建 initramfs"
    echo "  -h, --help            显示帮助"
    echo ""
    echo "示例:"
    echo "  $0 -g                 图形模式启动"
    echo "  $0 -s                 串口模式启动"
    echo "  $0 -g -m 4G -c 4      4GB 内存 4 核图形模式"
}

# ---- 主程序 ----
if [ $# -eq 0 ]; then
    while true; do
        show_menu
        read -p "选择 [0-5]: " choice
        case "$choice" in
            1) menu_compile_kernel ;;
            2) menu_start_graphic ;;
            3) menu_start_serial ;;
            4) menu_rebuild_initramfs ;;
            5) menu_advanced ;;
            0) echo -e "${GREEN}再见！${NC}"; exit 0 ;;
            *) echo -e "${RED}无效${NC}"; sleep 1 ;;
        esac
    done
fi

# ---- 命令行解析 ----
ACTION=""
REBUILD_INITRD=false

while [ $# -gt 0 ]; do
    case "$1" in
        -g|--graphic) ACTION="graphic"; shift ;;
        -s|--serial) ACTION="serial"; shift ;;
        -m|--mem) QEMU_MEM=$(parse_size "$2"); shift 2 ;;
        -c|--cores) QEMU_SMP="$2"; shift 2 ;;
        --no-kvm) NO_KVM=true; shift ;;
        --rebuild-initrd) REBUILD_INITRD=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) shift ;;
    esac
done

check_dependencies

if [ "$REBUILD_INITRD" = true ] || [ ! -f "$INITRAMFS_PATH" ]; then
    create_initramfs
fi

case "$ACTION" in
    graphic) start_qemu false ;;
    serial) start_qemu true ;;
    *) 
        if [ -f "$INITRAMFS_PATH" ]; then
            start_qemu false
        else
            create_initramfs
            start_qemu false
        fi
        ;;
esac

exit 0
