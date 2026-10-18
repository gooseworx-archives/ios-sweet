#!/usr/bin/env python3
"""Build the minimal Apple Device Tree for Google Pixel 6 (Tensor GS101, oriole) XNU bringup.

Addresses derived from Tensor GS101 stock device tree (gs101-oriole.dtb).
Usage: mkadt_pixel.py OUT.adt [--dump] [--qemu] [--highmem]
"""
import hashlib, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adt  # noqa: E402

# DRAM on Tensor GS101 starts at 0x80000000 (8 GB total LPDDR5).
# Reserved carveouts (GSA, TPU, AoC, ABL, Framebuffer) occupy 0x90000000 - 0x100000000.
# Upper DRAM above 4GB (0x100000000) is contiguous and free of carveouts (~6 GB).
PHYS_BASE = 0x82000000
MEM_SIZE = 0x0e000000  # 224 MiB contiguous RAM before 0x90200000 carveouts
HIGH_PHYS_BASE = 0x100000000
HIGH_MEM_SIZE = 0x180000000  # 6 GiB upper memory bank

# Tensor GS101 MMIO base (MMIO starts at 0x10000000)
SOC_BASE = 0x10000000

# GIC-600 / GICv3 (interrupt-controller@10400000)
GICD, GICD_SIZE = 0x10400000, 0x10000
GICR, GICR_SIZE = 0x10440000, 0x100000

# Samsung AMOLED linear framebuffer (splash@fac00000) left active by Pixel 6 ABL
FB, FB_SIZE = 0xfac00000, 0x9e3400
FB_W, FB_H, FB_STRIDE = 1080, 2400, 4320

# Google Tensor UFS 3.1 Host Controller (ufs@14700000)
UFS, UFS_SIZE = 0x14700000, 0x10000

# System counter timer (oscclk = 24.576 MHz, PPI 11 = INTID 27)
TIMEBASE = 24576000
VTIMER_INTID = 27

# QEMU virt (-M virt,gic-version=3 -cpu cortex-a76)
QEMU_GICD, QEMU_GICR, QEMU_TIMEBASE = 0x08000000, 0x080a0000, 62500000
QEMU_VTIMER_INTID = 27

PIXEL_ECID = 0x504958454c000001  # 'PIXEL' + 1, synthetic ECID
BOOT_MANIFEST_HASH = hashlib.sha384(b'ipixel boot manifest').digest()

D22AP_ADT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../research/ipsw-x/d22ap.adt')


def d22ap_product(path=D22AP_ADT):
    """/product properties of real D22AP tree, if extracted from IPSW."""
    if not os.path.exists(path):
        return None
    root, _ = adt.parse(open(path, 'rb').read())
    for c in root.children:
        if c.name == 'product':
            return [(p[0], p[2]) for p in c.props if not p[1] and p[0] not in ('name', 'AAPL,phandle')]
    return None


u32 = lambda *v: struct.pack('<%dI' % len(v), *v)
u64 = lambda *v: struct.pack('<%dQ' % len(v), *v)
cstr = lambda s: s.encode() + b'\0'


def node(name, props=(), children=()):
    n = adt.Node()
    n.props = [('name', 0, cstr(name))] + [(k, 0, v) for k, v in props]
    n.children = list(children)
    return n


