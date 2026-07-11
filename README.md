# make-bootable-iso - Linux 内核快速启动工具

一个将编译好的 Linux 内核打包为可启动 ISO，并用 QEMU 快速启动的辅助脚本。

## ✨ 特性

- 📦 **自动打包 ISO** - 将内核 `bzImage` 打包成可启动 ISO
- 🐚 **自动生成 initramfs** - 无需手动制作，自动生成 BusyBox initramfs
- 💾 **虚拟硬盘支持** - 自动创建和管理 qcow2 虚拟硬盘（支持 MB/GB 单位）
- 🖥️ **图形界面支持** - 默认使用 VGA 图形窗口，也可切换串口控制台
- 🎛️ **交互式菜单** - 无需记忆命令，菜单操作更简单
- 🔧 **UEFI 双启动** - 支持 BIOS + UEFI 启动模式
- ⚡ **KVM 加速** - 自动检测并启用 KVM 硬件加速
- 🎨 **彩色输出** - 清晰的信息分级显示

---

## 📢 更新公告 (v1.2)

### 重大更新

**🎯 交互式菜单模式**
- 直接运行 `./make-bootable-iso.sh` 即可进入图形化菜单
- 无需记忆复杂的命令行参数
- 清晰显示当前状态（内核/ISO/硬盘）

**💾 硬盘大小支持 MB 单位**
- 现在可以创建 512M、1G、5G 等大小的硬盘
- 输入纯数字自动识别为 MB（如 `512` = `512M`）

**🚀 性能优化**
- 修复了菜单模式下的权限问题
- 重构代码，不再递归调用自身
- 更快的 ISO 构建速度

**🎨 界面美化**
- 彩色菜单界面
- 实时状态显示
- 更友好的交互提示

---

## 📥 安装

### 1. 下载脚本

将 `make-bootable-iso.sh` 放入 Linux 内核源码目录：

```bash
cp make-bootable-iso.sh /path/to/linux-source/
cd /path/to/linux-source
chmod +x make-bootable-iso.sh
```
