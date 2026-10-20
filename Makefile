# SPDX-License-Identifier: GPL-2.0
# Out-of-tree build of pcie-apple-apciec against a configured kernel tree or
# installed kernel headers (kernel-devel / kernel-16k-devel):
#   make [KDIR=/lib/modules/$(uname -r)/build]
#   sudo make install        # to /lib/modules/<release>/extra, then depmod
KDIR ?= /lib/modules/$(shell uname -r)/build
KBUILD_ARGS := -C $(KDIR) M=$(CURDIR) CONFIG_PCIE_APPLE_APCIEC=m

.PHONY: all modules install clean dtbs_check
all modules:
	$(MAKE) $(KBUILD_ARGS) modules

install:
	$(MAKE) $(KBUILD_ARGS) modules_install
	depmod -a $(shell $(MAKE) -s -C $(KDIR) kernelrelease 2>/dev/null)

clean:
	$(MAKE) $(KBUILD_ARGS) clean
