#!/usr/bin/env pwsh
# VPS Kernel Config Optimizer for Actions-bbr-v3
# Transforms the base x86-64.config into a VPS-optimized kernel config.
# Target: Debian/Ubuntu VPS on KVM, Xen, VMware, Hyper-V
#
# After applying, the workflow's `make olddefconfig` will resolve
# all Kconfig dependencies and clean up orphaned sub-options.

param(
    [string]$ConfigPath = "$PSScriptRoot\x86-64.config",
    [string]$BackupPath = "$PSScriptRoot\x86-64.config.bak"
)

$ErrorActionPreference = "Stop"

# Create backup
Copy-Item $ConfigPath $BackupPath -Force
Write-Host "Backup saved to $BackupPath"

$content = Get-Content $ConfigPath -Raw
# Normalize line endings for reliable regex matching
$content = $content -replace "`r`n", "`n"

# Helper: enable an option
function Enable-Option([ref]$Content, [string]$Opt, [string]$Val = "y") {
    $escaped = [regex]::Escape($Opt)
    $pattern = "(?m)^(# ${escaped} is not set|${escaped}=.*)$"
    if ($Content.Value -match $pattern) {
        $Content.Value = $Content.Value -replace $pattern, "${Opt}=${Val}"
    } else {
        Write-Warning "Option $Opt not found in config"
    }
}

# Helper: disable an option
function Disable-Option([ref]$Content, [string]$Opt) {
    $escaped = [regex]::Escape($Opt)
    $pattern = "(?m)^(${escaped}=.*)$"
    if ($Content.Value -match $pattern) {
        $Content.Value = $Content.Value -replace $pattern, "# ${Opt} is not set"
    }
}

Write-Host "`n=== PERFORMANCE OPTIMIZATIONS ==="

# 1. Kernel compression: XZ -> ZSTD (faster decompression, better ratio)
Write-Host "  [*] Kernel compression: XZ -> ZSTD"
Disable-Option ([ref]$content) "CONFIG_KERNEL_XZ"
Enable-Option ([ref]$content) "CONFIG_KERNEL_ZSTD"

# 2. Timer: NO_HZ_FULL -> NO_HZ_IDLE (lower overhead for typical VPS workloads)
Write-Host "  [*] Timer tick: NO_HZ_FULL -> NO_HZ_IDLE"
Disable-Option ([ref]$content) "CONFIG_NO_HZ_FULL"
Enable-Option ([ref]$content) "CONFIG_NO_HZ_IDLE"

# 3. BPF JIT always on (critical for eBPF/XDP performance)
Write-Host "  [*] Enable BPF_JIT_ALWAYS_ON"
Enable-Option ([ref]$content) "CONFIG_BPF_JIT_ALWAYS_ON"

# 4. ZSWAP enabled by default
Write-Host "  [*] Enable ZSWAP_DEFAULT_ON"
Enable-Option ([ref]$content) "CONFIG_ZSWAP_DEFAULT_ON"

# 5. Page pool stats (XDP/network monitoring)
Write-Host "  [*] Enable PAGE_POOL_STATS"
Enable-Option ([ref]$content) "CONFIG_PAGE_POOL_STATS"

# 6. ZRAM default compression: lzo-rle -> zstd (better ratio)
Write-Host "  [*] ZRAM compression: lzo-rle -> zstd"
Disable-Option ([ref]$content) "CONFIG_ZRAM_DEF_COMP_LZORLE"
Enable-Option ([ref]$content) "CONFIG_ZRAM_DEF_COMP_ZSTD"
$content = $content -replace 'CONFIG_ZRAM_DEF_COMP="lzo-rle"', 'CONFIG_ZRAM_DEF_COMP="zstd"'

# 7. Microcode: kernel 7.0 merged Intel/AMD into unified CONFIG_MICROCODE
# CONFIG_MICROCODE_AMD is no longer a separate option; no action needed

Write-Host "`n=== AGGRESSIVE PERFORMANCE OPTIMIZATIONS ==="

# Helper: set a config option to a specific integer value
function Set-OptionValue([ref]$Content, [string]$Opt, [string]$Val) {
    $escaped = [regex]::Escape($Opt)
    $pattern = "(?m)^(# ${escaped} is not set|${escaped}=.*)$"
    if ($Content.Value -match $pattern) {
        $Content.Value = $Content.Value -replace $pattern, "${Opt}=${Val}"
    } else {
        Write-Warning "Option $Opt not found in config"
    }
}

