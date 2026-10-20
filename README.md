# apple-silicon-thunderbolt-linux

PCIe over Thunderbolt/USB4 for Apple M1 Pro/Max/Ultra Macs on Linux: the
`pcie-apple-apciec` driver, its device-tree binding and nodes, and the tools
used to test it.

**Unofficial and experimental.** Not affiliated with or endorsed by Apple,
Asahi Linux or Fedora. Don't report problems from this code to Asahi Linux
or Fedora; open an issue here.

Ready-made Fedora Asahi Remix packages that include it are planned in
[aquarat/apple-silicon-kernel-plus](https://github.com/aquarat/apple-silicon-kernel-plus).

A Linux PCIe host driver and device-tree binding for the PCIe root complexes
("APCIEC") behind the USB4/Thunderbolt ports of Apple T600x SoCs (M1 Pro,
M1 Max, M1 Ultra). With it, PCIe devices in USB4/Thunderbolt enclosures, such
as NVMe drives, work under Linux. Licence: GPL-2.0-only (driver), GPL-2.0-only
OR BSD-2-Clause (binding), GPL-2.0+ OR MIT (DTS), as usual for these trees.

Each USB4 port has its own root complex with one root port. The root port's
link never leaves the SoC. It runs over a PCIe tunnel that the USB4
connection manager (the Linux `thunderbolt` driver) builds through the USB4
link to the router in the enclosure. The port register block is the one
`pcie-apple.c` drives for the internal PCIe controller, plus a tunnel reset
handshake.

Tested on a Mac Studio (M1 Max, j375c) with a UGREEN ASM2464PD NVMe
enclosure on rear port 3: about 3 GB/s sequential reads, automatic recovery
from unplug/replug. See "Status" below for what has and has not been tested.

## Layout

| path | what |
|---|---|
| `drivers/pci/controller/pcie-apple-apciec.c` | the driver |
| `drivers/pci/controller/Kconfig.fragment`, `Makefile` | in-tree Kconfig entry and Makefile line (the Makefile also serves the out-of-tree build) |
| `Kbuild`, `Makefile` | out-of-tree module build |
| `Documentation/devicetree/bindings/pci/apple,t6000-apciec.yaml` | DT binding |
| `arch/arm64/boot/dts/apple/t600x-apciec.dtsi` | SoC nodes: APCIEC + DART for USB4 ports 0-3 of a die |
| `arch/arm64/boot/dts/apple/t600x-j375-apciec.dtsi`, `t600x-j314-j316-apciec.dtsi` | board parts (Mac Studio ports 0-3, 14"/16" MacBook Pro ports 0-2) |
| `patches/` | the same as a 4-patch series on asahi-wip 7.2.11 (`git am`-able) |
| `udev/60-apciec-nvme-apst.rules` | NVMe APST policy for drives behind APCIEC |
| `scripts/make-patches.sh` | regenerates `patches/` from this tree on a kernel git checkout |
| `tools/` | test tools: `tb-soak.sh` (filesystem soak with software replugs), `plot-soak.py` (graphs), `tb-port-cycle` / `tipd-4cc` (software replug through the port's USB-C PD controller; the address table is for the Mac Studio) |
| `docs/results/` | graphs from the soak runs quoted below |

## Requirements

- **Bootloader: m1n1 1.6.1 or later.** The register tunables
  (`apple,tunable-debug`, `-fabric`, `-rc` on the controller node and
  `apple,tunable` on its first child, the root port) are per-device data that
  m1n1 copies into the DT at boot. It finds the controller through the
  `usb4_N_pcie` alias. The driver refuses to probe without them. Neither the
  driver nor the DTS contains tunable values.
- **Kernel: the Apple USB4/Thunderbolt series** (Sven Peter's NHI, ACIO,
  atcphy USB4 mode and tipd work). Tested on asahi-wip 7.2.11
  (e09c62843a8e). Upstream 7.1/7.2 and the Fedora Asahi 7.1.13 kernel do not
  have it; the APCIEC driver itself builds against any of them, but there
  is no tunnel to drive without the series.
- Older kernels: `of_map_iommu_id()` is the only 7.2-only API used; on 7.1
  it is `of_map_id(np, rid, "iommu-map", "iommu-map-mask", &np, &sid)` (a
  small shim). Not build-tested against 7.1.13 headers.
- Kernel options: `CONFIG_PCIE_APPLE` (provides the MSI doorbell address
  and makes the DART driver reserve it), `CONFIG_APPLE_DART`,
  `CONFIG_APPLE_TUNABLE` (selected), `CONFIG_COMMON_CLK`, `CONFIG_PCI_MSI`,
  `CONFIG_USB4` and `CONFIG_USB4_APPLE_SOC`.
- DT nodes per the binding, with `dma-coherent` (mandatory: without it every
  DART mapping is uncached and throughput falls to about 570 MB/s; the
  driver refuses to probe without it).
- Something must authorize USB4 routers so that the connection manager
  builds the PCIe tunnel (boltd, or a udev rule written for your security
  policy). DMA from the enclosure goes through the port's DART.

## Building

Out of tree, against installed headers (e.g. `kernel-16k-devel`) or a
configured tree:

    make KDIR=/lib/modules/$(uname -r)/build
    sudo make KDIR=/lib/modules/$(uname -r)/build install

In tree: `git am patches/*.patch` on asahi-wip 7.2.11 (or apply
`Kconfig.fragment`/`Makefile` by hand), then `CONFIG_PCIE_APPLE_APCIEC=m`.
`scripts/make-patches.sh KERNEL_TREE OUT_DIR` regenerates the series from this
directory; its hunks are located by context, so porting to another base
means adjusting a few anchors. The patches carry an `Assisted-by:` tag
(Documentation/process/coding-assistants.rst): the code was written with an
AI coding assistant and reviewed and tested by the maintainer, whose
`Signed-off-by:` they carry.

## Device tree

Binding: `apple,t6000-apciec` (shared by T6000/T6001/T6002). Registers
`config` (256 MiB ECAM), `rc`, `port`, `fabric`, `debug`; one management
interrupt; `msi-controller` + `msi-ranges` (32 AIC lines, as `apple,pcie`);
`iommu-map` to the port's DART; `power-domains` (`ps_atcN_pcie`);
`dma-coherent`; `#clock-cells = <0>`; the root port as child `pci@0,0`.

The DART (`apple,t8110-dart`) is a normal top-level node, but it only
responds while the port's application clock runs, which needs the port to
be reset, tuned and enabled first. The controller therefore registers that
clock and the DART node references it (`clocks = <&apciecN>`). The DART then
cannot probe before the controller has started the clock (fw_devlink and the
clock lookup both defer it), and the driver waits for the DART to bind
before it scans anything. No runtime DT changes are involved.

Consequence: the driver cannot be unbound or unloaded at runtime. The bound
DART holds the clock, which keeps the module in use (`rmmod` fails with
"in use"), and manual unbind is suppressed as in `pcie-apple`. Unbinding
would have the driver core unbind the DART first; apple-dart's device links
then unbind the PCI functions parents first, and a bridge whose pcieport
driver goes away clears its bus-master bit, so nvme's own teardown stalls
(measured: 60 s of admin timeouts). Updating the module therefore needs a
reboot. The earlier lab driver created the DART with an `of_changeset`
after enabling the port and could be unloaded; that mechanism is not
acceptable upstream.

`t600x-apciec.dtsi` uses the `DIE_NODE()`/`DIE_NO` macros of
`t600x-dieX.dtsi` and is included for die 0 from `t6001.dtsi` (and hence
`t6000.dtsi`) and `t6002.dtsi`. All nodes are disabled there; the board
files enable the ports they wire up and add the `usb4_N_pcie` aliases. The
second die of the M1 Ultra is not described (its ports are untested).

Note for kernels without the driver: an enabled DART whose controller has no
driver stays in the deferred-probe list (harmless, visible in
`/sys/kernel/debug/devices_deferred`).

Porting to the Fedora Asahi 7.1.13 tree: the dtsi only needs the
`ps_atcN_pcie` labels, `&aic`, and the `DIE_NODE` macros, all present there;
the board hunks go next to the existing `usb4_N_*` aliases.

## Runtime behaviour

- Probe resets the port, applies the tunables, deasserts local PERST, starts
  the application clock (which lets the DART probe), sets up MSI, applies
  the root-complex tunables to the root port and then waits for a tunnel.
- `TUNSTAT` bit 0 is polled (every 200 ms for 60 s after probe or a loss,
  then every second). Once it clears, the link is trained (immediately
  retried on LINK_DOWN; the first attempt on a fresh tunnel usually ends
  that way) and the bus is scanned. The host bridge is registered on the
  first link-up; scanning with the link down would fix the root port's
  bus numbers and strand switches behind it.
- Unplug or tunnel teardown raises TUNNEL_ERR/LINK_DOWN. The driver removes
  everything below the root port and waits for the next tunnel. The NVMe
  namespace is back about 3.9 s after the port is powered again.
- ASPM is disabled on every link below the root port: L1 across the tunnel
  drops the USB4 link within seconds (macOS never enables ASPM there either).
- `/sys/kernel/debug/<node>.apciec/regs`: read-only port register snapshot.
  `dyndbg="module pcie_apple_apciec +p"` adds link event and RID/SID
  messages. There are no module parameters.

## NVMe APST

Install `udev/60-apciec-nvme-apst.rules` (to `/etc/udev/rules.d/` or
`/usr/lib/udev/rules.d/`). It disables APST only for NVMe controllers behind
an APCIEC root port, by writing 0 to the controller's
`power/pm_qos_latency_tolerance_us`. With APST on, the ASM2464PD enclosure
dropped the USB4 link about 15 s after the drive went idle. The rule
matches the parent driver (`DRIVERS=="pcie-apple-apciec"`), so it does not
depend on node names, and it keys on the namespace's add event because the
controller's attribute appears only after the controller's own uevent.

In-kernel alternatives, evaluated (none needed now):

- The controller driver cannot set nvme quirks: `NVME_QUIRK_NO_APST` comes
  from nvme-pci's own ID/DMI tables, PCI fixups do not run from modules, and
  the nvme controller device (which carries the PM QoS knob) does not exist
  until nvme-pci has probed.
- A small nvme-pci change that skips APST for controllers below an
  external-facing/tunnelled port would work for every platform (macOS does
  the same for external drives), but it changes behaviour for all
  Thunderbolt NVMe and needs an upstream discussion first. Marking the
  APCIEC root port external-facing would also make the devices "untrusted",
  which switches them to strict IOMMU mode with bounce buffering, so that
  is a separate decision.
- `nvme_core.default_ps_max_latency_us=0` works but turns APST off for the
  internal drive too.

## Status and known issues

Tested (Mac Studio M1 Max, port 3, ASM2464PD + Samsung SM961, asahi-wip
7.2.11, 2026-10-20): sequential 1M QD8 reads 3079 MiB/s, 4k random
QD64x4 295k IOPS, crc32c write/verify clean, 10/10 software replugs with the
namespace back in 3.8-3.9 s, 5 min idle without link loss, 1 h filesystem
soak with 4 replugs passed (graphs: [docs/results/soak-20261020](docs/results/soak-20261020)).
An earlier version of the driver ran a 2 h soak (7 rounds, 3 replugs) and
6.4 h of a 10 h soak before the known issue below ended it.

![Throughput during the 1 h soak](docs/results/soak-20261020/throughput.png)

Drive temperature in these runs (enclosure without its heatsink) sat at the
SM961's 70 °C warning threshold under sustained load, and the drive
throttled; fit the heatsink for sustained transfers. Not tested: ports 0-2 (wired the same
way), other enclosures, M1 Pro (t6000), M1 Ultra (t6002), MacBook Pros.

Known issues, accepted for release:

- The USB4 link can drop under heavy load within about 20 s of a
  (re)connect: roughly 1 in 6 replug-then-immediate-read cycles. It is the
  USB4 PHY losing the link (ACIO firmware "Gen2/3 link error" bursts), not
  the PCIe side. In-flight I/O fails with EIO and the filesystem must be
  remounted; no corruption has been seen. An established link has run for
  hours under load without a drop.
- After such a drop the PCIe link may not come back before the ASM2464 falls
  back to USB mass storage (about 10 s after the tunnel appears). A port
  power cycle or replug recovers it. Escalating to a port cycle from the
  driver is planned.

Limitations:

- No system suspend: the USB4 series refuses suspend while a device is
  connected.
- All functions behind one port share one DART stream (`iommu-map` with
  mask 0), so they are not isolated from each other.
- No INTx (MSI/MSI-X only); multi-message MSI is not offered.
- Tunnel arrival is polled; a notification from the connection manager
  when it activates the PCIe path would replace that (the ACIO graph port 3
  is the natural place to describe the link).

## Testing

`tools/tb-soak.sh PART HOURS [REPLUG_MIN] [PORT]` makes a scratch btrfs on
PART (**destroying its contents**) and runs rounds of fio (verified random
writes, sequential and random reads) with a verified reference file, a
software replug every REPLUG_MIN minutes followed by a full scrub, and a 5 s
sampler of throughput, temperature and port state. It needs fio, btrfs-progs,
smartmontools, bc, and `tb-port-cycle`/`tipd-4cc` on the PATH for replugs.
`tools/plot-soak.py RUN_DIR` turns a run into SVG/PNG graphs (matplotlib).

## Credits

- The Apple USB4/Thunderbolt support this builds on (NHI, ACIO, atcphy USB4
  mode, tipd) is Sven Peter's series in the Asahi Linux kernel tree.
- The port programming follows `pcie-apple.c` (Alyssa Rosenzweig, Marc
  Zyngier and others); see the driver's header.
- m1n1 (Asahi Linux) provides the per-device tunables at boot.

## Licence

GPL-2.0-only (`LICENSE`), except the DT binding (GPL-2.0-only OR
BSD-2-Clause) and the DTS files (GPL-2.0+ OR MIT), as marked in each file.
