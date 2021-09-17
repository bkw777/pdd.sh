#!/usr/bin/env bash
# pdd.sh - Tandy Portable Disk Drive client in pure bash
# Brian K. White b.kenyon.w@gmail.com
# github.com/bkw777/pdd.sh
# https://archive.org/details/tandy-service-manual-26-3808-s-software-manual-for-portable-disk-drive
# http://bitchin100.com/wiki/index.php?title=TPDD-2_Sector_Access_Protocol
# https://trs80stuff.net/tpdd/tpdd2_boot_disk_backup_log_hex.txt

###############################################################################
# CONFIG
#

###############################################################################
# behavior

# 1 or 2 for TPDD1 or TPDD2
: ${TPDD_MODEL:=1}

# verbose/debug
# 0/unset=normal, 1=verbose, >1=more verbose, 3=log all tty traffic to files
# DEBUG=1 ./pdd ...
v=${DEBUG:-0}

# true/false - Automatically convert filenames to Floppy/Flopy2-compatible 6.2 .
# When saving, pad to %-6s.%-2s  : "A.BA"      -> "A     .BA"
# When loading, strip all spaces : "A     .BA" -> "A.BA"
# You need to do this to be compatible with Floppy, Flopy2, TS-DOS, etc.
# But the drive doesn't care, and Model T's are not the only TPDD users(1).
# So the automatic 6.2 padding can be disabled by setting this to false.
# This can be done at run-time from the commandline:
#     $> FLOPPY_COMPAT=false ./pdd save myfilename.exe
# Even when enabled, if a filename wouldn't fit within 6.2, then it is
# not modified, so enabled generally does the expected thing automatically.
# (1) TANDY WP-2, Brother knitting machines, Cambridge Z-88, MS-DOS & most OS's
: ${FLOPPY_COMPAT:=true}

# Default rs232 tty device name, with platform differences
# The automatic TPDD port detection will search "/dev/${TPDD_TTY_PREFIX}*"
			stty_f="-F" TPDD_TTY_PREFIX=ttyUSB		# linux
case "${OSTYPE,,}" in
	*bsd*) 		stty_f="-f" TPDD_TTY_PREFIX=ttyU ;;		# *bsd
	darwin*) 	stty_f="-f" TPDD_TTY_PREFIX=cu.usbserial- ;;	# osx
esac

# stty flags to set the serial port parameters & tty behavior
# For 9600-only drives like FB-100 or FDD19, change 19200 to 9600
# (FB-100/FDD19 can run at 19200 by removing the solder blob from dip switch 1)
# To disable RTS/CTS hardware flow control, change "crtscts" to "-crtscts"
: ${BAUD:=19200}
STTY_FLAGS='crtscts clocal cread raw pass8 flusho -echo'

###############################################################################
# tunables

# tty read timeout in ms
# When issuing the "read" command to read bytes from the serial port, wait this
# long (in ms) for a byte to appear before giving up.
TTY_READ_TIMEOUT_MS=50

# Default tpdd_wait() timout in ms
# Wait this long (by default) for the drive to respond after issuing a command.
# Some commands like dirent(get_first) and close can take 2 seconds to respond.
# Some commands like format take 100 seconds.
TPDD_WAIT_TIMEOUT_MS=5000
TPDD_WAIT_PERIOD_MS=100

# How long to wait for format to complete
# Usually takes just under 100 seconds.
# If you ever get a timeout while formatting, increase this by 1000 until
# you no longer get timeouts.
FORMAT_WAIT_MS=105000
FORMAT_TPDD2_EXTRA_WAIT_MS=10000

# How long to wait for delete to complete
# Delete takes from 3 to 20 seconds. Larger files take longer.
# 65534 byte file takes 20.2 seconds, so 30 seconds should be safe.
DELETE_WAIT_MS=30000

# How long to wait for close to complete
CLOSE_WAIT_MS=20000

# The initial dirent(get_first) for a directory listing
LIST_WAIT_MS=10000

# Per-byte delay in send_loader()
LOADER_PER_CHAR_MS=6

#
# CONFIG
###############################################################################

###############################################################################
# CONSTANTS
#

###############################################################################
# operating modes
typeset -ra mode=(
	[0]=fdc		# operate a TPDD1 drive in "FDC mode"
	[1]=opr		# operate a TPDD1 drive "operation mode"
	[2]=pdd2	# operate a TPDD2 drive ("operation mode" with more commands)
	[3]=loader	# send an ascii BASIC file and BASIC_EOF out the serial port
	[4]=server	# vaporware
)

###############################################################################
# "Operation Mode" constants

# Operation Mode Request/Return Block Formats
typeset -rA opr_fmt=(
	# requests
	[req_dirent]='00'
	[req_open]='01'
	[req_close]='02'
	[req_read]='03'
	[req_write]='04'
	[req_delete]='05'
	[req_format]='06'
	[req_status]='07'
	[req_fdc]='08'
	[req_condition]='0C'		# TPDD2
	[req_sector_cache]='30'		# TPDD2
	[req_write_cache]='31'		# TPDD2
	[req_read_cache]='32'		# TPDD2
	# returns
	[ret_read]='10'
	[ret_dirent]='11'
	[ret_std]='12'	# error open close delete status write
	[ret_condition]='15'		# TPDD2
	[ret_pdd2_sector_std]='38'	# TPDD2 sector_cache write_cache
	[ret_read_cache]='39'		# TPDD2
)

# Operation Mode Error Codes
typeset -rA opr_msg=(
	[00]='Operation Complete'
	[10]='File Not Found'
	[11]='File Exists'
	[30]='Command Parameter or Sequence Error'
	[31]='Directory Search Error'
	[35]='Bank Error'
	[36]='Parameter Error'
	[37]='Open Format Mismatch'
	[3F]='End of File'
	[40]='No Start Mark'
	[41]='ID CRC Check Error'
	[42]='Sector Length Error'
	[43]='Read Error 3'
	[44]='Format Verify Error'
	[45]='Disk Not Formatted'
	[46]='Format Interruption'
	[47]='Erase Offset Error'
	[48]='Read Error 8'
	[49]='DATA CRC Check Error'
	[4A]='Sector Number Error'
	[4B]='Read Data Timeout'
	[4C]='Read Error C'
	[4D]='Sector Number Error'
	[4E]='Read Error E'
	[4F]='Read Error F'
	[50]='Write-Protected Disk'
	[5E]='Disk Not Formatted'
	[60]='Disk Full or Max File Size Exceeded or Directory Full' # TPDD2 'Directory Full'
	[61]='Disk Full'
	[6E]='File Too Long'
	[70]='No Disk'
	[71]='Disk Not Inserted or Disk Change Error' # TPDD2 'Disk Change Error'
	[72]='Disk Insertion Error 2'
	[73]='Disk Insertion Error 3'
	[74]='Disk Insertion Error 4'
	[75]='Disk Insertion Error 5'
	[76]='Disk Insertion Error 6'
	[77]='Disk Insertion Error 7'
	[78]='Disk Insertion Error 8'
	[79]='Disk Insertion Error 9'
	[7A]='Disk Insertion Error A'
	[7B]='Disk Insertion Error B'
	[7C]='Disk Insertion Error C'
	[7D]='Disk Insertion Error D'
	[7E]='Disk Insertion Error E'
	[7F]='Disk Insertion Error F'
	[80]='Hardware Fault 0'
	[81]='Hardware Fault 1'
	[82]='Hardware Fault 2'
	[83]='Defective Disk (power-cycle to clear error)'
	[84]='Hardware Fault 4'
	[85]='Hardware Fault 5'
	[86]='Hardware Fault 6'
	[87]='Hardware Fault 7'
	[88]='Hardware Fault 8'
	[89]='Hardware Fault 9'
	[8A]='Hardware Fault A'
	[8B]='Hardware Fault B'
	[8C]='Hardware Fault C'
	[8D]='Hardware Fault D'
	[8E]='Hardware Fault E'
	[8F]='Hardware Fault F'
)

# Directory Entry Search Forms
typeset -rA dirent_cmd=(
	[set_name]=0
	[get_first]=1
	[get_next]=2
)

# File Open Access Modes
typeset -rA open_mode=(
	[write_new]=1
	[write_append]=2
	[read]=3
)

###############################################################################
# "FDC Mode" constants

# FDC Mode Commands
typeset -rA fdc_cmd=(
	[mode]='M'
	[condition]='D'
	[format]='F'
	[format_nv]='G'
	[read_id]='A'
	[read_sector]='R'
	[search_id]='S'
	[write_id]='B'
	[write_id_nv]='C'
	[write_sector]='W'
	[write_sector_nv]='X'
)