# 8. [AGGRESSIVE] Disable CPU vulnerability mitigations (5-30% performance gain)
Write-Host "  [!] Disable CPU_MITIGATIONS (Spectre/Meltdown/MDS/SRSO/GDS...)"
Disable-Option ([ref]$content) "CONFIG_CPU_MITIGATIONS"

# 9. [AGGRESSIVE] Reduce NR_CPUS: 8192 -> 256 (less per-CPU memory overhead)
Write-Host "  [!] Disable MAXSMP, set NR_CPUS=256"
Disable-Option ([ref]$content) "CONFIG_MAXSMP"
Set-OptionValue ([ref]$content) "CONFIG_NR_CPUS" "256"

# 10. [AGGRESSIVE] Timer frequency: 250Hz -> 1000Hz (lower scheduling/network latency)
Write-Host "  [!] Timer: HZ=250 -> HZ=1000"
Disable-Option ([ref]$content) "CONFIG_HZ_100"
Disable-Option ([ref]$content) "CONFIG_HZ_250"
Disable-Option ([ref]$content) "CONFIG_HZ_300"
Enable-Option ([ref]$content) "CONFIG_HZ_1000"
Set-OptionValue ([ref]$content) "CONFIG_HZ" "1000"

# 11. [AGGRESSIVE] Disable IA-32 emulation (pure 64-bit VPS)
Write-Host "  [!] Disable IA32_EMULATION + X86_X32_ABI"
Disable-Option ([ref]$content) "CONFIG_IA32_EMULATION"
Disable-Option ([ref]$content) "CONFIG_X86_X32_ABI"

# 12. Enable BTF debug info (required for eBPF CO-RE / modern observability)
Write-Host "  [*] Enable DEBUG_INFO_BTF (eBPF CO-RE)"
Disable-Option ([ref]$content) "CONFIG_DEBUG_INFO_NONE"
Enable-Option ([ref]$content) "CONFIG_DEBUG_INFO"
Enable-Option ([ref]$content) "CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT"
Enable-Option ([ref]$content) "CONFIG_DEBUG_INFO_BTF"
Enable-Option ([ref]$content) "CONFIG_DEBUG_INFO_BTF_MODULES"

# 13. RCU deep optimization
Write-Host "  [*] RCU: NOCB_CPU_DEFAULT_ALL + LAZY default on"
Enable-Option ([ref]$content) "CONFIG_RCU_NOCB_CPU_DEFAULT_ALL"
Disable-Option ([ref]$content) "CONFIG_RCU_LAZY_DEFAULT_OFF"

# 14. TEO CPU idle governor (smarter idle prediction for VPS)
Write-Host "  [*] Enable CPU_IDLE_GOV_TEO"
Enable-Option ([ref]$content) "CONFIG_CPU_IDLE_GOV_TEO"

# 15. ZSWAP exclusive loads (page read from zswap auto-deleted from swap backend)
Write-Host "  [*] Enable ZSWAP_EXCLUSIVE_LOADS_DEFAULT_ON"
Enable-Option ([ref]$content) "CONFIG_ZSWAP_EXCLUSIVE_LOADS_DEFAULT_ON"

# 16. Module compression: none -> ZSTD
Write-Host "  [*] Module compression: ZSTD"
Disable-Option ([ref]$content) "CONFIG_MODULE_COMPRESS_NONE"
Enable-Option ([ref]$content) "CONFIG_MODULE_COMPRESS_ZSTD"

# 17. Haltpoll cpuidle (reduce VMEXIT latency in VMs)
Write-Host "  [*] Enable HALTPOLL_CPUIDLE"
Enable-Option ([ref]$content) "CONFIG_HALTPOLL_CPUIDLE"

# 18. Network extras
Write-Host "  [*] Enable TLS offload, MPTCP, XDP_SOCKETS, TCP_AO"
Enable-Option ([ref]$content) "CONFIG_TLS" "m"
Enable-Option ([ref]$content) "CONFIG_TLS_DEVICE"
Enable-Option ([ref]$content) "CONFIG_MPTCP"
Enable-Option ([ref]$content) "CONFIG_XDP_SOCKETS"
Enable-Option ([ref]$content) "CONFIG_TCP_AO"

