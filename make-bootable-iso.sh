#!/bin/bash
# =============================================================================
# make-bootable-iso.sh - 将编译好的Linux内核打包为ISO并用QEMU启动
#                        (自动生成 BusyBox initramfs 支持)
# =============================================================================
# 用法:
#   ./make-bootable-iso.sh                    # 使用默认路径，自动生成 initramfs
#   ./make-bootable-iso.sh --bzImage <路径>   # 指定内核
#   ./make-bootable-iso.sh --initrd <路径>    # 指定 initramfs (禁用自动生成)
#   ./make-bootable-iso.sh --no-auto-initrd   # 禁用自动生成 initramfs
#   ./make-bootable-iso.sh --run-only         # 仅运行已有的ISO
#   ./make-bootable-iso.sh --help             # 显示帮助
#
# 依赖:
#   - xorriso (生成 ISO)
#   - grub-mkimage (来自 grub-pc-bin / grub-efi-amd64-bin)
#   - qemu-system-x86_64
#   - mtools (UEFI 模式需要: sudo apt install mtools dosfstools)
#   - busybox-static, cpio (自动生成 initramfs 时需要)
# =============================================================================

set -e

# ---- 颜色定义 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ---- 工具函数 ----
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
bold()  { echo -e "${BOLD}$*${NC}"; }

# ---- 清理函数 ----
cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
    # 如果自动生成的 initramfs 是临时文件，也清理
    if [ -n "$AUTO_INITRD_FILE" ] && [ -f "$AUTO_INITRD_FILE" ]; then
        rm -f "$AUTO_INITRD_FILE"
    fi
}
trap cleanup EXIT

# ---- 默认配置 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_SRC="$SCRIPT_DIR"
KERNEL_BZIMAGE="${KERNEL_SRC}/arch/x86/boot/bzImage"
INITRAMFS=""                        # 外部 initramfs（cpio 格式）
INITRAMFS_BUILTIN=""                # 内核内置 initramfs 路径（编译时生成的）
OUTPUT_ISO="${KERNEL_SRC}/linux.iso"
QEMU_MEM="512M"
QEMU_SMP="2"
QEMU_CMDLINE=""                     # 额外内核启动参数
FORCE=false
RUN_ONLY=false
NO_QEMU=false                       # 只生成ISO，不启动QEMU
NO_KVM=false                        # 不使用KVM
USE_EFI=false                       # 使用UEFI启动
SERIAL_CONSOLE=true                 # 使用串口控制台
DEBUG=false                         # 调试模式
AUTO_INITRD=true                    # 自动生成 BusyBox initramfs (默认开启)
AUTO_INITRD_FILE=""                 # 自动生成的 initramfs 文件路径

