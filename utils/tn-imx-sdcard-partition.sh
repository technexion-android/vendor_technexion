#!/bin/bash -e

# This script fork from imx-sdcard-partition.sh

help() {

bn=`basename $0`
cat << EOF

Version: 1.6
Last change: generate super.img when flash images with dynamic partition feature
V1.4 change: add support imx8mn chips

Usage: $bn <option> device_node

options:
  -h                displays this help message
  -s                only get partition size
  -np               not partition.
  -f soc_name       flash android image file with soc_name. Below table lists soc_name values and bootloader offset.
                           ┌────────────────────────────┬───────────────┐
                           │   soc_name                 │     offset    │
                           ├────────────────────────────┼───────────────┤
                           │ imx6dl/imx6q/imx6qp        │      1k       │
                           │ imx6sx/imx7d/imx7ulp       │               │
                           ├────────────────────────────┼───────────────┤
                           │ imx8mm/imx8mq              │      33k      │
                           ├────────────────────────────┼───────────────┤
                           │imx8qm/imx8qxp/imx8mn/imx8mp│      32k      │
                           └────────────────────────────┴───────────────┘
  -a                only flash image to slot_a
  -b                only flash image to slot_b
  -c card_size      optional setting: 7 / 14 / 28
                        If not set, use partition-table.img (default)
                        If set to  7, use partition-table-7GB.img  for  8GB SD card
                        If set to 14, use partition-table-14GB.img for 16GB SD card
                        If set to 28, use partition-table-28GB.img for 32GB SD card
                    Make sure the corresponding file exist for your platform.
  -u uboot_feature  flash uboot or spl&bootloader image files with "uboot_feature" in their names.
  -d dtb_feature    flash dtbo, recovery and vbmeta image files with "dtb_feature" in their names.
  -D directory      specify the directory which contains the images to be flashed.
  -m                flash mcu image
  -o force_offset   force set uboot offset
EOF

}

# parse command line
moreoptions=1
node="na"
soc_name=""
force_offset=""
cal_only=0
card_size=0
bootloader_offset=1
mcu_image_offset=5120
vaild_gpt_size=17
not_partition=0
slot=""
systemimage_file="system.img"
system_extimage_file="system_ext.img"
vendor_file="vendor.img"
product_file="product.img"
partition_file="partition-table.img"
super_file="super.img"
vendorboot_file="vendor_boot.img"
init_boot_file="init_boot.img"
g_sizes=0
support_dtbo=0
flash_mcu=0
RED='\033[0;31m'
STD='\033[0;0m'

if ! (command -v make_f2fs >/dev/null 2>&1 || echo ${PATH} | grep "out/host/linux-x86/bin"); then
	export PATH="$PATH:$(readlink -f $(dirname $0)/../out)/host/linux-x86/bin"
fi

image_directory=""
dtb_feature=""
uboot_feature=""
support_dual_bootloader=0
support_dualslot=0
support_dynamic_partition=0
support_vendor_boot=0
support_init_boot=0
has_system_ext_partition=0
node_device_major=""
node_device_minor=0
current_device_major=""
current_device_minor=0
minor_difference=0

if [[ ! $(id -u) -eq 0 ]]; then
    echo -e "\n${RED}WARNING: You are not superuser, which may cause some problems.${STD}"
    read -p "\nPress any key to continue, or ctrl+C to break."
fi