# 19. sched_ext (loadable external schedulers)
Write-Host "  [*] Enable SCHED_CLASS_EXT"
Enable-Option ([ref]$content) "CONFIG_SCHED_CLASS_EXT"

Write-Host "`n=== DISABLE VPS-UNNECESSARY SUBSYSTEMS ==="

# --- Sound (huge build-time savings) ---
Write-Host "  [-] Sound subsystem (ALSA, HD-Audio, SoC, USB audio)"
Disable-Option ([ref]$content) "CONFIG_SOUND"

# --- Wireless/WiFi ---
Write-Host "  [-] Wireless LAN (WiFi drivers)"
Disable-Option ([ref]$content) "CONFIG_WLAN"

# --- Bluetooth ---
Write-Host "  [-] Bluetooth"
Disable-Option ([ref]$content) "CONFIG_BT"

# --- NFC ---
Write-Host "  [-] NFC"
Disable-Option ([ref]$content) "CONFIG_NFC"

# --- HAM Radio ---
Write-Host "  [-] Amateur Radio (HAMRADIO)"
Disable-Option ([ref]$content) "CONFIG_HAMRADIO"

# --- CAN bus ---
Write-Host "  [-] CAN bus"
Disable-Option ([ref]$content) "CONFIG_CAN"

# --- Media (V4L2, DVB, webcams, TV tuners) ---
Write-Host "  [-] Media support (V4L2, DVB, cameras, tuners)"
Disable-Option ([ref]$content) "CONFIG_MEDIA_SUPPORT"

# --- IR Remote Control ---
Write-Host "  [-] IR Remote Control"
Disable-Option ([ref]$content) "CONFIG_RC_CORE"

# --- CEC (Consumer Electronics Control) ---
Write-Host "  [-] CEC"
Disable-Option ([ref]$content) "CONFIG_CEC_CORE"

# --- ARCNET ---
Write-Host "  [-] ARCNET"
Disable-Option ([ref]$content) "CONFIG_ARCNET"

# --- ATM ---
Write-Host "  [-] ATM drivers"
Disable-Option ([ref]$content) "CONFIG_ATM_DRIVERS"

# --- FDDI ---
Write-Host "  [-] FDDI"
Disable-Option ([ref]$content) "CONFIG_FDDI"

# --- HIPPI ---
Write-Host "  [-] HIPPI"
Disable-Option ([ref]$content) "CONFIG_HIPPI"

# --- ISDN ---
Write-Host "  [-] ISDN"
Disable-Option ([ref]$content) "CONFIG_ISDN"

# --- FireWire ---
Write-Host "  [-] FireWire (IEEE 1394)"
Disable-Option ([ref]$content) "CONFIG_FIREWIRE"

# --- MTD (flash memory) ---
Write-Host "  [-] MTD flash memory"
Disable-Option ([ref]$content) "CONFIG_MTD"

# --- PCMCIA/PCCARD ---
Write-Host "  [-] PCMCIA/PCCARD"
Disable-Option ([ref]$content) "CONFIG_PCCARD"
Disable-Option ([ref]$content) "CONFIG_PCMCIA"

# --- Parallel port ---
Write-Host "  [-] Parallel port"
Disable-Option ([ref]$content) "CONFIG_PARPORT"

# --- IIO (Industrial I/O sensors) ---
Write-Host "  [-] Industrial I/O sensors"
Disable-Option ([ref]$content) "CONFIG_IIO"

# --- Speakup ---
Write-Host "  [-] Speakup speech synthesis"
Disable-Option ([ref]$content) "CONFIG_SPEAKUP"

# --- InfiniBand ---
Write-Host "  [-] InfiniBand"
Disable-Option ([ref]$content) "CONFIG_INFINIBAND"

# --- Comedi (data acquisition) ---
Write-Host "  [-] Comedi data acquisition"
Disable-Option ([ref]$content) "CONFIG_COMEDI"

# --- Staging drivers ---
Write-Host "  [-] Staging drivers"
Disable-Option ([ref]$content) "CONFIG_STAGING"

# --- SoundWire ---
Write-Host "  [-] SoundWire"
Disable-Option ([ref]$content) "CONFIG_SOUNDWIRE"