# ---- 解析命令行参数 ----
usage() {
    bold "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -b, --bzimage <文件>     指定内核 bzImage 路径"
    echo "  -i, --initrd <文件>      指定 initramfs/initrd 路径 (cpio 格式)"
    echo "  -o, --output <文件>      指定输出的 ISO 路径"
    echo "  -m, --mem <大小>         QEMU 内存大小 (默认: 512M)"
    echo "  -s, --smp <CPU数>        QEMU CPU 核心数 (默认: 2)"
    echo "  -c, --cmdline <参数>     附加内核启动参数"
    echo "  -e, --efi                使用 UEFI 启动 (默认: BIOS)"
    echo "  -k, --no-kvm             不使用 KVM 加速"
    echo "  -r, --run-only           仅运行已有的 ISO (不重新生成)"
    echo "  -n, --no-qemu            仅生成 ISO，不启动 QEMU"
    echo "  -f, --force              强制覆盖已有 ISO"
    echo "  -d, --debug              调试模式 (显示更多信息)"
    echo "      --no-auto-initrd     禁用自动生成 BusyBox initramfs"
    echo "  -h, --help               显示此帮助"
    echo ""
    echo "示例:"
    echo "  $0                        # 默认: 自动生成 BusyBox initramfs 并启动"
    echo "  $0 -b ../mybzImage -i ../initrd.cpio -m 1G"
    echo "  $0 -e -n                  # 生成 UEFI 启动的 ISO，不启动 QEMU"
    echo "  $0 -r                     # 直接启动已有的 linux.iso"
    echo ""
    echo "依赖检查:"
    for cmd in xorriso qemu-system-x86_64; do
        if command -v "$cmd" &>/dev/null; then
            ok "找到 $cmd"
        else
            error "未找到 $cmd"
        fi
    done
    if command -v grub-mkimage &>/dev/null; then
        ok "找到 grub-mkimage"
    else
        error "未找到 grub-mkimage"
    fi
    if command -v busybox &>/dev/null && command -v cpio &>/dev/null; then
        ok "找到 busybox 和 cpio (可用于自动生成 initramfs)"
    else
        warn "未找到 busybox 或 cpio (自动生成 initramfs 需要)"
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        -b|--bzimage)
            KERNEL_BZIMAGE="$2"; shift 2 ;;
        -i|--initrd)
            INITRAMFS="$2"; shift 2 ;;
        -o|--output)
            OUTPUT_ISO="$2"; shift 2 ;;
        -m|--mem)
            QEMU_MEM="$2"; shift 2 ;;
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
        --no-auto-initrd)
            AUTO_INITRD=false; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            error "未知参数: $1"
            usage; exit 1 ;;
    esac
done

# =============================================================================
# 阶段1: 检查依赖和输入文件
# =============================================================================
bold ""
bold "╔══════════════════════════════════════════════════════════════╗"
bold "║      Linux 内核 ISO 打包 + QEMU 启动工具                    ║"
bold "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ---- 依赖检查 ----
DEP_MISSING=false
for cmd in xorriso qemu-system-x86_64 grub-mkimage; do
    if ! command -v "$cmd" &>/dev/null; then
        error "缺少依赖: $cmd"
        DEP_MISSING=true
    fi
done
# UEFI 模式额外需要 mtools 和 dosfstools
if [ "$USE_EFI" = true ]; then
    for cmd in mcopy mmd mkfs.vfat; do
        if ! command -v "$cmd" &>/dev/null; then
            error "UEFI 模式需要 $cmd (mtools / dosfstools)"
            DEP_MISSING=true
        fi
    done
    if [ "$DEP_MISSING" = true ]; then
        info "安装: sudo apt install mtools dosfstools"
    fi
fi
# 如果启用了自动生成，需要 busybox 和 cpio
if [ "$AUTO_INITRD" = true ]; then
    if ! command -v busybox &>/dev/null; then
        error "自动生成 initramfs 需要 busybox-static"
        DEP_MISSING=true
    fi
    if ! command -v cpio &>/dev/null; then
        error "自动生成 initramfs 需要 cpio"
        DEP_MISSING=true
    fi
    if [ "$DEP_MISSING" = true ]; then
        info "安装: sudo apt install busybox-static cpio"
    fi
fi
if [ "$DEP_MISSING" = true ]; then
    echo ""
    info "安装基础依赖:"
    info "  sudo apt install xorriso grub-pc-bin grub-efi-amd64-bin qemu-system-x86 mtools dosfstools busybox-static cpio"
    exit 1
fi
ok "所有依赖已满足"

# ---- 仅运行已有的 ISO ----
if [ "$RUN_ONLY" = true ]; then
    if [ ! -f "$OUTPUT_ISO" ]; then
        error "ISO 文件不存在: $OUTPUT_ISO"
        info "请先生成 ISO: $0"
        exit 1
    fi
    ok "使用已有 ISO: $OUTPUT_ISO"
    # 直接跳转到 QEMU 启动部分
    goto_qemu=true
else
    goto_qemu=false
fi

