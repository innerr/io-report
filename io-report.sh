#!/bin/bash

## basic spec report

function _io_test()
{
	local rw="${1}"
	local bs="${2}"
	local sec="${3}"
	local jobs="${4}"
	local file="${5}"
	local log="${6}"
	local size="${7}"

	fio -filename="${file}" -direct=1 -rw="${rw}" -size "${size}" -numjobs="${jobs}" \
		-bs="${bs}" -runtime="${sec}" -group_reporting -name=test | \
		tee -a ${log} | { grep IOPS || test $? == 1; } | awk -F ': ' '{print $2}'
}

function _io_standard()
{
	local threads="$1"
	local file="${2}"
	local log="${3}"
	local sec="${4}"
	local size="${5}"

	local wl_w=`_io_test 'write' 64k "${sec}" "${threads}" "${file}" "${log}" "${size}"`
	local wl_r=`_io_test 'read'  64k "${sec}" "${threads}" "${file}" "${log}" "${size}"`
	local wl_iops_w=`echo "${wl_w}" | awk -F ',' '{print $1}'`
	local wl_iops_r=`echo "${wl_r}" | awk -F ',' '{print $1}'`
	local wl_iotp_w=`echo "${wl_w}" | awk '{print $2}'`
	local wl_iotp_r=`echo "${wl_r}" | awk '{print $2}'`
	echo "64K, ${threads} threads: Write: ${wl_iops_w} ${wl_iotp_w}, Read: ${wl_iops_r} ${wl_iotp_r}"
}

function io_report()
{
	if [ -z "${5+x}" ]; then
		echo "[func io_report] usage: <func> test_file test_log each_test_sec test_file_size" >&2
		return 1
	fi

	local file="${1}"
	local log="${2}"
	local sec="${3}"
	local size="${4}"
	local threads="${5}"

	local iops_w=`_io_test randwrite 4k "${sec}" "${threads}" "${file}" "${log}" "${size}" | awk -F ',' '{print $1}'`
	local iops_r=`_io_test randread  4k "${sec}" "${threads}" "${file}" "${log}" "${size}" | awk -F ',' '{print $1}'`
	local iotp_w=`_io_test randwrite 4m "${sec}" "${threads}" "${file}" "${log}" "${size}" | awk '{print $2}'`
	local iotp_r=`_io_test randread  4m "${sec}" "${threads}" "${file}" "${log}" "${size}" | awk '{print $2}'`

	echo "Max: RandWrite: (4K)${iops_w} (4M)${iotp_w}, RandRead: (4K)${iops_r} (4M)${iotp_r}"

	_io_standard " 4" "${file}" "${log}" "${sec}" "${size}"
	_io_standard " 8" "${file}" "${log}" "${sec}" "${size}"
	_io_standard "16" "${file}" "${log}" "${sec}" "${size}"
	_io_standard "32" "${file}" "${log}" "${sec}" "${size}"

	rm -f "$log.w.stable"
	for ((i = 0; i < 3; i++)); do
		_io_test randwrite 64k "${sec}" "${threads}" "${file}" "${log}" "${size}" >> "$log.w.stable"
	done
	local w_stable=(`cat "$log.w.stable" | awk -F 'BW=' '{print $2}' | awk '{print $1}'`)
	echo "RandWrite stable test: (64K 8t) ["${w_stable[@]}"]"

	rm -f "$log.r.stable"
	for ((i = 0; i < 3; i++)); do
		_io_test randread 64k "${sec}" "${threads}" "${file}" "${log}" "${size}" >> "$log.r.stable"
	done
	local r_stable=(`cat "$log.r.stable" | awk -F 'BW=' '{print $2}' | awk '{print $1}'`)
	echo "RandRead stable test: (64K 8t) ["${r_stable[@]}"]"
}
export -f io_report

## latency report

function _lat_workload()
{
	local run_sec="${1}"
	local file="${2}"
	local threads="${3}"
	local bsk="${4}"
	local rw="${5}"
	local fsize="${6}"
	local run_sec=$((run_sec + 10))
	echo fio -threads="${threads}" -size="${fsize}" -bs="${bsk}k" -direct=1 -rw="rand${rw}" \
		-name=test -group_reporting -filename="${file}" -runtime="${run_sec}"
	fio -threads="${threads}" -size="${fsize}" -bs="${bsk}k" -direct=1 -rw="rand${rw}" \
		-name=test -group_reporting -filename="${file}" -runtime="${run_sec}" 1>/dev/null 2>&1
}

function _lat_collect()
{
	local run_sec="${1}"
	local disk="${2}"
	local lines=$((run_sec * 3 + 10))
	local run_time=$((run_sec + 2))
	iostat -xdm "fake-dev-for-print-header" | grep 'Dev' | head -n 1
	iostat -xdm 1 "${disk}" | head -n "${lines}" | grep "${disk}" | \
		head -n "${run_time}" | tail -n "${run_sec}" | head -n 3
}