# FDC Mode Errors
# There is no documentation for the FDC error codes
# These are guesses from experimenting
typeset -ra fdc_msg=(
	[0]='OK'
	[17]='Logical Sector Number Below Range'
	[18]='Logical Sector Number Above Range'
	[19]='Physical Sector Number Above Range'
	[33]='Parameter Invalid, Wrong Type'
	[50]='Invalid Logical Sector Size Code'
	[51]='Logical Sector Size Code Above Range'
	[160]='Disk Not Formatted'
	[161]='Read Error'
	[176]='Write-Protected Disk'
	[193]='Invalid Command'
	[209]='Disk Not Inserted'
)

# FDC Format Disk Logical Sector Size Codes
typeset -ra fdc_format_sector_size=(
	[0]=64
	[1]=80
	[2]=128
	[3]=256
	[4]=512
	[5]=1024
	[6]=1280
)

###############################################################################
# general constants

typeset -ri \
	PHYSICAL_SECTOR_LENGTH=1280 \
	PHYSICAL_SECTOR_COUNT=80 \
	PDD1_SECTOR_ID_LENGTH=12 \
	TPDD_MAX_FILE_LENGTH=65534 \
	TPDD_MAX_FILE_COUNT=40 \
	PDD2_SECTOR_CHUNK_LENGTH=64 \
	SMT_OFFSET=1240 \
	SMT_LENGTH=20

typeset -r BASIC_EOF='1A'

#
# CONSTANTS
###############################################################################

###############################################################################
# generic/util functions

abrt () {
	echo "$0: $@" >&2
	exit 1
}

vecho () {
	local -i l="$1" ;shift
	((v>=l)) && echo "$@" >&2
	:
}

_sleep () {
	local x
	read -t ${1:-1} -u 4 x
	:
}

# Milliseconds to seconds, up to 999999ms
ms_to_s () {
	((_s=1000000+$1))
	_s="${_s:1:-3}.${_s: -3}"
}

# Convert a plain text string to hex pairs stored in shex[]
str_to_shex () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	local x="$*" ;local -i i l=${#x} ;shex=()
	for ((i=0;i<l;i++)) { printf -v shex[i] '%02X' "'${x:i:1}" ; }
	vecho 1 "$z: shex=(${shex[*]})"
}

# Read a local file into hex pairs stored in fhex[]
file_to_fhex () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	local x ;fhex=()

	[[ -r "$1" ]] || { err_msg+=("\"$1\" not found") ;return 1 ; }

	exec 5<"$1" || return $?
	while IFS= read -d '' -r -n 1 -u 5 x ;do
		printf -v x '%02X' "'$x"
		fhex+=($x)
		((${#fhex[*]}>TPDD_MAX_FILE_LENGTH)) && { err_msg+=("\"$1\" exceeds $TPDD_MAX_FILE_LENGTH bytes") ; break ; }
	done
	exec 5<&-

	((${#err_msg[*]})) && return 1
	vecho 1 "$z: bytes read: ${#fhex[*]}"
}

# Progress indicator
# pbar part whole [units]
#   pbar 14 120
#   [####====================================] 11%
#   pbar 14 120 seconds
#   [####====================================] 11% (14/120 seconds)
pbar () {
	((v)) && return
	local -i i c p=$1 w=$2 p_len w_len=40 ;local b= s= u=$3
	((w)) && c=$((p*100/w)) p_len=$((p*w_len/w)) || c=100 p_len=$w_len
	for ((i=0;i<w_len;i++)) { ((i<p_len)) && b+='#' || b+='.' ; }
	printf '\r%79s\r[%s] %d%%%s ' '' "$b" "$c" "${u:+ ($p/$w $u)}"
}

# Busy-indicator
typeset -ra _Y=('-' '\' '|' '/')
spin () {
	((v)) && return
	case "$1" in
		'+') printf '  ' ;;
		'-') printf '\b\b  \b\b' ;;
		*) printf '\b\b%s ' "${_Y[_y]}" ;;
	esac
	((++_y>3)) && _y=0
}

_init () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((_om==operation_mode)) && return
	_om=${operation_mode}
	case "${mode[operation_mode]}" in
		fdc|opr)
			# ensure we always leave the drive in operation mode
			trap 'fcmd_mode 1' EXIT
			# ensure we always start in operation mode
			fcmd_mode 1
			;;
		*)
			trap '' EXIT
			;;
	esac
}

###############################################################################
# Main Command Dispatcher

do_cmd () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	local -i _i _e ;local _a=$@ _c ifs=$IFS IFS=';' ;_a=(${_a}) IFS=$ifs
	for ((_i=0;_i<${#_a[*]};_i++)) {
		set ${_a[_i]}
		_c=$1 ;shift
		_e=999 err_msg=() exit=exit

		vecho 2 "$z: ${_c} $@"

	# commands that do not need _init()
		case "${_c}" in
			1|pdd1|tpdd1) pdd2=0 operation_mode=1 exit=: _e=$? ;;
			2|pdd2|tpdd2) pdd2=1 operation_mode=2 exit=: _e=$? ;;
			b|bank) ((pdd2)) && bank=$1 exit=: _e=$? || abrt "${_c} requires TPDD2" ;;
			baud|speed) BAUD=$1 _e=$? ;;
			com_test) lcmd_com_test ;_e=$? ;; # check if port open
			com_open) lcmd_com_open ;_e=$? ;; # open the port
			com_close) lcmd_com_close ;_e=$? ;; # close the port
			sync|drain) tpdd_drain ;_e=$? ;;
			sum) calc_cksum $* ;_e=$? ;;
			ocmd_check_err) ocmd_check_err ;_e=$? ;;
			send_loader) srv_send_loader "$@" ;_e=$? ;;
			sleep) _sleep $* ;_e=$? ;;
			debug) ((${#1})) && v=$1 || { ((v)) && v=0 || v=1 ; } ;exit=: _e=$? ;;
			q|quit|bye|exit) exit ;;
			pdd1_boot) pdd1_boot "$@" ;_e=$? ;; # wip
			pdd2_boot) pdd2_boot "$@" ;_e=$? ;; # [100|200]
			'') _e=0 ;;
		esac
		((_e<256)) && {
			((${#err_msg[*]})) && printf '\n%s: %s\n' "${_c}" "${err_msg[*]}" >&2
			continue
		}

	# commands that need _init()
		_e=0
		_init

		case "${_c}" in

	# operation-mode commands
	# TPDD1 & TPDD2 file access
	# All of the drive firmware "operation mode" functions.
	# Most of these are low-level, not used directly by a user.
	# Higher-level commands like ls, load, & save are built out of these.
			dirent) ocmd_dirent "$@" ;_e=$? ;;
			open) ocmd_open $* ;_e=$? ;;
			close) ocmd_close ;_e=$? ;;
			read) ocmd_read $* ;_e=$? ;;
			write) ocmd_write $* ;_e=$? ;;
			delete) ocmd_delete ;_e=$? ;;
			format) ocmd_format ;_e=$? ;;
			status) ocmd_status ;_e=$? ;((_e)) || echo "OK" ;;

	# TPDD1-only operation-mode command to switch to fdc-mode
			fdc) ocmd_fdc ;_e=$? ; exit=: ;;

	# fdc-mode commands
	# TPDD1 sector access
	# All of the drive firmware "FDC mode" functions.
			${fdc_cmd[mode]}|mode) fcmd_mode $* ;_e=$? ;exit=: ;; # select operation-mode or fdc-mode
			${fdc_cmd[condition]}|condition) ((pdd2)) && { pdd2_condition $* ;_e=$? ; } || { fcmd_condition $* ;_e=$? ; } ;; # get drive condition
			${fdc_cmd[format]}|fdc_format|ff) fcmd_format $* ;_e=$? ;; # format disk - selectable sector size
			#${fdc_cmd[format_nv]}|format_nv) fcmd_format_nv $* ;_e=$? ;; # format disk no verify
			${fdc_cmd[read_id]}|read_id|ri) fcmd_read_id $* ;_e=$? ;; # read id
			${fdc_cmd[read_sector]}|read_logical|rl) fcmd_read_logical $* ;_e=$? ;; # read one logical sector
			#${fdc_cmd[search_id]}|search_id|si) fcmd_search_id $* ;_e=$? ;; # search id
			${fdc_cmd[write_id]}|write_id|wi) fcmd_write_id $* ;_e=$? ;; # write id
			#${fdc_cmd[write_id_nv]}|write_id_nv) fcmd_write_id_nv $* ;_e=$? ;; # write id no verify
			${fdc_cmd[write_sector]}|write_logical|wl) fcmd_write_logical $* ;_e=$? ;; # write sector
			#${fdc_cmd[write_sect_nv]}|write_sector_nv) fcmd_write_sector_nv $* ;_e=$? ;; # write sector no verify

	# TPDD2 sector access
			read_cache) pdd2_read_cache $* ;_e=$? ;;		# read from cache
			write_cache) lcmd2_write_cache $* ;_e=$? ;;		# write to cache
			sector_cache) pdd2_sector_cache $* ;_e=$? ;;	# copy sector between disk & cache

	# TPDD1 & TPDD2 local/client commands
			ls|dir) lcmd_ls "$@" ;_e=$? ;;
			rm|del) lcmd_rm "$@" ;_e=$? ;;
			load) lcmd_load "$@" ;_e=$? ;;
			save) lcmd_save "$@" ;_e=$? ;;
			mv|ren) lcmd_mv "$@" ;_e=$? ;;
			cp|copy) lcmd_cp "$@" ;_e=$? ;;
			rp|read_physical) ((pdd2)) || { pdd1_read_physical "$@" ;_e=$? ; } ;;
			dd|dump_disk) ((pdd2)) && { pdd2_dump_disk "$@" ;_e=$? ; } || { pdd1_dump_disk "$@" ;_e=$? ; } ;;
			rd|restore_disk) ((pdd2)) && { pdd2_restore_disk "$@" ;_e=$? ; } || { pdd1_restore_disk "$@" ;_e=$? ; } ;;

	# low level manual raw/debug commands
			tpdd_read) tpdd_read $* ;_e=$? ;; # read $1 bytes
			tpdd_write) tpdd_write $* ;_e=$? ;; # write $* (hex pairs)
			ocmd_send_req) ocmd_send_req $* ;_e=$? ;;
			ocmd_read_ret) ocmd_read_ret $* ;_e=$? ;;
			read_smt) read_smt $* ;_e=$? ;;


			*) echo "Unknown command: \"${_c}\"" >&2 ;;
		esac
		((${#err_msg[*]})) && printf '\n%s: %s\n' "${_c}" "${err_msg[*]}" >&2
	}
	return ${_e}
}

###############################################################################
# experimental junk

tpdd_read_BASIC () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	local x e ;printf -v e '%b' "\x$BASIC_EOF"
	tpdd_wait
	while read -r -t 2 -u 3 x ;do
		printf '%s\n' "$x"
		[[ "${x: -1}" == "$e" ]] && break
	done
}