# =============================================================================
# 阶段2: 检查内核文件 —— 仅在需要生成 ISO 时
# =============================================================================
if [ "$goto_qemu" = false ]; then
    # 检查 bzImage
    if [ ! -f "$KERNEL_BZIMAGE" ]; then
        error "未找到内核 bzImage: $KERNEL_BZIMAGE"
        echo ""
        info "请先编译内核:"
        info "  cd $KERNEL_SRC"
        info "  make -j\$(nproc)"
        echo ""
        info "或者使用 -b 参数指定 bzImage 路径:"
        info "  $0 -b /path/to/bzImage"
        exit 1
    fi
    ok "找到内核: $KERNEL_BZIMAGE"

    # 如果未指定外部 initramfs，尝试查找内核编译时自带的 initramfs
    if [ -z "$INITRAMFS" ]; then
        if [ -f "${KERNEL_SRC}/usr/initramfs_data.cpio" ]; then
            cpio_size=$(stat -c%s "${KERNEL_SRC}/usr/initramfs_data.cpio" 2>/dev/null || echo 0)
            if [ "$cpio_size" -gt 1024 ]; then
                INITRAMFS_BUILTIN="${KERNEL_SRC}/usr/initramfs_data.cpio"
                ok "找到内核内置 initramfs (${cpio_size} 字节)"
            fi
        fi
    fi

    # ---- 自动生成 BusyBox initramfs ----
    NO_INITRD=false
    if [ -z "$INITRAMFS" ] && [ -z "$INITRAMFS_BUILTIN" ]; then
        if [ "$AUTO_INITRD" = true ]; then
            info "未指定 initramfs，自动生成 BusyBox initramfs..."
            # 创建临时目录
            BUSYBOX_DIR="$(mktemp -d)"
            mkdir -p "$BUSYBOX_DIR"/{bin,dev,etc,lib,proc,sys,tmp}
            ln -s /bin/busybox "$BUSYBOX_DIR/bin/sh"
            cp "$(which busybox)" "$BUSYBOX_DIR/bin/"

            # 创建 init 脚本
            cat > "$BUSYBOX_DIR/init" << 'EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
