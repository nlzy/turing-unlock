# SPDX-License-Identifier: GPL-2.0-only
VERSION    := $(shell cat VERSION)
NV         := 610.43.03
PYTHON     ?= python3
DESTDIR    ?=
DISTDIR    ?= build
CACHE      ?= $(HOME)/.cache/turing-unlock
INPUTS     ?= $(CACHE)/inputs
ASSETS     ?= $(CACHE)/assets
DKMSDIR    ?= /usr/src/turing-unlock-$(VERSION)
FWDIR      ?= /usr/lib/firmware/turing-unlock/$(NV)
LICENSEDIR ?= /usr/share/licenses
PKG        ?= turing-unlock
NVCC       ?= $(or $(shell command -v nvcc),/opt/cuda/bin/nvcc)
GPU        ?= 0
MIN_TFLOPS ?= 70

MODULE_FILES   := $(filter-out %.mod.c,$(sort $(wildcard kernel/turing_unlock/*.[ch]))) \
                  kernel/turing_unlock/Kbuild kernel/turing_unlock/Makefile kernel/turing_unlock/dkms.conf
FIRMWARE_FILES := booter_load_tu102.bin gsp_tu10x.bin gsp_boot_tu102.bin \
                  gsp_boot_desc_tu102.bin sec2_bl_tu102.bin v67-tu102-$(NV).bin
LICENSES       := licenses/GPL-2.0.txt licenses/NVIDIA-MIT.txt
NV_SOURCE      := NVIDIA-kernel-module-source-$(NV)
NV_UTILS       := nvidia-utils-$(NV)-1-x86_64_v3.pkg.tar.zst

TARBALL := $(abspath $(DISTDIR))/turing-unlock-$(VERSION).tar.xz
DEBDIR  := $(abspath $(DISTDIR))/deb
RPMDIR  := $(abspath $(DISTDIR))/rpm
DEBS    := $(foreach p,dkms firmware,$(DEBDIR)/turing-unlock-$(p)_$(VERSION)_all.deb)

.PHONY: all dist inputs firmware assets install-dkms install-firmware \
        install-mkinitcpio install-initramfs-tools install-dracut \
        install-licenses arch deb rpm bench install install-arch install-deb install-rpm

all:

# FP16 tensor GEMM on a card with the unlock applied (needs CUDA). GPU is a PCI
# address or CUDA index; exits non-zero if it stays under MIN_TFLOPS.
bench: $(DISTDIR)/gemm_fp16
	$(DISTDIR)/gemm_fp16 -d $(GPU) --min-tflops $(MIN_TFLOPS)

$(DISTDIR)/gemm_fp16: tests/gemm_fp16.cu
	mkdir -p $(DISTDIR)
	$(NVCC) -O2 -arch=sm_75 -o $@ $< -lcublas

# Source-only release tarball; see .gitattributes for what is left out.
dist:
	mkdir -p $(DISTDIR)
	git archive --format=tar --prefix=turing-unlock-$(VERSION)/ \
		--output=$(DISTDIR)/turing-unlock-$(VERSION).tar HEAD
	xz -9 -f $(DISTDIR)/turing-unlock-$(VERSION).tar

# Download and SHA-256 check the pinned NVIDIA inputs. makepkg does this
# itself from the PKGBUILD's source array.
inputs:
	$(PYTHON) firmware/fetch_artifacts.py $(INPUTS)

# Generate firmware from $(INPUTS) into $(ASSETS); debian/rules and the RPM
# spec call this from their build step.
firmware:
	rm -rf $(ASSETS).src
	mkdir -p $(ASSETS).src
	tar -xf $(INPUTS)/$(NV_SOURCE).tar.xz -C $(ASSETS).src
	$(PYTHON) firmware/generate_v67.py "$$(realpath $(INPUTS)/$(NV_UTILS))" $(ASSETS)
	$(PYTHON) firmware/extract_boot_assets.py $(ASSETS).src/$(NV_SOURCE) $(ASSETS)

assets: inputs
	$(MAKE) firmware

# The module source. It does nothing unless turing_unlock.targets= is on the
# kernel command line.
install-dkms:
	grep -qx 'PACKAGE_VERSION="$(VERSION)"' kernel/turing_unlock/dkms.conf
	grep -q 'MODULE_VERSION("$(VERSION)")' kernel/turing_unlock/main.c
	install -Dm644 -t $(DESTDIR)$(DKMSDIR) $(MODULE_FILES)
	install -Dm644 README.md $(DESTDIR)/usr/share/doc/turing-unlock/README.md

# The generators check every file against its pinned SHA-256 before writing it.
install-firmware:
	install -Dm644 -t $(DESTDIR)$(FWDIR) $(addprefix $(ASSETS)/,$(FIRMWARE_FILES))
	install -Dm644 $(ASSETS)/NVIDIA-LICENSE $(DESTDIR)$(LICENSEDIR)/turing-unlock-firmware/NVIDIA-LICENSE
	install -Dm644 firmware/NOTICE.md $(DESTDIR)$(LICENSEDIR)/turing-unlock-firmware/NOTICE.md

# One file per initramfs generator: include turing_unlock and its firmware in
# the image so it runs before an nvidia module loaded from the initramfs.
install-mkinitcpio:
	install -Dm644 packaging/boot/mkinitcpio.conf $(DESTDIR)/etc/mkinitcpio.conf.d/zz-turing-unlock.conf

install-initramfs-tools:
	install -Dm644 packaging/boot/initramfs-tools.conf \
		$(DESTDIR)/usr/share/initramfs-tools/modules.d/turing-unlock.conf

install-dracut:
	install -Dm644 packaging/boot/dracut.conf $(DESTDIR)/usr/lib/dracut/dracut.conf.d/turing-unlock.conf

install-licenses:
	install -Dm644 -t $(DESTDIR)$(LICENSEDIR)/$(PKG) $(LICENSES)

# Native packages, built from the committed HEAD like the PKGBUILD. The
# install-* variants also pull build dependencies and install the result.
install:
	@set -eu; \
	if [ -r /etc/os-release ]; then \
		. /etc/os-release; \
	elif [ -r /usr/lib/os-release ]; then \
		. /usr/lib/os-release; \
	fi; \
	for distro in $${ID:-} $${ID_LIKE:-}; do \
		case "$$distro" in \
			arch) target=arch ;; \
			debian|ubuntu) target=deb ;; \
			fedora|rhel|centos) target=rpm ;; \
			*) continue ;; \
		esac; \
		echo "Detected $$distro family; running make install-$$target"; \
		$(MAKE) install-$$target; \
		exit $$?; \
	done; \
	echo "Unsupported distribution: $${ID:-unknown}. Use make install-arch, install-deb, or install-rpm explicitly (RPM requires DNF)." >&2; \
	exit 1

arch:
	cd packaging/arch && makepkg -f

install-arch:
	cd packaging/arch && makepkg -sif

deb: dist inputs
	rm -rf $(DEBDIR)
	mkdir -p $(DEBDIR)
	tar -xf $(TARBALL) -C $(DEBDIR)
	cd $(DEBDIR)/turing-unlock-$(VERSION) && \
		TURING_UNLOCK_INPUTS=$(abspath $(INPUTS)) dpkg-buildpackage -us -uc

install-deb:
	sudo apt-get build-dep -y $(CURDIR)
	$(MAKE) deb
	sudo apt-get install -y $(DEBS)

rpm: dist inputs
	rm -rf $(RPMDIR)
	mkdir -p $(RPMDIR)/SOURCES
	cp $(TARBALL) $(RPMDIR)/SOURCES/
	ln -s $(abspath $(INPUTS))/$(NV_SOURCE).tar.xz $(abspath $(INPUTS))/$(NV_UTILS) $(RPMDIR)/SOURCES/
	rpmbuild -ba --define "_topdir $(RPMDIR)" packaging/rpm/turing-unlock.spec

install-rpm:
	sudo dnf install -y rpm-build
	sudo dnf builddep -y packaging/rpm/turing-unlock.spec
	$(MAKE) rpm
	sudo dnf install -y $(RPMDIR)/RPMS/noarch/turing-unlock-*-$(VERSION)-*.noarch.rpm