function io_lat_report()
{
	if [ -z "${6+x}" ]; then
		echo "[func io_report] usage: <func> test_file disk_name each_test_sec bw_threads iops_threads file_size" >&2
		return 1
	fi

	local file="${1}"
	local disk="${2}"
	local run_sec="${3}"
	local bw_max_threads="${4}"
	local iops_max_threads="${5}"
	local fsize="${6}"

	local bsk="256"
	for ((i = 1; i <= ${bw_max_threads};)); do
		echo "[w_bw_${i}t]"
		_lat_workload "${run_sec}" "${file}" "${i}" "${bsk}" "write" "${fsize}" &
		_lat_collect "${run_sec}" "${disk}"
		wait
		echo "[r_bw_${i}t]"
		_lat_workload "${run_sec}" "${file}" "${i}" "${bsk}" "read" "${fsize}" &
		_lat_collect "${run_sec}" "${disk}"
		wait
		i=$((i * 2))
		bsk=$((bsk * 2))
	done
	local max_bsk="${bsk}"

	for ((i = 1; i <= ${iops_max_threads};)); do
		echo "[w_iops_${i}t]"
		_lat_workload "${run_sec}" "${file}" "${i}" "4" "write" "${fsize}" &
		_lat_collect "${run_sec}" "${disk}"
		wait
		echo "[r_iops_${i}t]"
		_lat_workload "${run_sec}" "${file}" "${i}" "4" "read" "${fsize}" &
		_lat_collect "${run_sec}" "${disk}"
		wait
		i=$((i * 2))
	done

	local bw_threads="${bw_max_threads}"
	local iops_threads="${iops_max_threads}"
	local bsk="${max_bsk}"
	for ((; 1 == 1;)); do
		echo "[w_bw_${bw_threads}t + w_iops_${iops_threads}t]"
		_lat_workload "${run_sec}" "${file}" "${bw_threads}" "${bsk}" "write" "${fsize}" &
		_lat_workload "${run_sec}" "${file}" "${io_threads}" "4" "write" "${fsize}" &
		_lat_collect "${run_sec}" "${disk}"
		wait
		local bw_threads=$((bw_threads / 2))
		local iops_threads=$((iops_threads / 2))
		local bsk=$((bsk / 2))
		if [ "${bw_threads}" == 0 ] || [ "${iops_threads}" == 0 ] || [ "${bsk}" == 0 ]; then
			break;
		fi
	done

	local bw_threads="${bw_max_threads}"
	local iops_threads="${iops_max_threads}"
	local bsk="${max_bsk}"
	for ((; 1 == 1;)); do
		echo "[w_bw_${bw_threads}t + w_iops_${iops_threads}t + r_iops_${iops_threads}t]"
		_lat_workload "${run_sec}" "${file}" "${bw_threads}" "${bsk}" "write" "${fsize}" &
		_lat_workload "${run_sec}" "${file}" "${bw_threads}" "${bsk}" "read" "${fsize}" &
		_lat_workload "${run_sec}" "${file}" "${io_threads}" "4" "write" "${fsize}" &
		_lat_collect "${run_sec}" "${disk}"
		wait
		local bw_threads=$((bw_threads / 2))
		local iops_threads=$((iops_threads / 2))
		local bsk=$((bsk / 2))
		if [ "${bw_threads}" == 0 ] || [ "${iops_threads}" == 0 ] || [ "${bsk}" == 0 ]; then
			break;
		fi
	done
}
export -f io_lat_report

## main entry

function io_trait()
{
	local file="${1}"
	local disk="${2}"

	local log="./io-report.log"
	echo "IO trait report created by [https://github.com/innerr/io-report/blob/master/io-report.sh]" > "${log}"
	echo "    host: `hostname`" >> "${log}"
	echo "    file: ${file}" >> "${log}"
	echo "    disk: ${disk}" >> "${log}"
	echo "    date: `date +%D-%T`" >> "${log}"
	echo "" >> "${log}"

	echo "==> [basic io spec report]" >> "${log}"
	io_report "${file}" "${file}.fio.tmp.log" "30" "16G" "8" >> "${log}"
	echo "" >> "${log}"
	echo "==> [cache detecting report]" >> "${log}"
	io_report "${file}" "${file}.fio.tmp.log" "15" "500M" "8" >> "${log}"
	echo "" >> "${log}"
	echo "==> [latency report]" >> "${log}"
	io_lat_report "${file}" "${disk}" "30" "64" "128" "16G" >> "${log}"
}
export -f io_trait

## user interface

set -eu
if [ -z "${2+x}" ]; then
	echo "usage: <bin> test_file_path disk_name(device_name)" >&2
	exit 1
fi
io_trait "${1}" "${2}"