def build(seed=None, qemu=False, highmem=False):
    phys_base, mem_size = (HIGH_PHYS_BASE, HIGH_MEM_SIZE) if highmem else (PHYS_BASE, MEM_SIZE)
    gicd, gicr, timebase = (QEMU_GICD, QEMU_GICR, QEMU_TIMEBASE) if qemu else (GICD, GICR, TIMEBASE)
    vtimer_irq = QEMU_VTIMER_INTID if qemu else VTIMER_INTID
    seed = seed if seed is not None else os.urandom(64)
    phandle = iter(range(1, 1000))
    ph = lambda: ('AAPL,phandle', u32(next(phandle)))

    chosen = node('chosen', [
        ph(),
        ('dram-base', u64(phys_base)),
        ('dram-size', u64(mem_size)),
        ('random-seed', seed),
        ('debug-enabled', u32(1)),
        ('firmware-version', cstr('ipixel-shim')),
        ('system-firmware-version', cstr('ipixel-shim')),
        ('boot-manifest-hash', BOOT_MANIFEST_HASH),
        ('crypto-hash-method', cstr('sha2-384')),
        ('display-scale', u32(3)),  # 3x Retina density (360x800 pt)
        ('unique-chip-id', struct.pack('<Q', PIXEL_ECID)),
        ('chip-id', u32(0x8015)),    # Apple A11 Bionic chip-id expected by iPhone X userland
        # Native "Hactivation" security flags
        ('certificate-production-status', u32(0)),
        ('effective-production-status-ap', u32(0)),
        ('certificate-security-mode', u32(1)),
        ('effective-security-mode-sep', u32(1)),
    ], [
        node('memory-map', [ph()]),
        # Relaxed SIP flags for unsigned userland and shared cache mapping
        node('asmb', [ph(), ('lp-sip0', u64(0x6f)), ('lp-sip1', u32(1))])
    ])

    # Google Tensor GS101 CPU Topology:
    # Cores 0-3: Cortex-A55 (Little) @ 1.80 GHz
    # Cores 4-5: Cortex-A76 (Mid)    @ 2.25 GHz
    # Cores 6-7: Cortex-X1  (Big)    @ 2.80 GHz
    cpu_nodes = []
    num_cpus = 1 if qemu else 8
    for core in range(num_cpus):
        if core >= 6:
            compat = 'arm,cortex-x1'
            clk = 2800000000
        elif core >= 4:
            compat = 'arm,cortex-a76'
            clk = 2250000000
        else:
            compat = 'arm,cortex-a55'
            clk = 1800000000

        cpu_nodes.append(node(f'cpu{core}', [
            ph(),
            ('device_type', cstr('cpu')),
            ('compatible', cstr(compat) + cstr('ARM,v8')),
            ('reg', u32(core << 8)),  # MPIDR Aff1:Aff0
            ('cpu-id', u32(core)),
            ('cluster-id', u32(0)),
            ('cluster-type', u32(0)),  # homogeneous SMP presentation to XNU
            ('die-cluster-id', u32(0)),
            ('cluster-core-id', u32(core)),
            ('l2-cache-id', u32(core)),
            ('l3-cache-id', u32(0)),
            ('state', cstr('running' if core == 0 else 'stopped')),
            ('timebase-frequency', u32(timebase)),
            ('clock-frequency', u32(clk)),
            ('bus-frequency', u32(100000000)),
            ('memory-frequency', u32(3200000000)),
            ('peripheral-frequency', u32(timebase)),
            ('fixed-frequency', u32(timebase)),
        ]))

    cpus = node('cpus', [ph(), ('#address-cells', u32(1)), ('#size-cells', u32(0))], cpu_nodes)

    gic = node('gic', [
        ph(),
        ('compatible', cstr('arm,gic-v3')),
        ('interrupt-controller', b''),
        ('virtual-timer-intid', u32(vtimer_irq)),
        ('reg', u64(gicd - SOC_BASE, GICD_SIZE, gicr - SOC_BASE, GICR_SIZE)),
    ])

    arm_io = node('arm-io', [
        ph(),
        ('device_type', cstr('pixel-io')),
        ('compatible', cstr('pixel-io') + cstr('sweet-io') + cstr('arm-io')),
        ('#address-cells', u32(2)),
        ('#size-cells', u32(2)),
        ('ranges', u64(0, SOC_BASE, 0x100000000 - SOC_BASE)),
    ], [
        gic,
        node('wdt', [ph(), ('no-pmu', u32(1))]),
        node('disp0', [
            ph(),
            ('device_type', cstr('display-subsystem')),
            ('compatible', cstr('pixel,display') + cstr('sweet,display')),
            ('canvas-width', u32(1125)),   # Presented iPhone X canvas width
            ('canvas-height', u32(2436)),  # Presented iPhone X canvas height
        ])
    ])

    fbcon = node('sweet-fbcon', [
        ph(),
        ('reg', u64(FB, FB_SIZE)),
        ('width', u32(FB_W)),
        ('height', u32(FB_H)),
        ('stride', u32(FB_STRIDE)),
    ])

    ufs = node('sweet-ufs', [
        ph(),
        ('compatible', cstr('google,gs101-ufs') + cstr('samsung,exynos-ufs') + cstr('qcom,ufshc')),
        ('reg', u64(UFS, UFS_SIZE)),
    ])

    defaults = node('defaults', [ph(), ('no-effaceable-storage', u32(1))])

    # MobileGestalt HomeButtonType = 2 (gesture-bar, iPhone X class)
    buttons = node('buttons', [
        ph(),
        ('button-names', cstr('volup') + cstr('voldown') + cstr('hold')),
        ('home-button-type', u32(2)),
        ('opposed-power-vol-buttons', u32(1)),
    ])

    product_props = d22ap_product()
    product = [node('product', [ph()] + product_props)] if product_props else []

    return node('device-tree', [
        ph(),
        ('compatible', cstr('D22AP') + cstr('iPhone10,3') + cstr('xiaomi,sweet') + cstr('google,oriole') + cstr('google,gs101') + cstr('AppleARM')),
        ('model', cstr('iPhone10,3')),
        ('target-type', cstr('D22')),
        ('target-sub-type', cstr('D22AP')),
        ('manufacturer', cstr('Apple Inc.')),
        ('#address-cells', u32(2)),
        ('#size-cells', u32(2)),
    ], [chosen, defaults, cpus, arm_io, fbcon, buttons] + product + ([] if qemu else [ufs]))


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} OUT.adt [--dump] [--qemu] [--highmem]", file=sys.stderr)
        sys.exit(1)
    out_file = sys.argv[1]
    root = build(qemu='--qemu' in sys.argv, highmem='--highmem' in sys.argv)
    blob = adt.serialize(root)
    with open(out_file, 'wb') as f:
        f.write(blob)
    if '--dump' in sys.argv:
        adt.dump(adt.parse(blob)[0])
    print(f'{out_file}: {len(blob)} bytes generated for Pixel 6 (oriole)', file=sys.stderr)