# Emulate a client performing the TPDD1 boot sequence
pdd1_boot () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((pdd2)) && abrt "$z requires TPDD1"
	local REPLY M mdl=${1:-100}

	close_com
	open_com 9600

	echo -en " Turn the drive power OFF.\n" \
		"Set all 4 dip switches to ON.\n" \
		"Turn the drive power ON.\n" \
		"Press [Enter] when ready: " >&2
	read -s ;echo

	echo
	echo "0' $0: $z($@)"
	echo "0' TPDD1 Boot Sequence - Model $mdl"

	str_to_shex 'S10985157C00AD7EF08B3AS901FE'
	tpdd_write ${shex[*]} 0D

	tpdd_read_BASIC
	echo

	# 10 PRINT"---INITIAL PROGRAM LOADER---"
	# 20 PRINT"      WAIT A MINUTE!":CLOSE
	close_com

	# 30 IF PEEK(1)=171 THEN M2=1 ELSE M2=0
	#   Model 102: 167 -> M2=0
	#   Model 200: 171 -> M2=1
	case "$mdl" in
		"200") M='01' ;;
		*) M='00' ;;
	esac

	# 40 OPEN "COM:88N1DNN" FOR OUTPUT AS #1
	open_com 9600

	# 50 ?#1,"KK"+CHR$(M2);
	#   no trailing CR or LF
	tpdd_write 4B 4B $M

	# 60 FOR I=1 TO 10:NEXT:CLOSE
	#   1000 = 2 seconds
	_sleep 0.02
	close_com

	# 70 LOAD "COM:88N1ENN",R
	open_com 9600
	tpdd_read_BASIC
	echo

	echo -en " Turn the drive power OFF.\n" \
		"Set all 4 dip switches to OFF.\n" \
		"Turn the drive power ON.\n" \
		"Press [Enter] when ready: " >&2
	read -s ;echo

}

# Emulate a client performing the TPDD2 boot sequence
# pdd2_boot [100|200]
pdd2_boot () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((pdd2)) || abrt "$z requires TPDD2"
	local M mdl=${1:-100}

	echo
	echo "0' $0: $z($@)"
	echo "0' TPDD2 Boot Sequence - Model $mdl"

	# RUN "COM:98N1ENN"
	tpdd_read_BASIC

	# 10 CLS:?"---INITIAL PROGRAM LOADER II---
	# 20 ?"      WAIT A MINUTE!":CLOSE
	close_com
	echo

	# 30 IF PEEK(1)=171 THEN M=4 ELSE M=3
	#   Model 102: 167 -> M=3
	#   Model 200: 171 -> M=4
	case "$mdl" in
		"200") M='04' ;;
		*) M='03' ;;
	esac

	# 40 OPEN"COM:98N1DNN" FOR OUTPUT AS #1
	open_com

	# 50 ?#1,"FF";CHR$(M);
	#   no trailing CR or LF
	tpdd_write 46 46 $M

	# 60 FOR I=1 TO 10:NEXT:CLOSE
	#   1000 = 2 seconds
	_sleep 0.02
	close_com

	# 70 RUN"COM:98N1ENN
	open_com
	tpdd_read_BASIC
	echo
}

###############################################################################
# serial port operations

