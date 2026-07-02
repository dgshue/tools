#!/bin/sh

# Copyright (c) 2016-2022 Franco Fichtner <franco@opnsense.org>
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.

# rv2.sh -- raw GPT+EFI+UFS full-disk image for riscv64 boards that boot via
# an EFI loader handed off from a vendor U-Boot in SPI/flash (Orange Pi RV2 /
# SpacemiT K1).  There is no in-image bootloader to embed (no freebsd-boot,
# no U-Boot dd) -- the board's own firmware finds \EFI\BOOT\bootriscv64.efi on
# the ESP and runs the FreeBSD loader from there.  Layout mirrors the aarch64
# path of vm.sh: an EFI System Partition + a UFS root labelled gpt/rootfs.

set -e

SELF=rv2

. ./common.sh

if [ ${PRODUCT_ARCH} != riscv64 ]; then
	echo ">>> Cannot build rv2 image with arch ${PRODUCT_ARCH}"
	exit 1
fi

check_image ${SELF} ${@}

RV2SIZE="4G"
RV2SWAP="1G"

if [ -n "${1}" ]; then
	RV2SIZE=${1}
fi

if [ -n "${2}" ]; then
	if [ "${2}" != "off" -a "${2}" != "never" ]; then
		RV2SWAP=${2}
	else
		RV2SWAP=
	fi
fi

RV2IMG="${IMAGESDIR}/${PRODUCT_RELEASE}-${SELF}-${PRODUCT_ARCH}.img"
RV2BASE="rv2base"

sh ./clean.sh ${SELF}

setup_stage ${STAGEDIR} mnt

truncate -s ${RV2SIZE} ${STAGEDIR}/${RV2BASE}
DEV=$(mdconfig -t vnode -f ${STAGEDIR}/${RV2BASE})

newfs -L rootfs /dev/${DEV}
mount /dev/${DEV} ${STAGEDIR}/mnt

setup_base ${STAGEDIR}/mnt

# need the freshly-populated boot dir again later for the EFI loader
cp -R ${STAGEDIR}/mnt/boot ${STAGEDIR}

setup_kernel ${STAGEDIR}/mnt
setup_xtools ${STAGEDIR}/mnt
setup_packages ${STAGEDIR}/mnt
setup_extras ${STAGEDIR}/mnt ${SELF}
setup_entropy ${STAGEDIR}/mnt
setup_xbase ${STAGEDIR}/mnt

cat > ${STAGEDIR}/mnt/etc/fstab << EOF
# Device	Mountpoint	FStype	Options	Dump	Pass#
/dev/gpt/rootfs	/		ufs	rw	1	1
EOF

SWAPARGS=
GPTDUMMY="-p freebsd-swap::512k"

if [ -n "${RV2SWAP}" ]; then
	SWAPARGS="-p freebsd-swap/swapfs::${RV2SWAP}"
	GPTDUMMY=
	cat >> ${STAGEDIR}/mnt/etc/fstab << EOF
/dev/gpt/swapfs	none		swap	sw	0	0
EOF
fi

# EFI System Partition carrying \EFI\BOOT\bootriscv64.efi (via setup_efiboot,
# which now knows the riscv64 -> bootriscv64 mapping).
setup_efiboot ${STAGEDIR}/efiboot.img \
    ${STAGEDIR}/boot/loader.efi $((66 * 1024))

cat >> ${STAGEDIR}/mnt/etc/fstab << EOF
/dev/gpt/efifs	/boot/efi	msdosfs	rw	2	2
EOF

umount ${STAGEDIR}/mnt
mdconfig -d -u ${DEV}

echo -n ">>> Building rv2 image... "

# pure EFI: ESP first, then UFS root.  No freebsd-boot / pmbr.
(cd ${STAGEDIR}; mkimg -s gpt -o ${RV2IMG} \
    -p efi/efifs:=efiboot.img ${SWAPARGS} ${GPTDUMMY} \
    -p freebsd-ufs/rootfs:=${RV2BASE})

echo "done"

sign_image ${RV2IMG}