while [ "$moreoptions" = 1 -a $# -gt 0 ]; do
    case $1 in
        -h) help; exit ;;
        -s) cal_only=1 ;;
        -f) soc_name=$2; shift;;
        -c) card_size=$2; shift;;
        -np) not_partition=1 ;;
        -a) slot="_a" ;;
        -b) slot="_b" ;;
        -m) flash_mcu=1 ;;
        -o) force_offset=$2; shift;;
        -u) uboot_feature=-$2; shift;;
        -d) dtb_feature=$2; shift;;
        -D) image_directory=$2; shift;;
        *)  moreoptions=0; node=$1 ;;
    esac
    [ "$moreoptions" = 0 ] && [ $# -gt 1 ] \
        && echo -e >&2 "${RED}An unkonwn option \"${node}\" is used or the target flash device is not correctly specified at the end of the command ${STD}" \
        && help && exit
    [ "$moreoptions" = 1 ] && shift
done

# check required applications are installed
command -v simg2img >/dev/null 2>&1 || { echo -e >&2 "${RED}Missing simg2img app. Please run: sudo apt-get install android-tools-fsutils${STD}" ; exit 1 ; }
command -v hdparm >/dev/null 2>&1 || { echo -e >&2 "${RED}Missing hdparm app. Please make sure it is installed. Exiting.${STD}" ; exit 1 ; }
command -v gdisk >/dev/null 2>&1 || { echo -e >&2 "${RED}Missing gdisk app. Please make sure it is installed. Exiting.${STD}" ; exit 1 ; }

if [ ${card_size} -ne 0 ] && [ ${card_size} -ne 7 ] && [ ${card_size} -ne 14 ] && [ ${card_size} -ne 28 ]; then
    help; exit 1;
fi

# imx8qxp RevB0 chips, imx8qm RevB0 chips, imx8mp and imx8mn chips, bootloader offset is 32KB on SD card
if [ "${soc_name}" = "imx8qxp" -o "${soc_name}" = "imx8qm" -o "${soc_name}" = "imx8mn" -o "${soc_name}" = "imx8mp" ]; then
    bootloader_offset=32
fi

# imx8mq chips and imx8mm chips, bootloader offset is 33KB on SD card
if [ "${soc_name}" = "imx8mq" -o "${soc_name}" = "imx8mm" ]; then
    bootloader_offset=33
fi

if [ "${force_offset}" != "" ]; then
    bootloader_offset=${force_offset}
fi

# exit if the block device file specified by ${node} doesn't exist
if [ ! -e ${node} ]; then
    echo "The loop device is not set"
    help
    exit 1
fi

# Process of the uboot_feature parameter
if [[ "${uboot_feature}" = *"trusty"* ]] || [[ "${uboot_feature}" = *"secure"* ]]; then
    echo -e >&2 ${RED}Do not flash the image with Trusty OS to SD card${STD}
    help
    exit 1
fi
if [[ "${uboot_feature}" = *"dual"* ]]; then
    support_dual_bootloader=1;
fi


# dual bootloader support will use different gpt. Android Automative only boot from eMMC, judgement here is complete
if [ ${support_dual_bootloader} -eq 1 ]; then
    if [ ${card_size} -gt 0 ]; then
        partition_file="partition-table-${card_size}GB-dual.img";
    else
        partition_file="partition-table-dual.img";
    fi
else
    if [ ${card_size} -gt 0 ]; then
        partition_file="tn-android13_${card_size}GB.gpt"
        if [[ -f ${partition_file} ]]; then
            SGDISK_GPT=1
        else
            partition_file="partition-table-${card_size}GB.img";
        fi
    fi
fi


# for specified directory, make sure there is a slash at the end
if [[ "${image_directory}" = "" ]]; then
    image_directory=`pwd`;
fi
image_directory="${image_directory%/}/";

if [ ! -f "${image_directory}${partition_file}" ]; then
    echo -e >&2 "${RED}File ${partition_file} not found. Please check. Exiting${STD}"
    return 1
fi


# dump partitions
if [ "${cal_only}" -eq "1" ]; then
    sgdisk -p ${node} 2>/dev/null | grep -A 20 "Number  "
    exit 0
fi

function get_partition_size
{
    part_info=`sgdisk -p ${node} | grep -w $1`
    start_sector=`echo ${part_info} | awk '{print $2}'`
    end_sector=`echo ${part_info} | awk '{print $3}'`
    # 1 sector = 512 bytes. This will change unit from sector to MBytes.
    let "g_sizes=($end_sector - $start_sector + 1) / 2048"
}

function format_partition
{
    num=`sgdisk -p ${node} | grep -w $1 | awk '{print $1}'`
    if [ ${num} -gt 0 ] 2>/dev/null; then
        echo "format_partition: $1:${dev_p}${num} ${2:-ext4}"
        if [ "$2" != "f2fs" ]; then
            mkfs.ext4 -F "${dev_p}${num}" -L$1
        else
            # check whether make_f2fs exists
            command -v make_f2fs >/dev/null 2>&1 || { echo -e >&2 "${RED}Missing make_f2fs, fallback to erase the $1 partition ${STD}" ; erase_partition $1; return 1; }

            get_partition_size $1
            randome_part=$RANDOM
            # generate a sparse filesystem image with f2fs type and the size of the partition
            make_f2fs -S $(( g_sizes*1024*1024 )) -g android /tmp/TemporaryFile_${randome_part}
            simg2img /tmp/TemporaryFile_${randome_part} "${dev_p}${num}"
            rm /tmp/TemporaryFile_${randome_part}
        fi
    fi
}

function erase_partition
{
    num=`sgdisk -p ${node} | grep -w $1 | awk '{print $1}'`
    if [ ${num} -gt 0 ] 2>/dev/null; then
        get_partition_size $1
        echo "erase_partition: $1 : ${node}p${num} ${g_sizes}M"
        dd if=/dev/zero of="${dev_p}${num}" bs=1M conv=fsync count=${g_sizes} status=progress
    fi
}

function flash_partition
{
    for num in `gdisk -l ${node} | grep -E -w "$1|$1_a|$1_b" | awk '{print $1}'`
    do
        if [ $num -gt 0 ]; then
            if [ "$(echo ${1} | grep "bootloader_")" != "" ]; then
                img_name=${uboot_proper_file}
            elif [ ${support_vendor_boot} -eq 1 ] && [ $(echo ${1} | grep "vendor_boot") != "" ] 2>/dev/null; then
                img_name="${vendorboot_file}"
            elif [ ${support_init_boot} -eq 1 ] && [ $(echo ${1} | grep "init_boot") != "" ] 2>/dev/null; then
                img_name="${init_boot_file}"
            elif [ "$(echo ${1} | grep "system_ext")" != "" ]; then
                img_name=${system_extimage_file}
            elif [ "$(echo ${1} | grep "system")" != "" ]; then
                img_name=${systemimage_file}
            elif [ "$(echo ${1} | grep "vendor")" != "" ]; then
                img_name=${vendor_file}
            elif [ "$(echo ${1} | grep "product")" != "" ]; then
                img_name=${product_file}
            elif [ ${support_dtbo} -eq 1 ] && [ $(echo ${1} | grep "boot") != "" ] 2>/dev/null; then
                img_name="boot.img"
            elif [ "$(echo ${1} | grep -E "dtbo|vbmeta|recovery")" != "" -a "${dtb_feature}" != "" ]; then
                img_name="${1%_*}-${soc_name}-${dtb_feature}.img"
            elif [ "$(echo ${1} | grep "super")" != "" ]; then
                img_name=${super_file}
            else
                img_name="${1%_*}-${soc_name}.img"
            fi
            # check whether the image files to be flashed exist or not
            if [ ! -f "${image_directory}${img_name}" ]; then
                echo -e >&2 "${RED}File ${img_name} not found. Please check. Exiting${STD}"
                return 1
            fi
            echo "flash_partition: ${img_name} ---> ${dev_p}${num}"

            if [ "$(echo ${1} | grep "vendor_boot")" != "" ]; then
                dd if=${image_directory}${img_name} of="${dev_p}${num}" bs=10M conv=fsync,nocreat
            elif [ "$(echo ${1} | grep "system")" != "" ] || [ "$(echo ${1} | grep "vendor")" != "" ] || \
                [ "$(echo ${1} | grep "product")" != "" ] || [ "$(echo ${1} | grep "super")" != "" ]; then
                simg2img ${image_directory}${img_name} "${dev_p}${num}"
            else
                dd if=${image_directory}${img_name} of="${dev_p}${num}" bs=10M conv=fsync,nocreat
            fi
        fi
    done
}

function format_android
{
    echo "formating android images"
    format_partition metadata f2fs || return 1
    format_partition cache || return 1
    erase_partition presistdata || return 1
    erase_partition fbmisc || return 1
    erase_partition misc || return 1
    format_partition userdata f2fs || return 1
}

function make_partition
{
    echo "make gpt partition for android: ${partition_file}"
    if [[ ${SGDISK_GPT} -eq 1 ]]; then
        sgdisk -l ${image_directory}${partition_file} ${node} || return 1
    else
        dd if=${image_directory}${partition_file} of=${node} bs=1k count=${vaild_gpt_size} conv=fsync || return 1
        # backup the GPT table to last LBA for sd card. execute "gdisk ${node}" with the input characters
        # redirect standard OUTPUT to /dev/null to reduce some ouput
        echo -e 'r\ne\nY\nw\nY\nY' | gdisk ${node} 1>/dev/null
    fi
}

function flash_android
{
    boot_partition="boot"${slot}
    recovery_partition="recovery"${slot}
    system_partition="system"${slot}
    system_ext_partition="system_ext"${slot}
    vendor_partition="vendor"${slot}
    product_partition="product"${slot}
    vbmeta_partition="vbmeta"${slot}
    dtbo_partition="dtbo"${slot}
    super_partition="super"
    vendor_boot_partition="vendor_boot"${slot}
    init_boot_partition="init_boot"${slot}
    sgdisk -p ${node} 2>/dev/null | grep -q "dtbo" && support_dtbo=1
    sgdisk -p ${node} 2>/dev/null | grep -q "super" && support_dynamic_partition=1
    sgdisk -p ${node} 2>/dev/null | grep -q "vendor_boot" && support_vendor_boot=1
    sgdisk -p ${node} 2>/dev/null | grep -q "init_boot" && support_init_boot=1
    sgdisk -p ${node} 2>/dev/null | grep -q "system_ext" && has_system_ext_partition=1

    if [ ${support_dual_bootloader} -eq 1 ]; then
        bootloader_file=spl-${soc_name}${uboot_feature}.bin
        uboot_proper_file=bootloader-${soc_name}${uboot_feature}.img
        bootloader_partition="bootloader"${slot}
        flash_partition ${bootloader_partition} || exit 1
    else
        bootloader_file=u-boot-${soc_name}${uboot_feature}.imx
    fi

    if [ "${support_dtbo}" -eq "1" ] ; then
        flash_partition ${dtbo_partition} || exit 1
    fi
    if [ "${support_vendor_boot}" -eq "1" ] ; then
        flash_partition ${vendor_boot_partition} || exit 1
    fi
    if [ "${support_init_boot}" -eq "1" ] ; then
        flash_partition ${init_boot_partition} || exit 1
    fi
    flash_partition ${boot_partition}  || exit 1
    flash_partition ${recovery_partition}  || exit 1
    if [ ${support_dynamic_partition} -eq 0 ]; then
        flash_partition ${system_partition} || exit 1
        if [ ${has_system_ext_partition} -eq 1 ]; then
            flash_partition ${system_ext_partition} || exit 1
        fi
        flash_partition ${vendor_partition} || exit 1
        flash_partition ${product_partition} || exit 1
    else
        flash_partition ${super_partition} || exit 1
    fi
    flash_partition ${vbmeta_partition} || exit 1
    echo "erase_partition: uboot : ${node}"
    echo "flash_partition: ${bootloader_file} ---> ${node}"
    first_partition_offset=`sgdisk -p ${node} | grep ' 1 ' | awk '{print $2}'`
    # the unit of first_partition_offset is sector size which is 512 Byte.
    count_bootloader=`expr ${first_partition_offset} / 2 - ${bootloader_offset}`
    echo "the bootloader partition size: ${count_bootloader}"
    dd if=/dev/zero of=${node} bs=1k seek=${bootloader_offset} conv=fsync count=${count_bootloader}
    dd if=${image_directory}${bootloader_file} of=${node} bs=1k seek=${bootloader_offset} conv=fsync
    if [ "${flash_mcu}" -eq "1" ] ; then
        if [ "${soc_name}" = "imx7ulp" ]; then
            echo -e >&2 "${RED}Caution:${STD}"
            echo -e >&2 "        mcu image for imx7ulp_evk is in SPI flash on board, not in SD card, use uboot commands to flash it."
        else
            mcu_image=${soc_name#*-}"_mcu_demo.img"
            echo "flash_partition: ${mcu_image} ---> ${node}"
            dd if=${image_directory}${mcu_image} of=${node} bs=1k seek=${mcu_image_offset} conv=fsync
        fi
    fi

    echo -e "\nwipe metadata and userdata"
    erase_partition metadata
    erase_partition userdata
}

dev_p="${node}p"

if [ "${not_partition}" -eq "1" ] ; then
    echo -e "\n-------------> Generate aneroid partitions <-------------"
    # invoke make_partition to write first 17KB in partition table image to sdcard start
    make_partition || exit 1
    # unmount partitions and then force to re-read the partition table of the specified device
    sleep 3
    for i in `cat /proc/mounts | grep "${node}" | awk '{print $2}'`; do umount $i; done
    hdparm -z ${node}

    echo "-------------> Generate aneroid partitions successfully <-------------"
    exit 0
fi

# use "boot_b" to check whether dual slot is supported
sgdisk -p ${node} | grep -E -w "boot_b" 2>&1 > /dev/null && support_dualslot=1

format_android || exit 1
flash_android || exit 1

if [ "${slot}" = "_b" ]; then
    echo -e >&2 "${RED}Caution:${STD}"
    echo -e >&2 "       This script can't generate metadata to directly boot from b slot, fastboot command may need to be used to boot from b slot."
fi

echo
echo ">>>>>>>>>>>>>> Flashing successfully completed <<<<<<<<<<<<<<"

exit 0
