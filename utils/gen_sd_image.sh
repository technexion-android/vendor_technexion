#!/bin/bash

RED='\033[0;31m'
STD='\033[0;0m'

DEV_MAPPER=0

function detech_all_loop_dev() {
	echo -e "--->> Detach all loop devices relate to the ${_img_}"
	sudo kpartx -d "${_img_}" || true
	_loopdev=$(sudo losetup | grep "${_img_}" | awk '{print $1}')
	for i in ${_loopdev}; do
		sudo kpartx -d "${i}" || true
		sudo losetup -d "${i}"
		sudo rm -rf /dev/mapper/$(awk -F'/' '{print $3}' <<< ${i})*
	done
	sync
}

function msg_error {
	echo -e "${RED}ERROR: ${1}${STD}"
}

function error_exit {
	msg_error "${1}"
	detech_all_loop_dev
	false
	exit 1
}

function usage() {
	echo "Usage: $(basename $0) <platform> <sd_size>"
	exit 0
}

function create_device_mapper() {
	echo -e "--->> Create device mapper for ${1}"
	_mapper_dev="/dev/mapper/$(awk -F/ '{print $3}' <<< "${1}")"
	_partitions=$(lsblk -x MAJ:MIN --raw --output "MAJ:MIN" --noheadings "${1}")
	_cnt=0
	for i in ${_partitions}; do
		_maj=$(echo $i | cut -d: -f1)
		_min=$(echo $i | cut -d: -f2)
		if [[ ${_cnt} -eq 0 ]]; then
			sudo mknod ${_mapper_dev} b ${_maj} ${_min}
		else
			sudo mknod ${_mapper_dev}p${_cnt} b ${_maj} ${_min}
		fi
		_cnt=$((_cnt + 1))
	done
	(ls "${_mapper_dev}") || { msg_error "Invalid device mapper"; SUCCESS=0; return 1; }
	[[ -z ${2} ]] || eval ${2}="\${_mapper_dev}"
	unset _mapper_dev _min _maj _cnt _partitions
}

_platform=${1}
[[ -z ${_platform} ]] && usage
_card_size=${2}
case ${_card_size} in
	3|4)
		_dd_cnt=3400
		_dd_bs=1M
		_partition_table=3
		;;
	7|8)
		_dd_cnt=1024
		_dd_bs="7M"
		_partition_table=7
		;;
	14|15|16)
		_dd_cnt=1024
		_dd_bs="14900K"
		_partition_table=14
		;;
	28|29|32)
		_dd_cnt=1024
		_dd_bs="29M"
		_partition_table=28
		;;
	*)
		error_exit "Unsupported card size ${_card_size}"
esac

SUCCESS=1

_gen_img_sh="./tn-imx-sdcard-partition.sh"
_img_=${3:-"${_platform}_${_card_size}GB.img"}
echo -e "--->> Create a empty image ${_img_}"
sudo rm -f "${_img_}"
sudo dd if=/dev/zero of="${_img_}" bs=${_dd_bs} count=${_dd_cnt} status=progress
sync

detech_all_loop_dev

_loopdev=$(sudo losetup --find --show --partscan "${_img_}")
[[ -z ${_loopdev} ]] && error_exit "Invalid loopback device"
echo -e "--->> Loopback device: ${_loopdev}"
echo -e "--->> Generate partitions for ${_img_}"
sudo ${_gen_img_sh} -np -f "${_platform}" -c ${_partition_table} "${_loopdev}" && sync || error_exit "Create partition fail"
sudo losetup -d "${_loopdev}" && sync
unset _loopdev

echo -e "--->> Clone android image to partition"
_loopdev=$(sudo losetup --find --show --partscan "${_img_}")
(ls "${_loopdev}p1" > /dev/null) || DEV_MAPPER=1
if [[ ${DEV_MAPPER} -eq 1 ]]; then
	create_device_mapper ${_loopdev} _loopdev || error_exit "Create device mapper fail"
fi

if [[ ${SUCCESS} -eq 1 ]]; then
	sudo ${_gen_img_sh} -f "${_platform}" -c ${_partition_table} "${_loopdev}" && sync || { msg_error "generate SD image fail"; SUCCESS=0; }
fi

detech_all_loop_dev
