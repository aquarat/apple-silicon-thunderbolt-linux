#!/usr/bin/env bash
# Turn apciec/ into a kernel patch series on top of a kernel git tree.
#   scripts/make-patches.sh KERNEL_TREE OUT_DIR
# KERNEL_TREE must be a clean git checkout (a worktree is fine); the series
# is committed on its current branch and written to OUT_DIR with
# git format-patch. Written for asahi-wip 7.2.11; the hunks are small and
# located by context, so porting means adjusting the anchors below.
set -euo pipefail
src=$(cd -- "$(dirname -- "$0")/.." && pwd)
tree=${1:?usage: $0 KERNEL_TREE OUT_DIR}
out=${2:?usage: $0 KERNEL_TREE OUT_DIR}
cd "$tree"
git diff --quiet && git diff --cached --quiet || { echo "tree not clean"; exit 1; }
gc() { git -c user.name=aquarat -c user.email=3090997+aquarat@users.noreply.github.com commit -q "$@"; }
# Assisted-by: Documentation/process/coding-assistants.rst. Signed-off-by:
# the maintainer of this repository (DCO).
trailer='Assisted-by: Claude:claude-opus-5-5
Signed-off-by: aquarat <3090997+aquarat@users.noreply.github.com>'

# insert TEXT after the first line matching REGEX in FILE (python for safety)
ins_after() {
	python3 - "$1" "$2" "$3" <<'EOF'
import re, sys
path, regex, text = sys.argv[1:]
lines = open(path).read().split('\n')
for i, l in enumerate(lines):
    if re.search(regex, l):
        lines[i + 1:i + 1] = text.split('\n')
        break
else:
    sys.exit(f'{path}: no line matches {regex}')
open(path, 'w').write('\n'.join(lines))
EOF
}

# 1: binding
cp "$src/Documentation/devicetree/bindings/pci/apple,t6000-apciec.yaml" \
	Documentation/devicetree/bindings/pci/
ins_after MAINTAINERS '^F:\tDocumentation/devicetree/bindings/pci/apple,pcie.yaml$' \
	'F:	Documentation/devicetree/bindings/pci/apple,t6000-apciec.yaml'
git add Documentation/devicetree/bindings/pci/apple,t6000-apciec.yaml MAINTAINERS
gc -F - <<EOF
dt-bindings: pci: Add Apple T600x tunnelled PCIe controller

Each USB4/Thunderbolt port of the Apple T600x SoCs (M1 Pro/Max/Ultra) has
its own PCIe root complex with a single root port whose link is carried by
a PCIe tunnel over the USB4 link. Describe these controllers. The port's
DART only responds while the port application clock runs, so the
controller is a clock provider and the DART references that clock.

The register tunables are filled in by the bootloader.

$trailer
EOF

# 2: driver
cp "$src/drivers/pci/controller/pcie-apple-apciec.c" drivers/pci/controller/
kconfig=$(sed -n '/^config PCIE_APPLE_APCIEC/,$p' "$src/drivers/pci/controller/Kconfig.fragment")
python3 - drivers/pci/controller/Kconfig "$kconfig" <<'EOF'
import sys
path, text = sys.argv[1:]
s = open(path).read()
anchor = s.index('config PCIE_APPLE\n')
nxt = s.index('\nconfig ', anchor + 1) + 1
s = s[:nxt] + text.rstrip('\n') + '\n\n' + s[nxt:]
open(path, 'w').write(s)
EOF
ins_after drivers/pci/controller/Makefile '^obj-\$\(CONFIG_PCIE_APPLE\) \+= pcie-apple.o$' \
	'obj-$(CONFIG_PCIE_APPLE_APCIEC) += pcie-apple-apciec.o'
ins_after MAINTAINERS '^F:\tdrivers/nvmem/apple-spmi-nvmem.c$' \
	'F:	drivers/pci/controller/pcie-apple-apciec.c'
git add drivers/pci/controller MAINTAINERS
gc -F - <<EOF
PCI: apple: Add driver for the T600x tunnelled PCIe controllers