echo "=== BusyBox initramfs 启动成功 ==="
echo "您现在可以执行命令，例如："
echo "  ls /"
echo "  cat /proc/cpuinfo"
exec /bin/sh
EOF
            chmod +x "$BUSYBOX_DIR/init"

            # 打包为 cpio
            AUTO_INITRD_FILE="$(mktemp)"
            (cd "$BUSYBOX_DIR" && find . -print0 | cpio --null -o --format=newc > "$AUTO_INITRD_FILE")
            # 清理临时目录
            rm -rf "$BUSYBOX_DIR"
            INITRAMFS="$AUTO_INITRD_FILE"
            ok "自动生成 initramfs: $AUTO_INITRD_FILE ($(du -h "$AUTO_INITRD_FILE" | cut -f1))"
            NO_INITRD=false
        else
            NO_INITRD=true
            warn "未找到外部 initramfs，也未能检测到内核内置 initramfs"
            warn "内核可能缺少根文件系统，启动可能 panic！"
            warn "建议使用 -i 指定一个 initramfs，或确保内核配置了 CONFIG_INITRAMFS_SOURCE"
            warn "您也可以启用自动生成 (移除 --no-auto-initrd)"
        fi
    fi

    # ---- 检查 ISO 是否已存在 ----
    if [ -f "$OUTPUT_ISO" ]; then
        if [ "$FORCE" = true ]; then
            warn "覆盖已有 ISO: $OUTPUT_ISO"
            rm -f "$OUTPUT_ISO"
        else
            error "ISO 已存在: $OUTPUT_ISO"
            info "使用 -f 参数强制覆盖，或使用 -r 参数直接启动"
            exit 1
        fi
    fi

    # =============================================================================
    # 阶段3: 构建 ISO
    # =============================================================================
    bold ""
    bold "═══════════ 构建 ISO ═══════════"
    echo ""

    TEMP_DIR="$(mktemp -d)"
    ISO_DIR="${TEMP_DIR}/iso-root"
    mkdir -p "$ISO_DIR"/boot/grub

    # 复制内核
    cp "$KERNEL_BZIMAGE" "$ISO_DIR/boot/vmlinuz"
    ok "复制 bzImage → /boot/vmlinuz"

    # 复制 initramfs（如果有）
    INITRD_USED=""
    if [ -n "$INITRAMFS" ]; then
        if [ ! -f "$INITRAMFS" ]; then
            error "指定的 initramfs 不存在: $INITRAMFS"
            exit 1
        fi
        cp "$INITRAMFS" "$ISO_DIR/boot/initrd.img"
        INITRD_USED="$INITRAMFS"
        ok "复制 initramfs → /boot/initrd.img: $INITRAMFS"
    elif [ -n "$INITRAMFS_BUILTIN" ]; then
        if [ "$DEBUG" = true ]; then
            info "内核内置了 initramfs，无需外部 initrd"
        fi
    else
        warn "未找到 initramfs — 内核需要内置 initramfs 或指定外部 initrd"
        warn "如果内核没有内置 initramfs，启动可能会 panic (无法挂载根文件系统)"
        warn "提示: 用 -i 参数指定 initramfs，或在内核配置中设置 CONFIG_INITRAMFS_SOURCE"
    fi

    # ---- 生成 GRUB 配置文件 ----
    CMDLINE=""
    if [ "$SERIAL_CONSOLE" = true ]; then
        CMDLINE="console=ttyS0,115200 earlyprintk=serial"
    fi

    # 自动添加 root= 仅当 NO_INITRD 为 true 时（即没有 initramfs 且禁用了自动生成）
    if [ "$NO_INITRD" = true ]; then
        if [ -n "$QEMU_CMDLINE" ] && echo "$QEMU_CMDLINE" | grep -q "\broot="; then
            :  # 用户已指定
        else
            warn "未指定 root= 且无 initramfs，自动添加 root=/dev/sr0 (尝试挂载 CD-ROM)"
            warn "这仅用于测试，若内核不支持 iso9660 或没有 /sbin/init，仍将失败"
            CMDLINE="$CMDLINE root=/dev/sr0"
        fi
    fi
    # 添加用户自定义参数（可能覆盖 root）
    if [ -n "$QEMU_CMDLINE" ]; then
        CMDLINE="$CMDLINE $QEMU_CMDLINE"
    fi

    # 处理 initrd 在 grub.cfg 中的引用
    INITRD_LINE=""
    if [ -n "$INITRAMFS" ] || [ -n "$INITRAMFS_BUILTIN" ]; then
        if [ -f "$ISO_DIR/boot/initrd.img" ]; then
            INITRD_LINE="initrd /boot/initrd.img"
        fi
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

    # 添加 initrd 行（如果有的话）
    if [ -n "$INITRD_LINE" ]; then
        echo "    $INITRD_LINE" >> "$ISO_DIR/boot/grub/grub.cfg"
    fi

    # 添加 cmdline 和结束
    cat >> "$ISO_DIR/boot/grub/grub.cfg" << GRUB_EOF
    echo "Booting custom Linux kernel..."
}
GRUB_EOF

    # 在 linux 行中添加 cmdline
    if [ -n "$CMDLINE" ]; then
        sed -i "s|linux /boot/vmlinuz|linux /boot/vmlinuz $CMDLINE|" "$ISO_DIR/boot/grub/grub.cfg"
    fi

    # 为 UEFI 添加额外的 GRUB 配置
    if [ "$USE_EFI" = true ]; then
        mkdir -p "$ISO_DIR/EFI/BOOT"
        cp "$ISO_DIR/boot/grub/grub.cfg" "$ISO_DIR/EFI/BOOT/"
    fi

    if [ "$DEBUG" = true ]; then
        info "GRUB 配置内容:"
        cat "$ISO_DIR/boot/grub/grub.cfg"
    fi
    ok "生成 GRUB 配置文件"

    # ---- 使用 xorriso 直接创建 ISO（替代 grub-mkrescue）----
    info "正在生成 ISO..."

    # ---- 创建 GRUB BIOS 启动镜像 ----
    BIOS_BOOT_IMG="/usr/lib/grub/i386-pc/cdboot.img"
    if [ ! -f "$BIOS_BOOT_IMG" ]; then
        error "未找到 GRUB BIOS 启动镜像: $BIOS_BOOT_IMG"
        error "请安装 grub-pc-bin: sudo apt install grub-pc-bin"
        exit 1
    fi

    # 使用 grub-mkimage 生成 core.img，嵌入必要的模块
    info "生成 GRUB core.img (BIOS)..."
    set +e
    if [ "$DEBUG" = true ]; then
        grub-mkimage -O i386-pc -o "$TEMP_DIR/core.img" -p /boot/grub \
            iso9660 biosdisk part_msdos normal configfile boot linux \
            search search_fs_file echo test gzio all_video
    else
        grub-mkimage -O i386-pc -o "$TEMP_DIR/core.img" -p /boot/grub \
            iso9660 biosdisk part_msdos normal configfile boot linux \
            search search_fs_file echo test gzio all_video 2>/dev/null
    fi
    set -e
    if [ ! -f "$TEMP_DIR/core.img" ]; then
        error "grub-mkimage 执行失败，无法创建 core.img"
        exit 1
    fi

    # 拼接 cdboot.img + core.img = eltorito.img
    cat "$BIOS_BOOT_IMG" "$TEMP_DIR/core.img" > "$ISO_DIR/boot/grub/eltorito.img"
    ok "创建 GRUB BIOS El Torito 启动镜像 ($(du -h "$ISO_DIR/boot/grub/eltorito.img" | cut -f1))"

    # 构建 xorriso 基础参数
    XORRISO_OPTS=(
        "-b" "boot/grub/eltorito.img"
        "-no-emul-boot"
        "-boot-load-size" "4"
        "-boot-info-table"
        "--grub2-boot-info"
    )

    # ---- UEFI 模式: 额外创建 EFI 系统分区 ----
    if [ "$USE_EFI" = true ]; then
        if [ "$DEBUG" = true ]; then
            info "创建 BIOS+UEFI 双启动 ISO"
        fi

        # 使用 grub-mkstandalone 创建 EFI 可执行文件（嵌入 grub.cfg）
        info "生成 GRUB EFI 启动文件..."
        EFI_GRUB_CFG="$ISO_DIR/boot/grub/grub.cfg"
        EFI_BINARY="$TEMP_DIR/BOOTx64.EFI"
        COPY_GRUB_CFG_TO_EFI=false

        if command -v grub-mkstandalone &>/dev/null; then
            set +e
            if [ "$DEBUG" = true ]; then
                grub-mkstandalone -O x86_64-efi \
                    -o "$EFI_BINARY" \
                    -p "/boot/grub" \
                    boot/grub/grub.cfg="$EFI_GRUB_CFG"
            else
                grub-mkstandalone -O x86_64-efi \
                    -o "$EFI_BINARY" \
                    -p "/boot/grub" \
                    boot/grub/grub.cfg="$EFI_GRUB_CFG" 2>/dev/null
            fi
            set -e
        fi

        # 回退: grub-mkimage（未嵌入配置，需要额外复制 grub.cfg）
        if [ ! -f "$EFI_BINARY" ]; then
            warn "grub-mkstandalone 不可用，回退到 grub-mkimage..."
            set +e
            if [ "$DEBUG" = true ]; then
                grub-mkimage -O x86_64-efi \
                    -o "$EFI_BINARY" \
                    -p "/boot/grub" \
                    iso9660 part_gpt part_msdos ext2 fat normal configfile \
                    boot linux chain search search_fs_file
            else
                grub-mkimage -O x86_64-efi \
                    -o "$EFI_BINARY" \
                    -p "/boot/grub" \
                    iso9660 part_gpt part_msdos ext2 fat normal configfile \
                    boot linux chain search search_fs_file 2>/dev/null
            fi
            set -e
            if [ ! -f "$EFI_BINARY" ]; then
                error "无法创建 GRUB EFI 启动文件"
                error "请安装 grub-efi-amd64-bin: sudo apt install grub-efi-amd64-bin"
                exit 1
            fi
            COPY_GRUB_CFG_TO_EFI=true
        fi

        # 创建 FAT 格式的 EFI 系统分区镜像 (4MB)
        info "创建 EFI 系统分区..."
        EFI_IMG="$ISO_DIR/boot/grub/efi.img"
        dd if=/dev/zero of="$EFI_IMG" bs=1K count=4096 2>/dev/null
        if ! mkfs.vfat "$EFI_IMG" 2>/dev/null; then
            error "无法创建 FAT 文件系统"
            error "请安装 dosfstools: sudo apt install dosfstools"
            exit 1
        fi

        # 将 EFI 启动文件复制到 FAT 镜像中
        mmd -i "$EFI_IMG" ::/EFI 2>/dev/null || {
            error "无法在 EFI 镜像中创建目录"
            exit 1
        }
        mmd -i "$EFI_IMG" ::/EFI/BOOT 2>/dev/null
        mcopy -i "$EFI_IMG" "$EFI_BINARY" ::/EFI/BOOT/BOOTx64.EFI 2>/dev/null || {
            error "无法将 EFI 启动文件复制到 FAT 镜像"
            exit 1
        }

        # grub-mkimage 方式需要额外复制 grub.cfg 到 FAT 镜像
        if [ "$COPY_GRUB_CFG_TO_EFI" = true ]; then
            info "复制 GRUB 配置到 EFI 系统分区..."
            mmd -i "$EFI_IMG" ::/boot 2>/dev/null
            mmd -i "$EFI_IMG" ::/boot/grub 2>/dev/null
            mcopy -i "$EFI_IMG" "$EFI_GRUB_CFG" ::/boot/grub/grub.cfg 2>/dev/null
        fi

        ok "EFI 系统分区创建完成"

        # 添加 UEFI El Torito 启动入口
        XORRISO_OPTS+=(
            "-eltorito-alt-boot"
            "-e" "boot/grub/efi.img"
            "-no-emul-boot"
            "-isohybrid-gpt-basdat"
        )
    fi

    if [ "$DEBUG" = true ]; then
        info "xorriso 参数: ${XORRISO_OPTS[*]}"
    fi

    # 执行 xorriso
    info "正在生成 ISO 文件..."
    set +e
    if [ "$DEBUG" = true ]; then
        xorriso -as mkisofs \
            "${XORRISO_OPTS[@]}" \
            -o "$OUTPUT_ISO" \
            "$ISO_DIR" 2>&1
    else
        xorriso -as mkisofs \
            "${XORRISO_OPTS[@]}" \
            -o "$OUTPUT_ISO" \
            "$ISO_DIR" 2>/dev/null
    fi
    XORRISO_EXIT=$?
    set -e

    if [ $XORRISO_EXIT -ne 0 ]; then
        error "xorriso 执行失败 (退出码: $XORRISO_EXIT)"
        exit 1
    fi

    if [ ! -f "$OUTPUT_ISO" ]; then
        error "ISO 生成失败，输出文件不存在"
        exit 1
    fi

    iso_size=$(du -h "$OUTPUT_ISO" | cut -f1)
    ok "ISO 生成成功: $OUTPUT_ISO ($iso_size)"