# --- Input: Joystick, Tablet, Touchscreen, Gameport ---
Write-Host "  [-] Input: Joystick, Tablet, Touchscreen, Gameport"
Disable-Option ([ref]$content) "CONFIG_INPUT_JOYSTICK"
Disable-Option ([ref]$content) "CONFIG_INPUT_TABLET"
Disable-Option ([ref]$content) "CONFIG_INPUT_TOUCHSCREEN"
Disable-Option ([ref]$content) "CONFIG_GAMEPORT"

# --- WAN/HDLC ---
Write-Host "  [-] WAN/HDLC"
Disable-Option ([ref]$content) "CONFIG_WAN"

# --- WWAN (Wireless WAN / mobile) ---
Write-Host "  [-] Wireless WAN"
Disable-Option ([ref]$content) "CONFIG_WWAN"

# --- IEEE 802.15.4 (Zigbee) ---
Write-Host "  [-] IEEE 802.15.4 (Zigbee)"
Disable-Option ([ref]$content) "CONFIG_IEEE802154_DRIVERS"

# --- 1-Wire ---
Write-Host "  [-] 1-Wire bus"
Disable-Option ([ref]$content) "CONFIG_W1"

# --- GNSS (GPS) ---
Write-Host "  [-] GNSS (GPS receivers)"
Disable-Option ([ref]$content) "CONFIG_GNSS"

# --- Fibre Channel networking ---
Write-Host "  [-] Fibre Channel networking (NET_FC)"
Disable-Option ([ref]$content) "CONFIG_NET_FC"

# --- USB Gadget (device mode) ---
Write-Host "  [-] USB Gadget (device mode)"
Disable-Option ([ref]$content) "CONFIG_USB_GADGET"

# --- Accessibility ---
Write-Host "  [-] Accessibility"
Disable-Option ([ref]$content) "CONFIG_ACCESSIBILITY"

# --- AGP (no physical GPU on VPS) ---
Write-Host "  [-] AGP"
Disable-Option ([ref]$content) "CONFIG_AGP"

Write-Host "`n=== GPU: DISABLE HEAVY DRIVERS, KEEP VPS-ESSENTIAL ==="

# Disable desktop GPU drivers (massive build-time savings)
Write-Host "  [-] DRM: Radeon, AMDGPU, Nouveau, i915, GMA500"
Disable-Option ([ref]$content) "CONFIG_DRM_RADEON"
Disable-Option ([ref]$content) "CONFIG_DRM_AMDGPU"
Disable-Option ([ref]$content) "CONFIG_DRM_NOUVEAU"
Disable-Option ([ref]$content) "CONFIG_DRM_I915"
Disable-Option ([ref]$content) "CONFIG_DRM_GMA500"
# Keep: DRM_BOCHS, DRM_CIRRUS_QEMU, DRM_QXL, DRM_VIRTIO_GPU, DRM_VMWGFX,
#       DRM_XEN_FRONTEND, DRM_VBOXVIDEO, DRM_AST, DRM_HYPERV, DRM_MGAG200

# Reduce VGA_ARB max GPUs
$content = $content -replace 'CONFIG_VGA_ARB_MAX_GPUS=16', 'CONFIG_VGA_ARB_MAX_GPUS=4'

Write-Host "`n=== DISABLE LAPTOP/DESKTOP PLATFORM DRIVERS ==="

$laptopDrivers = @(
    "CONFIG_ACERHDF", "CONFIG_ACER_WMI", "CONFIG_ACER_WIRELESS",
    "CONFIG_ASUS_LAPTOP", "CONFIG_ASUS_WMI", "CONFIG_ASUS_NB_WMI",
    "CONFIG_EEEPC_LAPTOP", "CONFIG_EEEPC_WMI",
    "CONFIG_DELL_LAPTOP", "CONFIG_DELL_WMI", "CONFIG_DELL_SMO8800",
    "CONFIG_HP_ACCEL", "CONFIG_HP_WMI",
    "CONFIG_IDEAPAD_LAPTOP", "CONFIG_LENOVO_YMC",
    "CONFIG_THINKPAD_ACPI", "CONFIG_THINKPAD_LMI",
    "CONFIG_SAMSUNG_LAPTOP", "CONFIG_SAMSUNG_Q10",
    "CONFIG_SONY_LAPTOP",
    "CONFIG_MSI_LAPTOP", "CONFIG_MSI_WMI", "CONFIG_MSI_EC",
    "CONFIG_FUJITSU_LAPTOP", "CONFIG_FUJITSU_TABLET",
    "CONFIG_PANASONIC_LAPTOP",
    "CONFIG_COMPAL_LAPTOP",
    "CONFIG_LG_LAPTOP",
    "CONFIG_ACPI_TOSHIBA", "CONFIG_TOSHIBA_BT_RFKILL", "CONFIG_TOSHIBA_HAPS", "CONFIG_TOSHIBA_WMI",
    "CONFIG_ACPI_CMPC",
    "CONFIG_TOPSTAR_LAPTOP",
    "CONFIG_SYSTEM76_ACPI",
    "CONFIG_APPLE_GMUX",
    "CONFIG_GPD_POCKET_FAN",
    "CONFIG_AMD_PMF",
    "CONFIG_SENSORS_HDAPS",
    "CONFIG_AMILO_RFKILL",
    "CONFIG_ALIENWARE_WMI"
)
foreach ($drv in $laptopDrivers) {
    Disable-Option ([ref]$content) $drv
}
Write-Host "  [-] $($laptopDrivers.Count) laptop/desktop platform drivers"