Add a host driver for the PCIe root complexes ("APCIEC") behind the
USB4/Thunderbolt ports of Apple T600x SoCs. The root port block is the one
pcie-apple.c drives, plus a tunnel reset handshake; the link only trains
while the USB4 connection manager has a PCIe tunnel set up.

The driver
 - enables the port and its application clock, applies the bootloader
   provided tunables and sets up the MSI window and RID-to-SID table as
   pcie-apple.c does,
 - waits for a tunnel (TUNSTAT), trains the link (retrying immediately on
   LINK_DOWN, which the first attempt on a new tunnel usually ends in) and
   only then scans the bus,
 - on tunnel loss (TUNNEL_ERR/LINK_DOWN interrupt) removes everything below
   the root port and restarts once a new tunnel appears,
 - provides the application clock to the port's DART, which does not
   respond without it, so the DART cannot probe early; nothing is scanned
   before the DART is bound,
 - disables ASPM on all tunnelled links: L1 across the tunnel drops the
   USB4 link.

Manual unbinding is suppressed, as in pcie-apple: unbinding the controller
would first unbind the DART (a consumer of its clock), whose device links
unbind the PCI functions parents first, and a bridge losing its driver stops
forwarding DMA for the functions below it.

Tested on a Mac Studio (M1 Max) with an ASM2464PD NVMe enclosure.

$trailer
EOF

# 3: SoC nodes
cp "$src/arch/arm64/boot/dts/apple/t600x-apciec.dtsi" arch/arm64/boot/dts/apple/
ins_after arch/arm64/boot/dts/apple/t6001.dtsi '^#include "t600x-dieX.dtsi"$' \
	'#include "t600x-apciec.dtsi"'
ins_after arch/arm64/boot/dts/apple/t6002.dtsi '^#include "t600x-dieX.dtsi"$' \
	'#include "t600x-apciec.dtsi"'
git add arch/arm64/boot/dts/apple
gc -F - <<EOF
arm64: dts: apple: t600x: Add tunnelled PCIe controllers

Add the tunnelled PCIe root complexes of USB4 ports 0-3 of die 0 and their
DARTs, disabled. Boards enable the ports they wire up.

$trailer
EOF

# 4: boards
board_bits() {	# FILE NPORTS ANCHOR_REGEX
	local f=$1 n=$2 i aliases='' nodes=''
	for ((i = 0; i < n; i++)); do
		aliases+=$'\t\t'"usb4_${i}_pcie = &apciec${i};"$'\n'
		nodes+=$'\n'"&apciec${i}_dart {"$'\n\t'"status = \"okay\";"$'\n'"};"$'\n'
		nodes+=$'\n'"&apciec${i} {"$'\n\t'"status = \"okay\";"$'\n'"};"$'\n'
	done
	ins_after "$f" "$3" "${aliases%$'\n'}"
	python3 - "$f" "$nodes" <<'EOF'
import sys
path, text = sys.argv[1:]
s = open(path).read()
anchor = s.index('/* USB4 */\n')
s = s[:anchor] + '/* Tunnelled PCIe (USB4) */\n' + text.lstrip('\n') + '\n' + s[anchor:]
open(path, 'w').write(s)
EOF
}
board_bits arch/arm64/boot/dts/apple/t600x-j375.dtsi 4 '^\t\tusb4_3_nhi = &usb4_3_nhi;$'
board_bits arch/arm64/boot/dts/apple/t600x-j314-j316.dtsi 3 '^\t\tusb4_2_nhi = &usb4_2_nhi;$'
git add arch/arm64/boot/dts/apple
gc -F - <<EOF
arm64: dts: apple: t600x-j314-j316, t600x-j375: Enable tunnelled PCIe

Enable the tunnelled PCIe controllers of the USB4 ports (0-2 on the
MacBook Pros, 0-3 on the Mac Studio) and add the usb4_N_pcie aliases the
bootloader uses to fill in their tunables.

$trailer
EOF

rm -rf "$out"
git format-patch -q -4 -o "$out"
ls "$out"