fi

# =============================================================================
# 阶段4: 使用 QEMU 启动
# =============================================================================
if [ "$NO_QEMU" = true ]; then
    bold ""
    bold "═══════════ 完成 ═══════════"
    echo ""
    ok "ISO 已生成: $OUTPUT_ISO"
    info "可以随时手动启动:"
    info "  qemu-system-x86_64 -cdrom $OUTPUT_ISO -m $QEMU_MEM"
    info "或用此脚本启动:"
    info "  $0 -r"
    exit 0
fi

bold ""
bold "═══════════ 启动 QEMU ═══════════"
echo ""

# 检查 ISO
if [ ! -f "$OUTPUT_ISO" ]; then
    error "ISO 文件不存在: $OUTPUT_ISO"
    exit 1
fi
ok "ISO: $OUTPUT_ISO"

# ---- 构建 QEMU 命令 ----
QEMU_CMD="qemu-system-x86_64"
QEMU_ARGS=()

# 内存和 CPU
QEMU_ARGS+=("-m" "$QEMU_MEM")
QEMU_ARGS+=("-smp" "$QEMU_SMP")

# 显示
QEMU_ARGS+=("-cdrom" "$OUTPUT_ISO")

# 网络 (用户模式)
QEMU_ARGS+=("-netdev" "user,id=net0")
QEMU_ARGS+=("-device" "e1000,netdev=net0")