# Disable Chrome OS and Surface platform drivers
Write-Host "  [-] Chrome OS platform drivers"
Disable-Option ([ref]$content) "CONFIG_CHROME_PLATFORMS"
Write-Host "  [-] Surface platform drivers"
Disable-Option ([ref]$content) "CONFIG_SURFACE_PLATFORMS"

Write-Host "`n=== DISABLE LEGACY FRAME BUFFER HARDWARE DRIVERS ==="

$fbDrivers = @(
    "CONFIG_FB_CIRRUS", "CONFIG_FB_PM2", "CONFIG_FB_CYBER2000",
    "CONFIG_FB_ARC", "CONFIG_FB_VGA16", "CONFIG_FB_HGA", "CONFIG_FB_N411",
    "CONFIG_FB_MATROX", "CONFIG_FB_RADEON", "CONFIG_FB_ATY128",
    "CONFIG_FB_ATY", "CONFIG_FB_S3", "CONFIG_FB_SAVAGE", "CONFIG_FB_SIS",
    "CONFIG_FB_VIA", "CONFIG_FB_NEOMAGIC", "CONFIG_FB_KYRO",
    "CONFIG_FB_3DFX", "CONFIG_FB_VOODOO1", "CONFIG_FB_VT8623",
    "CONFIG_FB_TRIDENT", "CONFIG_FB_ARK", "CONFIG_FB_PM3",
    "CONFIG_FB_SMSCUFX", "CONFIG_FB_MB862XX", "CONFIG_FB_HECUBA"
)
foreach ($fb in $fbDrivers) {
    Disable-Option ([ref]$content) $fb
}
Write-Host "  [-] $($fbDrivers.Count) legacy framebuffer drivers"
# Keep: FB_EFI, FB_VESA, FB_SIMPLE, FB_UVESA, XEN_FBDEV_FRONTEND

Write-Host "`n=== DISABLE EXOTIC PARTITION TYPES ==="

$partitions = @(
    "CONFIG_ACORN_PARTITION", "CONFIG_AMIGA_PARTITION",
    "CONFIG_ATARI_PARTITION", "CONFIG_MAC_PARTITION",
    "CONFIG_SGI_PARTITION", "CONFIG_SUN_PARTITION",
    "CONFIG_KARMA_PARTITION", "CONFIG_BSD_DISKLABEL",
    "CONFIG_MINIX_SUBPARTITION", "CONFIG_SOLARIS_X86_PARTITION",
    "CONFIG_UNIXWARE_DISKLABEL", "CONFIG_CMDLINE_PARTITION"
)
foreach ($p in $partitions) {
    Disable-Option ([ref]$content) $p
}
Write-Host "  [-] $($partitions.Count) exotic partition types"

Write-Host "`n=== STRIP EXOTIC FILESYSTEMS ==="