get_tpdd_port () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	local x=(/dev/${TPDD_TTY_PREFIX#/dev/}*)
	[[ "${x[0]}" == "/dev/${TPDD_TTY_PREFIX}*" ]] && x=(/dev/tty*)
	((${#x[*]}==1)) && { PORT=${x[0]} ;return ; }
	local PS3="Which serial port is the TPDD drive on? "
	select PORT in ${x[*]} ;do [[ -c "$PORT" ]] && break ;done
}

test_com () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	{ : >&3 ; } 2>&-
}

open_com () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	local b=${1:-$BAUD}
	test_com && return
	exec 3<>"${PORT}"
	stty ${stty_f} "${PORT}" $b ${STTY_FLAGS}
	test_com || abrt "Failed to open serial port \"${PORT}\""
}

close_com () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	exec 3>&-
}

###############################################################################
# TPDD communication primitives

# write $* to com port as binary
tpdd_write () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	local x=$*
	((v==9)) && { local c=$((10000+seq++)) ;printf '%b' "\x${x// /\\x}" >${0##*/}.$$.${c#?}.$z ; }
	printf '%b' "\x${x// /\\x}" >&3
}

# read $1 bytes from com port
# store each byte as a hex pair in global rhex[]
#
# We need to read binary data from the drive. The special problem with handling
# binary data in shell is that it's not possible to store or retrieve null/0x00
# bytes in a shell variable. All other values can be handled with a little care.
#
# But we can *detect* null bytes and we can store the knowledge of them instead.
#
# LANG=C IFS= read -r -d $'\0' gets us all bytes except 0x00.
#
# To get the 0x00's what we do here is tell read() to treat null as the
# delimiter, then read one byte at a time for the expected number of bytes (in
# the case of TPDD, we always know the expected number of bytes, but we could
# also read until end of data). For each read, the variable holding the data
# will be empty if we read a 0x00 byte, or if there was no data. For each byte
# that comes back empty, look at the return value from read() to tell whether
# the drive sent a 0x00 byte, or if the drive didn't send anything.
#
# Thanks to Andrew Ayers in the M100 group on Facebook for help finding the key trick.
#
# return value from "read" is crucial to distiguish a timeout from a null byte
# $?=0 = we read a non-null byte normally, $x contains a byte
#    1 = we read a null byte, $x is empty because we ate the null as a delimiter
# >128 = we timed out, $x is empty because there was no data, not even a null
tpdd_read () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	local -i i l=$1 ;local x ;rhex=() read_err=0
	[[ "$2" ]] && tpdd_wait $2 $3
	vecho 2 -n "$z: l=$l "
	l=${1:-$TPDD_MAX_FILE_LENGTH}
	for ((i=0;i<l;i++)) {
		tpdd_wait
		x=
		IFS= read -d '' -r -t $read_timeout -n 1 -u 3 x ;read_err=$?
		((read_err==1)) && rhex[i]='00' read_err=0
		((read_err)) && break
		printf -v rhex[i] '%02X' "'$x"
		vecho 2 -n "$i:${rhex[i]} "
	}
	((v==9)) && { local c=$((10000+seq++)) ;x="${rhex[*]}" ;printf '%b' "\x${x// /\\x}" >${0##*/}.$$.${c#?}.$z ; }
	((read_err>1)) && vecho 2 "read_err:$read_err" || vecho 2 ''
}

# check if data is available without consuming any
tpdd_check () {
	local z=${FUNCNAME[0]} ;vecho 2 "$z($@)"
	IFS= read -t 0 -u 3
}

# wait for data
# tpdd_wait timeout_ms busy_indication
# sleep() but periodically check the drive
# return once the drive starts sending data
tpdd_wait () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	local d=(: spin pbar) s
	local -i i=-1 n p=$TPDD_WAIT_PERIOD_MS t=${1:-$TPDD_WAIT_TIMEOUT_MS} b=$2
	ms_to_s $p ;s=$_s
	((t<p)) && t=p ;n=$(((t+50)/p))
	((b==1)) && spin +
	until ((++i>n)) ;do
		tpdd_check && break
		${d[b]} $i $n
		_sleep $s
	done
	((i>n)) && abrt "TIMED OUT"
	${d[b]} 1 1
	((b==1)) && spin -
	((b)) && echo
	vecho 1 "$z: $@:$((i*p))"
}

# Drain output from the drive to get in sync with it's input vs output.
tpdd_drain () {
	local z=${FUNCNAME[0]} ;vecho 2 "$z($@)"
	local x
	while tpdd_check ;do
		IFS= read -d '' -r -t $read_timeout -u 3 x
		((v>1)) && printf '%02X:%u:%s\n' "'$x" "'$x" "$x"
	done
}

###############################################################################
#                             OPERATION MODE                                  #
###############################################################################
#
# operation-mode transaction format reference
#
# request block
#
#   preamble  2 bytes       5A5A
#   format    1 byte        type of request block
#   length    1 byte        length of data in bytes
#   data      0-128 bytes   data
#   checksum  1 byte        1's comp of LSByte of sum of format through data
#
# return block
#
#   format    1 byte        type of return block
#   length    1 byte        length of data in bytes
#   data      0-128 bytes   data
#   checksum  1 byte        1's comp of LSByte of sum of format through data

###############################################################################
# "Operation Mode" support functions

# calculate the checksum of $* (hex pairs)
# return in global $cksum (hex pair)
calc_cksum () {
	local z=${FUNCNAME[0]} ;vecho 1 -n "$z($@):"
	local -i s=0
	while (($#)) ;do ((s+=16#$1)) ;shift ;done
	((s=(s&255)^255))
	printf -v cksum '%02X' $s
	vecho 1 "$cksum"
}

# verify the checksum of a received packet
# $* = data data data... csum  (hex pairs)
verify_checksum () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	local -i l=$(($#-1)) ;local x= h=($*)
	x=${h[l]} ;h[l]=
	calc_cksum ${h[*]}
	vecho 1 "$z: $x=$cksum"
	((16#$x==16#$cksum))
}

# check if a ret_std format response was ok (00) or error
ocmd_check_err () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	local -i e ;local x
	vecho 1 "$z: ret_fmt=$ret_fmt ret_len=$ret_len ret_dat=(${ret_dat[*]}) read_err=\"$read_err\""
	((${#ret_dat[*]}==1)) || { err_msg+=('Corrupt Response') ; ret_dat=() ;return 1 ; }
	vecho 1 -n "$z: ${ret_dat[0]}:"
	((e=16#${ret_dat[0]}))
	x='OK'
	((e)) && {
		x='UNKNOWN ERROR'
		((${#opr_msg[${ret_dat[0]}]})) && x="${opr_msg[${ret_dat[0]}]}"
		ret_err=${ret_dat[0]}
		err_msg+=("$x")
	}
	vecho 1 "$x"
	return $e
}

# build a valid operation-mode request block and send it to the tpdd
# 5A 5A format length data checksum
# fmt=$1  data=$2-*
ocmd_send_req () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((operation_mode)) || fcmd_mode 1
	local fmt=$1 len ;shift
	printf -v len '%02X' $#
	calc_cksum $fmt $len $*
	vecho 1 "$z: fmt=\"$fmt\" len=\"$len\" dat=\"$*\" sum=\"$cksum\""
	tpdd_write 5A 5A $fmt $len $* $cksum
}

# read an operation-mode return block from the tpdd
# parse it into the parts: format, length, data, checksum
# verify the checksum
# return the globals ret_fmt, ret_len, ret_dat[], ret_sum
# $* is appended to the first tpdd_read() args (timeout_ms busy_indicator)
ocmd_read_ret () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	local -i t ;local l x ;ret_fmt= ret_len= ret_dat=() ret_sum=

	vecho 1 "$z: reading 2 bytes (fmt len)"
	tpdd_read 2 $* || return $?
	vecho 1 "$z: (${rhex[*]})"
	((${#rhex[*]}==2)) || return 1
	[[ "$ret_list" =~ \|${rhex[0]}\| ]] || abrt 'INVALID RESPONSE'
	ret_fmt=${rhex[0]} ret_len=${rhex[1]}

	((l=16#${ret_len:-00}))
	vecho 1 "$z: reading 0x$ret_len($l) bytes (data)"
	tpdd_read $l || return $?
	((${#rhex[*]}==l)) || return 3
	ret_dat=(${rhex[*]})
	vecho 1 "$z: data=(${ret_dat[*]})"

	vecho 1 "$z: reading 1 byte (checksum)"
	tpdd_read 1 || return $?
	((${#rhex[*]}==1)) || return 4
	ret_sum=${rhex[0]}
	vecho 1 "$z: cksum=$ret_sum"

	# compute the checksum and verify it matches the supplied checksum
	verify_checksum $ret_fmt $ret_len ${ret_dat[*]} $ret_sum || abrt 'CHECKSUM FAILED'
}

# Space-pad or truncate $1 to 24 bytes.
# If in "Floppy Compatible" mode, and if the filename is already 6.2 or less,
# then also space-pad to %-6s.%-2s within that. Return in global tpdd_file_name
# normal       : "hi.bat"                -> "hi.bat                  "
# floppy_compat: "A.CO"   -> "A     .CO" -> "A     .CO               "
# floppy_compat: "Floppy_SYS"            -> "Floppy_SYS              "
mk_tpdd_file_name () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	local -i e ;local x t f="$1" ;tpdd_file_name=

	$FLOPPY_COMPAT && {
		t=${1%.*} x=${1##*.}
		[[ "$1" =~ \. ]] && ((${#t})) && ((${#t}<7)) && ((${#x}<3)) && printf -v f '%-6s.%-2s' "$t" "$x"
	}

	printf -v tpdd_file_name '%-24.24s' "$f"
}

# Un-pad a padded 6.2 on-disk filename to it's normal form.
# If in "Floppy Compatible" mode, and the filename would fit within 6.2, then
# collapse the internal spaces.
un_tpdd_file_name () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	local f= x= ;file_name="$1"

	$FLOPPY_COMPAT && {
		f=${file_name// /} ;x=${f##*.} ;f=${f%.*}
		[[ "$1" =~ \. ]] && ((${#f})) && ((${#f}<7)) && ((${#x}<3)) && printf -v file_name '%s.%s' "$f" "$x"
	}
	:
}

###############################################################################
# "Operation Mode" drive functions
# wrappers for each "operation mode" function of the drive firmware

# directory entry
# fmt = 00
# len = 1a
# filename = 24 bytes
# attribute = "F" (always F for any file, null for unused entries)
# search form = 00=set_name | 01=get_first | 02=get_next
ocmd_dirent () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	local -i e w=10000 ;local r=${opr_fmt[req_dirent]} x f="$1" m=${3:-${dirent_cmd[get_first]}}
	drive_err= file_name= file_attr= file_len= free_sectors=
	((operation_mode)) || fcmd_mode 1

	# if tpdd2 bank 1, add 0x40 to opr_fmt[req]
	((bank)) && printf -v r '%02X' $((16#$r+16#40))

	# construct the request
	mk_tpdd_file_name "$f"			# pad/truncate filename
	str_to_shex "$tpdd_file_name"		# filename (shex[0-23])
	printf -v shex[24] '%02X' "'${2:-F}"	# attribute - always "F"
	printf -v shex[25] '%02X' $m		# search form (set_name, get_first, get_next)

	# send the request
	ocmd_send_req $r ${shex[*]} || return $?

	((m==${dirent_cmd[get_first]})) && w=$LIST_WAIT_MS

	# read the response
	ocmd_read_ret $w || return $?

	# check which kind of response we got
	case "$ret_fmt" in
		"${opr_fmt[ret_std]}") ocmd_check_err || return $? ;;	# got a valid error return
		"${opr_fmt[ret_dirent]}") : ;;				# got a valid dirent return
		*) abrt "$z: Unexpected Return" ;;		# got no valid return
	esac
	((${#ret_dat[*]}==28)) || abrt "$z: Got ${#ret_dat[*]} bytes, expected 28"

	# parse a dirent return format
	x="${ret_dat[*]:0:24}" ;printf -v file_name '%-24.24b' "\x${x// /\\x}"
	printf -v file_attr '%b' "\x${ret_dat[24]}"
	((file_len=16#${ret_dat[25]}*256+16#${ret_dat[26]}))
	((free_sectors=16#${ret_dat[27]}))
	vecho 1 "$z: mode=$m filename=\"$file_name\" attr=\"$file_attr\" len=$file_len free=$free_sectors"

	# If doing set_name, and we got this far, then return success. Only the
	# caller knows if they expected file_name & file_attr to be null or not.
	((m==${dirent_cmd[set_name]})) && return 0

	# If doing get_first or get_next, filename[0]=00 means no more files.
	((16#${ret_dat[0]}))
}

# Get Drive Status
# request: 5A 5A 07 00 ##
# return : 07 01 ?? ##
ocmd_status () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((operation_mode)) || fcmd_mode 1
	ocmd_send_req ${opr_fmt[req_status]} || return $?
	ocmd_read_ret || return $?
	ocmd_check_err || return $?
}

# Operation-Mode Format Disk
#request: 5A 5A 06 00 ##
#return : 12 01 ?? ##
# "operation-mode" format is somehow special and different from FDC-mode format.
# It creates 64-byte logical sectors, but if you use the FDC-mode format command
# "ff 0" to format with 64-byte logical sectors, and then try save a file,
# "ls" will show the file's contents were written into the directory sector.
ocmd_format () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((operation_mode)) || fcmd_mode 1
	local -i w=$FORMAT_WAIT_MS
	((pdd2)) && {
		((w+=FORMAT_TPDD2_EXTRA_WAIT_MS))
		echo "Formatting Disk, TPDD2 mode"
	} || {
		echo "Formatting Disk, TPDD1 \"operation\" mode"
	}
	ocmd_send_req ${opr_fmt[req_format]} || return $?
	ocmd_read_ret $w 2 || return $?
	ocmd_check_err || return $?
}

# switch to FDC mode
ocmd_fdc () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((pdd2)) && abrt "$z requires TPDD1"
	ocmd_send_req ${opr_fmt[req_fdc]} || return $?
	operation_mode=0
	_sleep 0.1
	tpdd_drain
}

# Open File
# request: 5A 5A 01 01 MM ##
# return : 12 01 ?? ##
# MM = access mode: 01=write_new, 02=write_append, 03=read
ocmd_open () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((operation_mode)) || fcmd_mode 1
	local r=${opr_fmt[req_open]} m ;printf -v m '%02X' $1
	((bank)) && printf -v r '%02X' $((16#$r+16#40))
	ocmd_send_req $r $m || return $?	# open the file
	ocmd_read_ret || return $?
	ocmd_check_err
}

# Close File
# request: 5A 5A 02 00 ##
# return : 12 01 ?? ##
ocmd_close () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((operation_mode)) || fcmd_mode 1
	local r=${opr_fmt[req_close]}
	((bank)) && printf -v r '%02X' $((16#$r+16#40))
	ocmd_send_req $r
	ocmd_read_ret $CLOSE_WAIT_MS || return $?
	ocmd_check_err
}

# Delete File
# request: 5A 5A 05 00 ##
# return : 12 01 ?? ##
ocmd_delete () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((operation_mode)) || fcmd_mode 1
	local r=${opr_fmt[req_delete]}
	((bank)) && printf -v r '%02X' $((16#$r+16#40))
	ocmd_send_req $r || return $?
	ocmd_read_ret $DELETE_WAIT_MS 1 || return $?
	ocmd_check_err
}

# Read File data
# request: 5A 5A 03 00 ##
# return : 10 00-80 1-128bytes ##
ocmd_read () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((operation_mode)) || fcmd_mode 1
	local r=${opr_fmt[req_read]}
	((bank)) && printf -v r '%02X' $((16#$r+16#40))
	ocmd_send_req $r || return $?
	ocmd_read_ret || return $?
	vecho 1 "$z: ret_fmt=$ret_fmt ret_len=$ret_len ret_dat=(${ret_dat[*]}) read_err=\"$read_err\""

	# check if the response was an error
	case "$ret_fmt" in
		"${opr_fmt[ret_std]}") ocmd_check_err || return $? ;;
		"${opr_fmt[ret_read]}") ;;
		*) abrt "$z: Unexpected Response" ;;
	esac

	# return true or not based on data or not
	# so we can do "while ocmd_read ;do ... ;done"
	((${#ret_dat[*]}))
}

# Write File Data
# request: 5A 5A 04 ?? 1-128 bytes ##
# return : 12 01 ?? ##
ocmd_write () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((operation_mode)) || fcmd_mode 1
	(($#)) || return 128
	local r=${opr_fmt[req_write]}
	((bank)) && printf -v r '%02X' $((16#$r+16#40))
	ocmd_send_req $r $* || return $?
	tpdd_check || return 0
	ocmd_read_ret || return $?
	ocmd_check_err
}

###############################################################################
#                                 FDC MODE                                    #
###############################################################################
#
# fdc-mode transaction format reference
#
# send: C [ ] [P[,P]...] CR
#
# C = command letter, ascii letter
# optional space between command letter and first parameter
# P = parameter (if any), integer decimal value in ascii numbers
# ,p = more parameters if any, seperated by commas, ascii decimal numbers
# CR = carriage return
#
# recv: 8 bytes as 4 ascii hex pairs representing 4 byte values
#
#  1st pair is the error status
#  remaining pairs meaning depends on the command
#
# Some fdc commands have another send-and-receive after that.
# Receive the first response, if the status is not error, then:
#
# send: the data for a sector write
# recv: another standard 8-byte response as above
# or
# send: single carriage-return
# recv: data from a sector read

###############################################################################
# "FDC Mode" support functions

# read an FDC-mode 8-byte result block
fcmd_read_result () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((operation_mode)) && ocmd_fdc
	local -i i ;local x ;fdc_err= fdc_res= fdc_len= fdc_res_b=()

	# read 8 bytes
	tpdd_read 8 $* || return $?

	# This may look a little confusing because we end up un-hexing the same data
	# twice. tpdd_read() returns all data encoded as hex pairs, because that's
	# how we have to deal with binary data in shell variables. In this case the
	# original 8 bytes from the drive are themselves ascii hex pairs.

	# re-constitute rhex[] from tpdd_read() back to the actual bytes sent
	# by the drive
	x="${rhex[*]}" ;printf -v x '%b' "\x${x// /\\x}"
	vecho 1 "$z:$x"

	# Decode the 8 bytes as
	# 2 bytes = hex pair representing an 8-bit integer error code
	# 2 bytes = hex pair representing an 8-bit integer result data
	# 4 bytes = 2 hex pairs representing a 16-bit integer length value
	((fdc_err=16#${x:0:2})) # first 2 = status
	((fdc_res=16#${x:2:2})) # next 2  = result
	((fdc_len=16#${x:4:4})) # last 4  = length

	# look up the status/error message for fdc_err
	x= ;[[ "${fdc_msg[fdc_err]}" ]] && x="${fdc_msg[fdc_err]}"
	((fdc_err)) && err_msg+=("${x:-ERROR:${fdc_err}}")

	# For some commands, fdc_res is actually 8 individual bit flags.
	# Provide the individual bits in fdc_res_b[] for convenience.
	fdc_res_b=()
	for ((i=7;i>=0;i--)) { fdc_res_b+=(${D2B[fdc_res]:i:1}) ; }

	vecho 1 "$z: err:$fdc_err:\"${fdc_msg[fdc_err]}\" res:$fdc_res(${D2B[fdc_res]}) len:$fdc_len"
}

###############################################################################
# "FDC Mode" drive functions
# wrappers for each "FDC mode" function of the drive firmware

# select operation mode
# fcmd_mode <0-1>
# 0=fdc 1=operation
fcmd_mode () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((pdd2)) && abrt "$z requires TPDD1"
	(($#)) || return
	str_to_shex "${fdc_cmd[mode]}$1"
	tpdd_write ${shex[*]} 0D
	operation_mode=$1
	_sleep 0.1
	tpdd_drain
}

# report drive condition
fcmd_condition () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((operation_mode)) && ocmd_fdc
	local x
	str_to_shex "${fdc_cmd[condition]}"
	tpdd_write ${shex[*]} 0D || return $?

	fcmd_read_result || return $?
	((fdc_err)) && return $fdc_err

	# result bit 7 - disk not inserted
	x= ;((fdc_res_b[7])) && x=' Not'
	echo -n "Disk${x} Inserted"
	((fdc_res_b[7])) && { echo ;return ; }

	# result bit 5 - disk write-protected
	x='Writable' ;((fdc_res_b[5])) && x='Write-protected'
	echo ", $x"
}

# FDC-mode format disk
# fcmd_format [logical_sector_size_code]
# size codes: 0=64 1=80 2=128 3=256 4=512 5=1024 6=1280 bytes
# The drive firmware defaults to size code 3 when not given.
# We intercept that and fill in our own default of 6 instead.
fcmd_format () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((operation_mode)) && ocmd_fdc
	typeset -i s=${1:-6}
	str_to_shex ${fdc_cmd[format]}$s
	echo "Formatting Disk with ${fdc_format_sector_size[s]:-\"\"}-Byte Logical Sectors"
	tpdd_write ${shex[*]} 0D || return $?
	fcmd_read_result $FORMAT_WAIT_MS 2 || return $?
	((fdc_err)) && err_msg+=(", Sector:$fdc_res")
	return $fdc_err
}

# See the software manual page 11
# The drive firmware function returns 13 bytes, only the 1st byte is used.
#
# 00 - current sector is not used by a file
# ** - sector number of next sector in current file
# FF - current sector is the last sector in current file
#
# read sector id section
# fcmd_read_id physical_sector [quiet]
fcmd_read_id () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((operation_mode)) && ocmd_fdc
	str_to_shex "${fdc_cmd[read_id]}$1"
	tpdd_write ${shex[*]} 0D || return $?
	fcmd_read_result || { err_msg+=("err:$? res:\"${fdc_res_b[*]}\"") ;return $? ; }
	#vecho 2 "P:$1 LEN:${fdc_len} RES:${fdc_res}[${fdc_res_b[*]}]"
	((fdc_err)) && { err_msg+=("err:$fdc_err res:\"${fdc_res_b[*]}\"") ;return $fdc_err ; }
	tpdd_write 0D || return $?
	tpdd_read $PDD1_SECTOR_ID_LENGTH || return $?
	((${#rhex[*]}<PDD1_SECTOR_ID_LENGTH)) && { err_msg+=("Got ${#rhex[*]} of $PDD1_SECTOR_ID_LENGTH bytes") ; return 1 ; }
	((${#2})) || printf "I %02u %04u %s\n" "$1" "$fdc_len" "${rhex[*]}"
}

# read a logical sector
# fcmd_read_logical physical logical [quiet]
# physical=0-79 logical=1-20
fcmd_read_logical () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((operation_mode)) && ocmd_fdc
	local -i ps=$1 ls=${2:-1} || return $? ;local x
	str_to_shex "${fdc_cmd[read_sector]}$ps,$ls"
	tpdd_write ${shex[*]} 0D || return $?
	fcmd_read_result || { err_msg+=("err:$? res[${fdc_res_b[*]}]") ;return $? ; }
	((fdc_err)) && { err_msg+=("err:$fdc_err res[${fdc_res_b[*]}]") ;return $fdc_err ; }
	((fdc_res==ps)) || { err_msg+=("Unexpected Physical Sector \"$ps\" Returned") ;return 1 ; }
	tpdd_write 0D || return $?
	# The drive will appear ready with data right away, but if you read too soon
	# the data will be corrupt or incomplete.
	# Take 2/3 of the number of bytes we expect to read, and sleep that many MS.
	ms_to_s $(((fdc_len/3)*2)) ;_sleep $_s
	tpdd_read $fdc_len || return $?
	((${#rhex[*]}<fdc_len)) && { err_msg+=("Got ${#rhex[*]} of $fdc_len bytes") ; return 1 ; }
	((${#3})) || printf "S %02u %02u %04u %s\n" "$ps" "$ls" "$fdc_len" "${rhex[*]}"
}

# write a physical sector ID section
# fcmd_write_id physical data(hex pairs)
fcmd_write_id () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((operation_mode)) && ocmd_fdc
	local -i p=$((10#$1)) ;shift
	str_to_shex "${fdc_cmd[write_id]}$p"
	tpdd_write ${shex[*]} 0D || return $?
	fcmd_read_result || { err_msg+=("err:$? res[${fdc_res_b[*]}]") ;return $? ; }
	((fdc_err)) && { err_msg+=("err:$fdc_err res[${fdc_res_b[*]}]") ;return $fdc_err ; }
	shift ; # discard the size field
	tpdd_write $* || return $?
	fcmd_read_result || { err_msg+=("err:$? res[${fdc_res_b[*]}]") ;return $? ; }
	((fdc_err)) && { err_msg+=("err:$fdc_err res[${fdc_res_b[*]}]") ;return $fdc_err ; }
	:
}

# write a logical sector
# fcmd_write_logical physical logical length data(hex pairs)
fcmd_write_logical () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((operation_mode)) && ocmd_fdc
	local -i ps=$((10#$1)) ls=$((10#$2)) ;shift 2
	str_to_shex "${fdc_cmd[write_sector]}$ps,$ls"
	tpdd_write ${shex[*]} 0D || return $?
	fcmd_read_result || { err_msg+=("err:$? res[${fdc_res_b[*]}]") ;return $? ; }
	((fdc_err)) && { err_msg+=("err:$fdc_err res[${fdc_res_b[*]}]") ;return $fdc_err ; }
	tpdd_write $* || return $?
	fcmd_read_result || { err_msg+=("err:$? res[${fdc_res_b[*]}]") ;return $? ; }
	((fdc_err)) && { err_msg+=("err:$fdc_err res[${fdc_res_b[*]}]") ;return $fdc_err ; }
	:
}

###############################################################################
# Local Commands
# high level functions implemented here in the client

# list disk directory
lcmd_ls () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	local -i m=${dirent_cmd[get_first]}

	((pdd2)) && {
		echo "--- Directory Listing   [$bank] ---"
	} || {
		echo '------ Directory Listing ------'
	}
	while ocmd_dirent '' '' $m ;do
		un_tpdd_file_name "$file_name"
		printf '%-24.24b %6u\n' "$file_name" "$file_len"
		((m==${dirent_cmd[get_first]})) && m=${dirent_cmd[get_next]}
	done
	echo '-------------------------------'
	echo "$((free_sectors*PHYSICAL_SECTOR_LENGTH)) bytes free"
}

# load a file (copy a file from tpdd to local file or memory)
# lcmd_load source_filename [destination_filename]
# If $2 is set but empty, read into global fhex[] instead of writing a file
lcmd_load () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	local x s=$1 d=${2:-$1} ;local -i p= l= ;fhex=()
	(($#)) || return 2
	(($#==2)) && ((${#2}==0)) && d=		# read into memory instead of file
	x= ;((pdd2)) && x="[$bank]"
	echo -n "Loading TPDD$x:$s" ;unset x
	ocmd_dirent "$s" '' ${dirent_cmd[set_name]} || return $?	# set the source filename
	((${#file_name})) || { err_msg+=('No Such File') ; return 1 ; }
	l=$file_len							# file size provided by dirent()
	((${#d})) && {
		echo " to $d"
		[[ -e "$d" ]] && { err_msg+=('File Exists') ;return 1 ; }
		> $d
	} || {
		echo
	}
	pbar 0 $l 'bytes'
	ocmd_open ${open_mode[read]} || return $?	# open the source file for reading
	while ocmd_read ;do					# read a block of data from tpdd
		((${#d})) && {
			x="${ret_dat[*]}" ;printf '%b' "\x${x// /\\x}" >> "$d"	# add to file
		} || {
			fhex+=(${ret_dat[*]})		# add to fhex[]
		}
		((p+=${#ret_dat[*]})) ;pbar $p $l 'bytes'
		((${#ret_dat[*]}<128)) && break	# stop if we get less than 128 bytes
		((p>=l)) && break				# stop if we reach the expected total
	done
	((ret_err==30)) && ((p%128==0)) && unset ret_err err_msg # special case
	ocmd_close || return $?				# close the source file
	((p==l)) || { err_msg+=('Error') ; return 1 ; }
	echo
}

# save a file (copy a file from local file or memory to tpdd)
# lcmd_save source_filename [destination_filename]
# If $1 is set but empty, get data from global fhex[] instead of reading a file
lcmd_save () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	local -i n p l ;local s=$1 d=${2:-$1} x
	(($#)) || return 2
	(($#==2)) && ((${#1}==0)) && s=		# read from memory instead of file
	((${#d})) || return 3
	((${#s})) && {
		[[ -r "$s" ]] || { err_msg+=("\"$s\" not found") ;return 1 ; }
		file_to_fhex "$s" || return 4
	}
	l=${#fhex[*]}
	x= ;((pdd2)) && x="[$bank]"
	echo "Saving TPDD$x:$d" ;unset x
	ocmd_dirent "$d" '' ${dirent_cmd[set_name]} || return $?
	((${#file_name})) && { err_msg+=('File Exists') ; return 1 ; }
	ocmd_open ${open_mode[write_new]} || return $?
	for ((p=0;p<l;p+=128)) {
		pbar $p $l 'bytes'
		ocmd_write ${fhex[*]:p:128} || return $?
		tpdd_wait
		ocmd_read_ret || return $?
		ocmd_check_err || return $?
	}
	pbar $l $l 'bytes'
	echo
	ocmd_close || return $?
}

# delete one or more files
# lcmd_rm filename [filenames...]
lcmd_rm () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	(($#)) || return 1
	local f
	for f in $* ;do
		echo -n "Deleting TPDD:$f "
		ocmd_dirent "$f" '' ${dirent_cmd[set_name]} || return $?
		((${#file_name})) || { err_msg+=('No Such File') ; return 1 ; }
		ocmd_delete || return $?
		printf '\r%79s\rDeleted TPDD:%s\n' '' "$f"
	done
}

# currently, mv and cp are mostly redundant, but later mv may be based on
# fdc-mode commands to edit sector 0 instead of load-delete-save
#
# load-rm-save is less safe than load-save-rm, but works when the disk is full
lcmd_mv () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	(($#==2)) || return 1
	lcmd_load "$1" '' && lcmd_rm "$1" && lcmd_save '' "$2"
}

lcmd_cp () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	(($#==2)) || return 1
	lcmd_load "$1" '' && lcmd_save '' "$2"
}

# read ID and all logical sectors in a physical sector
# lcmd_read_physical physical [quiet]
pdd1_read_physical () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	local -i p=$1 l t || return $? ;local u= h=()

	# read the logical sectors
	fcmd_read_logical $p 1 $2 || return $?
	h+=(${rhex[*]})
	((t=PHYSICAL_SECTOR_LENGTH/fdc_len))
	for ((l=2;l<=t;l++)) {
		((${#2})) && pbar $p $PHYSICAL_SECTOR_COUNT "P:$p L:$l"
		fcmd_read_logical $p $l $2 || return $?
		h+=(${rhex[*]})
	}
	rhex=(${h[*]})
}

# read all physical sectors on the disk
pdd1_dump_disk () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	local -i p t=$PHYSICAL_SECTOR_COUNT m=1 n ;local f=$1
	((${#f})) && {
		echo "Dumping Disk to File: \"$f\""
		[[ -e "$f" ]] && { err_msg+=('File Exists') ;return 1 ; }
		pbar 0 $t "P:- L:-"
		>$f
	}

	for ((p=0;p<t;p++)) {
		# read the ID section
		fcmd_read_id $p $f || return $?
		((n=PHYSICAL_SECTOR_LENGTH/fdc_len))
		((${#f})) && printf '%02u %04u %s ' "$p" "$fdc_len" "${rhex[*]}" >> $f

		# read the physical sector
		pdd1_read_physical $p $m || return $?
		((${#f})) && {
			printf '%s\n' "${rhex[*]}" >> $f
			pbar $((p+1)) $t "P:$p L:$n"
		}
	}
	((${#f})) && echo
}

# read a pdd1 hex dump file and write the contents back to a disk
# pdd1_hex_file_to_disk filename
pdd1_restore_disk () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	local d r s x ;local -i i t sz= n

	# Read the dump file into d[]
	exec 5<"$1" || return $?
	mapfile -u 5 d || return $?
	exec 5<&-

	# Get the logical sector size, abort if not uniform.
	t=${#d[*]}
	for ((i=0;i<t;i++)) {
		r=(${d[i]})
		((sz)) || sz=$((10#${r[1]}))
		((sz==$((10#${r[1]})))) || { err_msg+=('Mixed Logical Sector Sizes') ; return 1 ; }
	}

	# FDC-mode format the disk with the appropriate sector size.
	for i in ${!fdc_format_sector_size[*]} 9999 ;do ((${fdc_format_sector_size[i]}==sz)) && break ;done
	((i==9999)) && { err_msg+=('Unrecognized Logical Sector Size') ; return 1 ; }
	((n=PHYSICAL_SECTOR_LENGTH/sz))
	fcmd_format $i

	# Write the sectors, skip un-used sectors
	echo "Restoring Disk from $1"
	for ((i=0;i<t;i++)) {
		r=(${d[i]})
		pbar $((i+1)) $t "P:${r[0]} L:-/-"
		x=${r[@]:2} ;x=${x//[ 0]/} ;((${#x})) || continue

		# write the ID section
		fcmd_write_id ${r[@]:0:$((2+PDD1_SECTOR_ID_LENGTH))} || return $?

		# logical sectors count from 1
		for ((l=1;l<=n;l++)) {
			pbar $((i+1)) $t "P:${r[0]} L:$l/$n"
			s=(${r[@]:$((2+PDD1_SECTOR_ID_LENGTH+(sz*(l-1)))):sz})
			x=${s[@]:2} ;x=${x//[ 0]/} ;((${#x})) || continue
			fcmd_write_logical ${r[0]} $l ${s[*]} || return $?
		}
	}
	echo
}

###############################################################################
# manual/raw debug commands

lcmd_com_test () {
	test_com && echo 'com is open' || echo 'com is closed'
}

lcmd_com_open () {
	open_com
	lcmd_com_test
}

lcmd_com_close () {
	close_com
	lcmd_com_test
}

# read the Space Managment Table
# track 0 sector 0, bytes 1240-1260
read_smt () {
	((pdd2)) && {
		pdd2_sector_cache 0 0 0 || return $?
		pdd2_read_cache 0 $SMT_OFFSET $SMT_LENGTH >/dev/null || return $?
		echo "SMT 0: ${ret_dat[*]:3}"
		pdd2_sector_cache 0 1 0 || return $?
		pdd2_read_cache 0 $SMT_OFFSET $SMT_LENGTH >/dev/null || return $?
		echo "SMT 1: ${ret_dat[*]:3}"
	} || {
		pdd1_read_physical 0 >/dev/null || return $?
		echo "SMT: ${rhex[*]:$SMT_OFFSET:$SMT_LENGTH}"
	}
}

###############################################################################
# TPDD2

# TPDD2 Get Drive Status
# request: 5A 5A 0C 00 ##
# return : 15 01 ?? ##
pdd2_condition () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((pdd2)) || abrt "$z requires TPDD2"
	local -i i ;local x
	ocmd_send_req ${opr_fmt[req_condition]} || return $?
	ocmd_read_ret || return $?

	# response data is a single byte wih 4 bit-flags
	ocmd_cond_b=()
	for ((i=7;i>=0;i--)) { ocmd_cond_b+=(${D2B[16#${ret_dat[0]}]:i:1}) ; }

	# bit 2 - disk inserted
	x= ;((ocmd_cond_b[2])) && {
			x='Not Inserted'
	} || {
		# bit 3 - disk changed
		x= ;((ocmd_cond_b[3])) && x='Changed ,'
		# bit 1 - disk write-protected
		((ocmd_cond_b[1])) && x+='Write-protected' || x+='Writable'
	}
	echo "Disk $x"
	# result bit 0 - power
	x='Normal' ;((ocmd_cond_b[0])) && x='Low'
	echo "Power $x"
}

# TPDD2 read from cache
# pdd2_read_cache mode offset length [filename]
pdd2_read_cache () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((pdd2)) || abrt "$z requires TPDD2"
	local x

	# 4-byte request data
	# 00         mode
	# 0000-04C0  offset
	# 00-FC      length
	printf -v x '%02X %02X %02X %02X' $1 $(($2/256)) $(($2%256)) $3

	ocmd_send_req ${opr_fmt[req_read_cache]} $x || return $?
	ocmd_read_ret || return $?

	# returned data:
	# [0]     mode
	# [1][2]  offset
	# [3]+    data
	((${#4})) && {
		printf '%02X %02X %s\n' "$track_num" "$sector_num" "${ret_dat[*]}" >>$4
	} || {
		printf 'T:%02u S:%u m:%u O:%05u %s\n' "$track_num" "$sector_num" "$((16#${ret_dat[0]}))" "$((16#${ret_dat[1]}${ret_dat[2]}))" "${ret_dat[*]:3}"
		#printf -v x '%s' "${ret_dat[*]:3}" ;printf '%b\n' "\x${x// /\\x}"
	}
}

# TPDD2 write to cache
# pdd2_write_cache mode offset_msb offset_lsb data...
pdd2_write_cache () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((pdd2)) || abrt "$z requires TPDD2"
	ocmd_send_req ${opr_fmt[req_write_cache]} $* || return $?
	ocmd_read_ret || return $?
	ocmd_check_err
}

# TPDD2 write to cache, decimal offset for cli convenience
# lcmd_write_cache mode offset data...
lcmd_write_cache () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((pdd2)) || abrt "$z requires TPDD2"
	local x

	# payload header
	# 00|01      mode
	# 0000-0500  offset
	printf -v x '%02X %02X %02X' $1 $((10#$2/256)) $((10#$2%256)) ;shift 2

	pdd2_write_cache $x $* || return $?
}

# TPDD2 copy sector between disk and cache
# pdd2_cache_sector track sector mode
# pdd2_cache_sector 0-79 0-1 0|2
# mode: 0=disk-to-cache 2=cache-to-disk
pdd2_sector_cache () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((pdd2)) || abrt "$z requires TPDD2"
	local x m=${3:-0} ;track_num=$1 sector_num=$2

	# 5-byte request data
	# 00|02 mode
	# 00    unknown
	# 00-4F track#
	# 00    unknown
	# 00-01 sector
	printf -v x '%02X 00 %02X 00 %02X' $m $track_num $sector_num

	ocmd_send_req ${opr_fmt[req_sector_cache]} $x || return $?
	ocmd_read_ret || return $?
	ocmd_check_err
}

# TPDD2 dump disk
# pdd2_dump_disk [filename]
pdd2_dump_disk () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((pdd2)) || abrt "$z requires TPDD2"
	local -i t s f fq tb b=
	((fq=PHYSICAL_SECTOR_LENGTH/PDD2_SECTOR_CHUNK_LENGTH))
	((tb=fq*PHYSICAL_SECTOR_COUNT*2*PDD2_SECTOR_CHUNK_LENGTH))
	((${#1})) && {
		printf 'Dumping Disk to File: \"%s\"\n' "$1"
		pbar 0 $tb bytes
		>$1
	}

	for ((t=0;t<PHYSICAL_SECTOR_COUNT;t++)) {
		for ((s=0;s<2;s++)) {
			pdd2_sector_cache $t $s 0 || return $?
			pdd2_read_cache 1 32772 4 $1 || return $? # metadata
			for ((f=0;f<fq;f++)) {
				pdd2_read_cache 0 $((PDD2_SECTOR_CHUNK_LENGTH*f)) $PDD2_SECTOR_CHUNK_LENGTH $1 || return $?
				pbar $((b+=PDD2_SECTOR_CHUNK_LENGTH)) $tb bytes
			}
		}
	}

	((${#1})) && echo
}

pdd2_flush_cache () {
	# mystery metadata writes
	pdd2_write_cache 01 00 83 || return $?
	pdd2_write_cache 01 00 96 || return $?
	# flush the cache to disk
	pdd2_sector_cache $1 $2 2 || return $?
}

pdd2_restore_disk () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	((pdd2)) || abrt "$z requires TPDD2"
 	local d r ;local -i i n t s m b= tb=$((PHYSICAL_SECTOR_LENGTH*PHYSICAL_SECTOR_COUNT*2)) ;track_num= sector_num=

	# Format the disk
	ocmd_format || return $?

	# Read the dump file into d[]
	exec 5<"$1" || return $?
	mapfile -u 5 d || return $?
	exec 5<&-
	n=${#d[@]}

	# Write the sectors
	# each record in the file is:
	# track sector mode offset_msb offset_lsb data...
	echo "Restoring Disk from $1"
	for ((i=0;i<n;i++)) {
		r=(${d[i]})
		vecho 2 "${r[*]}"

		t=16#${r[0]} s=16#${r[1]} m=16#${r[2]}

		# encountered new sector in file, write cache to disk
		((t==track_num)) && ((s==sector_num)) || {
			((i)) && { pdd2_flush_cache $track_num $sector_num || return $? ; }
			track_num=$t sector_num=$s
		}

		((m)) || pbar $((b+=${#r[*]}-5)) $tb 'bytes'

		# write to cache
		pdd2_write_cache ${r[*]:2} || return $?
	}
	pdd2_flush_cache $track_num $sector_num || return $?
	echo
}

###############################################################################
# Server Functions
# These functions are for talking to a client not a drive

# write $* to com port with per-character delay
# followed by the BASIC EOF character
srv_send_loader () {
	local z=${FUNCNAME[0]} ;vecho 1 "$z($@)"
	local -i i l ;local s REPLY
	ms_to_s $LOADER_PER_CHAR_MS ;s=$_s
	file_to_fhex $1
	fhex+=('0D' $BASIC_EOF)

	echo "Installing $1"
	echo 'Prepare the portable to receive. Hints:'
	echo -e "\tRUN \"COM:98N1ENN\"\t(for TANDY, Kyotronic, Olivetti)"
	echo -e "\tRUN \"COM:9N81XN\"\t(for NEC)\n"
	read -p 'Press [Enter] when ready...'

	l=${#fhex[*]}
	for ((i=0;i<l;i++)) {
		printf '%b' "\x${fhex[i]}" >&3
		pbar $((i+1)) $l 'bytes'
		_sleep $s
	}
	echo
}

###############################################################################
# Main
typeset -a err_msg=() shex=() fhex=() rhex=() ret_dat=() fdc_res_b=()
typeset -i _y= pdd2=$((TPDD_MODEL-1)) bank= operation_mode=1 read_err= fdc_err= fdc_res= fdc_len= track_num= sector_num= _om=99
cksum=00 ret_err= ret_fmt= ret_len= ret_sum= tpdd_file_name= file_name= ret_list='|' _s=
readonly LANG=C D2B=({0,1}{0,1}{0,1}{0,1}{0,1}{0,1}{0,1}{0,1})
((v==9)) && typeset -i seq=0
ms_to_s $TTY_READ_TIMEOUT_MS ;read_timeout=$_s
[[ "$0" =~ .*pdd2(\.sh)?$ ]] && pdd2=1 operation_mode=2
for x in ${!opr_fmt[*]} ;do [[ "$x" =~ ^ret_.* ]] && ret_list+="${opr_fmt[$x]}|" ;done
unset x

# for _sleep()
readonly sleep_fifo="/tmp/.${0//\//_}.sleep.fifo"
[[ -p $sleep_fifo ]] || mkfifo "$sleep_fifo" || abrt "Error creating sleep fifo \"$sleep_fifo\""
exec 4<>$sleep_fifo

# tpdd serial port
for PORT in $1 /dev/$1 ;do [[ -c "$PORT" ]] && break || PORT= ;done
[[ "$PORT" ]] && shift || get_tpdd_port
vecho 1 "Using port \"$PORT\""
open_com || exit $?

# non-interactive mode
exit=exit
(($#)) && { do_cmd "$@" ;$exit ; }

# interactive mode
while read -p"TPDD(${mode[operation_mode]})> " __c ;do do_cmd "${__c}" ;done