# 串口控制台
if [ "$SERIAL_CONSOLE" = true ]; then
    QEMU_ARGS+=("-nographic")
else
    QEMU_ARGS+=("-vga" "std")
fi

# USB 支持
QEMU_ARGS+=("-usb")

# RTC
QEMU_ARGS+=("-rtc" "base=localtime")

# KVM 加速
if [ "$NO_KVM" = false ]; then
    if [ -e /dev/kvm ]; then
        QEMU_ARGS+=("-enable-kvm")
        info "KVM 加速已启用"
    else
        warn "/dev/kvm 不可用，使用纯软件模拟 (速度较慢)"
    fi
fi

# UEFI 支持
if [ "$USE_EFI" = true ]; then
    OVMF_CODE=""
    for path in \
        /usr/share/ovmf/OVMF.fd \
        /usr/share/qemu/ovmf-x86_64.bin \
        /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
        /usr/share/edk2-ovmf/OVMF_CODE.fd; do
        if [ -f "$path" ]; then
            OVMF_CODE="$path"
            break
        fi
    done

    if [ -n "$OVMF_CODE" ]; then
        QEMU_ARGS+=("-bios" "$OVMF_CODE")
        ok "UEFI 启动 (OVMF: $OVMF_CODE)"
    else
        warn "未找到 UEFI 固件 (OVMF)，使用 BIOS 兼容模式"
    fi
fi

# 打印内核命令行和完整 QEMU 命令
if [ -n "$CMDLINE" ]; then
    info "内核命令行: $CMDLINE"
fi
if [ "$DEBUG" = true ]; then
    info "QEMU 命令:"
    echo "  $QEMU_CMD ${QEMU_ARGS[*]}"
fi

# ---- 启动 QEMU ----
ok "启动 QEMU (内存: $QEMU_MEM, CPU: $QEMU_SMP)"
info "按 ${BOLD}Ctrl+A X${NC} 退出 QEMU"
info "按 ${BOLD}Ctrl+A H${NC} 查看 QEMU 帮助"
echo ""

# 捕获 Ctrl+C 以友好退出
trap 'echo ""; info "用户中断"; exit 0' INT

# 执行 QEMU
set +e
"$QEMU_CMD" "${QEMU_ARGS[@]}"
QEMU_EXIT=$?
set -e

echo ""
if [ $QEMU_EXIT -eq 0 ]; then
    ok "QEMU 正常退出"
else
    warn "QEMU 退出 (码: $QEMU_EXIT)"
fi

exit 0
