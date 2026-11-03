# Turing unlock

**NVIDIA Turing adaptation of [gpu-unlock](https://github.com/Zagitta/gpu-unlock)**

**Visit this page to support the original author [https://buymeacoffee.com/zagitta](https://buymeacoffee.com/zagitta)**

## WARNING

Tensor cores draw very high power. Unlocking them to full speed may damage your
hardware. **Use at your own risk.**

## Description

This is a Linux kernel module. It unlocks the full speed FP16 tensor core of the
NVIDIA TU102 GPU.

The module writes two speed selectors. SS0 becomes `0x88888888`. SS1 becomes
`0x8`. The payload also releases ACR mutex 3. Then the GPU returns through the
normal Booter finalize path.

Tested on the Dell RTX 2080 Ti 22GB (`10de:1e07`) with NVIDIA driver 575.51.03.
Both the proprietary driver and the open driver work. Other cards or other driver
is not tested.

## Windows

Windows is not covered by this module. Two independent community routes exist: a
direct UEFI port of these modules
([sargentmajord/Turing-GPU-UNLOCK](https://github.com/sargentmajord/Turing-GPU-UNLOCK)),
and a pre-driver UEFI tool that covers Turing, Ampere and Ada before the driver
loads ([physicsdolphin/nv-uefi-unlocker](https://github.com/physicsdolphin/nv-uefi-unlocker)).
Neither is maintained here.

## Performance

TFLOPS of cuBALS FP16 matrix multiply with FP32 Accumulate on RTX 2080 Ti @250W

| M.N.K | Before (%peak) | After (%peak) |
| ---: | ---: | ---:|
| 1024 | 50.3 (88.4%) | 68.3 (120.0%) |
| 2048 | 55.7 (97.9%) | 91.4 (160.6%) |
| 4096 | 53.7 (94.4%) | 81.7 (143.6%) |
| 8192 | 52.8 (92.8%) | 77.9 (136.9%) |

100%peak = 56.9 TFLOPS, claimed in *NVIDIA Turing Architecture Whitepaper*

## Install

Run these commands:

```sh
cd turing-unlock
make install
```

`make install` finds your distribution. It builds and installs the packages.
You can also choose the package type:

```sh
make install-arch   # Arch
make install-deb    # Debian or Ubuntu
make install-rpm    # Fedora or RHEL
```

`make arch`, `make deb`, and `make rpm` only build the packages. The output
goes to `build/deb` and `build/rpm`.

The build downloads two pinned NVIDIA files. It checks their SHA-256 hashes.
The files stay in `~/.cache/turing-unlock/inputs`. Use `make inputs` to download
them first. Use `INPUTS=` to set another cache directory.

## Enable the unlock

The module does nothing by default. Add one option to the kernel command line:

```
turing_unlock.targets=all
```

You can select cards by PCI address instead:

```
turing_unlock.targets=0000:21:00.0
turing_unlock.targets=0000:21:00.0,0000:22:00.0
```

`lspci -D` prints the full address. Use that name. Case does not matter.

Add the option like this:

- **GRUB (Debian/Ubuntu):** edit `GRUB_CMDLINE_LINUX_DEFAULT` in
  `/etc/default/grub`. Run `sudo update-grub`.
- **GRUB (Arch):** edit the same file. Run
  `sudo grub-mkconfig -o /boot/grub/grub.cfg`.
- **Fedora/RHEL:** run
  `sudo grubby --update-kernel=ALL --args="turing_unlock.targets=all"`.
- **systemd-boot:** add the option to the boot entry. Run `bootctl status` to
  find the entry file.
- **UKI:** add the option to `/etc/kernel/cmdline`. Rebuild the boot images.

Then reboot your system and check the result:

```sh
journalctl -k -b | grep turing_unlock
```

## Boot order

The packages put `turing_unlock` and its firmware in the initramfs. The module
loads before `nvidia` can bind a card. The packages add config files for these
tools:

- mkinitcpio: `/etc/mkinitcpio.conf.d/zz-turing-unlock.conf`
- initramfs-tools: `/usr/share/initramfs-tools/modules.d/turing-unlock.conf`
- dracut: `/usr/lib/dracut/dracut.conf.d/turing-unlock.conf`

The packages rebuild the initramfs on install and on removal.

The module skips a card with a driver. It also skips a powered-down card.
TU102 cards run one at a time. The module checks the card state. If needed,
it does a PCIe FLR first. Then `nvidia` loads and binds the card as usual.

The unlock does not reset the card when it succeeds. A failed step may reset
the card. The screen then stays blank until `nvidia-drm` takes over.

## Notes

If the GPU firmware does not stop, the module logs an error. It keeps the DMA
buffers until the next power off. Power off the machine before you try again.

The module and the packaging use GPL-2.0-only. The firmware keeps its NVIDIA
license. See `firmware/NOTICE.md` and `licenses/`.