$exoticFS = @(
    "CONFIG_ADFS_FS", "CONFIG_AFFS_FS", "CONFIG_BEFS_FS",
    "CONFIG_BFS_FS", "CONFIG_EFS_FS", "CONFIG_HPFS_FS",
    "CONFIG_MINIX_FS", "CONFIG_OMFS_FS", "CONFIG_QNX4FS_FS",
    "CONFIG_QNX6FS_FS", "CONFIG_ROMFS_FS", "CONFIG_SYSV_FS",
    "CONFIG_UFS_FS", "CONFIG_VXFS_FS", "CONFIG_ORANGEFS_FS",
    "CONFIG_CODA_FS", "CONFIG_JFFS2_FS", "CONFIG_UBIFS_FS",
    "CONFIG_NILFS2_FS", "CONFIG_REISERFS_FS",
    "CONFIG_HFS_FS", "CONFIG_HFSPLUS_FS",
    "CONFIG_GFS2_FS", "CONFIG_OCFS2_FS", "CONFIG_ZONEFS_FS",
    "CONFIG_EROFS_FS"
)
foreach ($fs in $exoticFS) {
    Disable-Option ([ref]$content) $fs
}
Write-Host "  [-] $($exoticFS.Count) exotic/unnecessary filesystems"
# Keep: ext4, XFS, Btrfs, F2FS, NFS, CIFS/SMB, FUSE, OverlayFS, squashfs,
#       FAT/VFAT/exFAT, ISO9660/UDF, 9P, AFS, tmpfs, proc, sysfs

Write-Host "`n=== FINALIZE ==="

# Write optimized config
Set-Content $ConfigPath $content -NoNewline
Write-Host "Optimized config written to $ConfigPath"
Write-Host "Backup available at $BackupPath"
Write-Host ""
Write-Host "Summary of major changes:"
Write-Host ""
Write-Host "  === AGGRESSIVE OPTIMIZATIONS ==="
Write-Host "  - [!] CPU_MITIGATIONS disabled (5-30% perf gain, security trade-off)"
Write-Host "  - [!] NR_CPUS: 8192 -> 256 (reduced per-CPU memory overhead)"
Write-Host "  - [!] HZ: 250 -> 1000 (lower scheduling/network latency)"
Write-Host "  - [!] IA32_EMULATION + X86_X32_ABI disabled (pure 64-bit)"
Write-Host ""
Write-Host "  === PERFORMANCE FEATURES ==="
Write-Host "  - ZSTD kernel + module compression (faster boot, smaller /lib/modules)"
Write-Host "  - NO_HZ_IDLE timer (reduced overhead vs NO_HZ_FULL)"
Write-Host "  - BPF_JIT_ALWAYS_ON, DEBUG_INFO_BTF (eBPF CO-RE)"
Write-Host "  - ZSWAP (ZSTD, exclusive loads) + ZRAM (ZSTD)"
Write-Host "  - RCU_NOCB_CPU_DEFAULT_ALL + RCU_LAZY default on"
Write-Host "  - CPU_IDLE_GOV_TEO + HALTPOLL_CPUIDLE (VM-optimized idle)"
Write-Host "  - TCP_AO, MPTCP, TLS offload, XDP_SOCKETS, sched_ext"
Write-Host "  - PAGE_POOL_STATS, MICROCODE (unified)"
Write-Host ""
Write-Host "  === STRIPPED SUBSYSTEMS ==="
Write-Host "  - Disabled: Sound, WiFi, Bluetooth, NFC, Media, IR"
Write-Host "  - Disabled: Heavy GPU drivers (Radeon, AMDGPU, Nouveau, i915)"
Write-Host "  - Disabled: CAN, HAMRADIO, ISDN, FireWire, MTD, PCMCIA"
Write-Host "  - Disabled: IIO sensors, InfiniBand, Comedi, Staging"
Write-Host "  - Disabled: Joystick, Tablet, Touchscreen, Gameport"
Write-Host "  - Disabled: Laptop platform drivers (Acer, ASUS, Dell, HP...)"
Write-Host "  - Disabled: Exotic partitions and filesystems"
Write-Host "  - Disabled: ARCNET, ATM, FDDI, HIPPI, WAN, WWAN, 1-Wire"
Write-Host ""
Write-Host "Kept VPS-essential: VirtIO, KVM guest, Xen, Hyper-V, VMware,"
Write-Host "  cloud NICs (e1000e, ENA, virtio_net, vmxnet3, hv_netvsc),"
Write-Host "  BBRv3, FQ, nftables, WireGuard, Docker/container support,"
Write-Host "  ext4, XFS, Btrfs, NFS, CIFS, OverlayFS, crypto, security."
Write-Host ""
Write-Host "Build with: KCFLAGS='-march=x86-64-v3 -pipe' for modern VPS CPUs."
Write-Host "Run 'make olddefconfig' in the build to resolve dependencies."
