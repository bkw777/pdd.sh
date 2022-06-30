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

# Use "TS-DOS mystery command" to automatically detect TPDD1 vs TPDD2
: ${MODEL_DETECTION:=true}

# verbose/debug
# 0/unset=normal, 1=verbose, >1=more verbose, 3=log all tty traffic to files
# DEBUG=1 ./pdd ...
case "$DEBUG" in
	false|off|n|no) DEBUG=0 ;;
	true|on|y|yes|:) DEBUG=1 ;;
esac
v=${DEBUG:-0}

# COMPAT sets default behavior for disk vs local filename conversions and
# the attribute byte.
# floppy : 6.2 space-padded names with attribute 'F' - TRS-80 Model 100, clones
# wp2    : 8.2 space-padded names with attribute 'F' - TANDY WP-2
# raw    : 24 byte names with attribute ' '          - Cambridge Z88, others
: ${COMPAT:=floppy}

# Default rs232 tty device name, with platform differences
# The automatic TPDD port detection will search "/dev/${TPDD_TTY_PREFIX}*"
			stty_f="-F" TPDD_TTY_PREFIX=ttyUSB	# linux
case "${OSTYPE,,}" in
	*bsd*) 		stty_f="-f" TPDD_TTY_PREFIX=ttyU ;;	# *bsd
	darwin*) 	stty_f="-f" TPDD_TTY_PREFIX=cu.  ;;	# osx
esac

# stty flags to set the serial port parameters & tty behavior
# For FB-100, FDD19, Purple Computing, change BAUD to 9600
# (or remove the solder blob from dip switch position 1)
: ${BAUD:=19200}
: ${RTSCTS:=true}
: ${XONOFF:=false}
STTY_FLAGS='raw pass8 clocal cread -echo'

# do a opr-fdc-opr sequence to joggle the drive into a known state in _init()
FONZIE_SMACK=true

# expose non-printable bytes in filenames (see tpdd2 util disk)
EXPOSE_FILENAMES=false

###############################################################################
# tunables

# tty read timeout in ms
# When issuing the "read" command to read bytes from the serial port,
# wait this long (in ms) for a byte to appear before giving up.
# This is not the TPDD read command to read a block of 128 bytes of file
# data, this is converted from ms to seconds and used with "read -t".
# It applies to all reads from the drive tty by any command.
TTY_READ_TIMEOUT_MS=100

# Default timout and polling period in tpdd_wait().
# Almost all commands have a timeout allowance for reading the result after
# issuing a command. tpdd_wait() polls the tty to see if data is available
# without consuming any, until either data arrives, or the timeout expires.
# These are the polling period, and the default timeout if not supplied.
TPDD_WAIT_TIMEOUT_MS=100
TPDD_WAIT_PERIOD_MS=100

# Timouts for various commands - unfortunately necessary
# If you get timouts on some command, increase the relevant value by
# 1000 until you stop getting timeouts. Most of the commands with 5
# seconds (5000) below usually respond much sooner, but any command
# might also take a long time to respond when the drive has been idle.
FORMAT_WAIT_MS=105000       # ocmd_format takes just under 100 seconds
FORMAT_TPDD2_EXTRA_WAIT_MS=10000 # tpdd2 uses the same command but takes longer
DELETE_WAIT_MS=30000        # ocmd_delete takes 3 to 20 seconds
RENAME_WAIT_MS=10000        # ocmd_pdd2_rename
OPEN_WAIT_MS=5000           # ocmd_open
CLOSE_WAIT_MS=20000         # ocmd_close
DIRENT_WAIT_MS=10000        # ocmd_dirent
READ_WAIT_MS=5000           # ocmd_read
WRITE_WAIT_MS=5000          # ocmd_write
READY_WAIT_MS=5000          # ocmd_ready, fcmd_ready, pdd2_ready
RI_WAIT_MS=5000             # fcmd_read_id
RL_WAIT_MS=5000             # fcmd_read_logical
WI_WAIT_MS=5000             # fcmd_write_id
WL_WAIT_MS=5000             # fcmd_write_logical
SC_WAIT_MS=5000             # pdd2_cache_load
WC_WAIT_MS=5000             # pdd2_cache_write
RC_WAIT_MS=5000             # pdd2_cache_read

# TS-DOS "mystery" command - TPDD2 detection
# real TPDD2 responds with this immediately
# real TPDD1 does not respond
UNK23_RET_DAT=(41 10 01 00 50 05 00 02 00 28 00 E1 00 00 00)

# Per-byte delay in send_loader()
LOADER_PER_CHAR_MS=7

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
	[req_seek]='09'	# TPDD2
	[req_tell]='0A'	# TPDD2
	[req_set_ext]='0B'	# TPDD2
	[req_condition]='0C'	# TPDD2
	[req_pdd2_rename]='0D'	# TPDD2
	[req_unk0E]='0E'	# TPDD2
	[req_unk0F]='0F'	# TPDD2
	[req_pdd2_unk10]='10'	# TPDD2 unk, resp: 38 01 36 (90)  (ret_pdd2_sector_std: ERR_PARAM)
	[req_pdd2_unk11]='11'	# TPDD2 unk, resp: 3A 06 80 13 05 00 10 E1 (36)
	[req_pdd2_unk12]='12'	# TPDD2 unk, resp: 38 01 36 (90)  (ret_pdd2_sector_std: ERR_PARAM)
#	[req_pdd2_unk13]='13'	# TPDD2 unk, resp: 12 01 36 B6    (ret_std: ERR_PARAM)
#	[req_pdd2_unk14]='14'	# TPDD2 unk, resp: 12 01 36 B6    (ret_std: ERR_PARAM)
#	[req_pdd2_unk15]='15'	# TPDD2 unk, resp: 12 01 36 B6    (ret_std: ERR_PARAM)
#	[req_pdd2_unk16]='16'	# TPDD2 unk, r: 
#	[req_pdd2_unk17]='17'	# TPDD2 unk, r: 
#	[req_pdd2_unk18]='18'	# TPDD2 unk, r: 
#	[req_pdd2_unk19]='19'	# TPDD2 unk, r: 
#	[req_pdd2_unk19]='19'	# TPDD2 unk, r: 
#	[req_pdd2_unk19]='19'	# TPDD2 unk, r: 
#	[req_pdd2_unk19]='19'	# TPDD2 unk, r: 
#	[req_pdd2_unk19]='19'	# TPDD2 unk, r: 
#	[req_pdd2_unk19]='19'	# TPDD2 unk, r: 
#	[req_pdd2_unk19]='19'	# TPDD2 unk, r: 
#	[req_pdd2_unk19]='19'	# TPDD2 unk, r: 
#	[req_pdd2_unk20]='20'	# TPDD2 unk, r: 
#	[req_pdd2_unk21]='21'	# TPDD2 unk, r: 
#	[req_pdd2_unk22]='22'	# TPDD2 unk, r: 
	[req_pdd2_unk23]='23'	# TPDD2 unk, r: 14 0F 41 10 01 00 50 05 00 02 00 28 00 E1 00 00 00 (2A)
	[req_cache_load]='30'	# TPDD2
	[req_cache_write]='31'	# TPDD2
	[req_cache_read]='32'	# TPDD2
	[req_pdd2_unk33]='33'	# TPDD2 unk, r: 3A 06 80 13 05 00 10 E1 (36)
#	[req_pdd2_unk34]='34'	# TPDD2 unk, r:
#	[req_pdd2_unk34]='35'	# TPDD2 unk, r:
#	[req_pdd2_unk34]='36'	# TPDD2 unk, r:
#	[req_pdd2_unk34]='37'	# TPDD2 unk, r:
#	[req_pdd2_unk34]='38'	# TPDD2 unk, r:
#	[req_pdd2_unk34]='39'	# TPDD2 unk, r:
#	[req_pdd2_unk34]='34'	# TPDD2 unk, r:
#	[req_pdd2_unk34]='34'	# TPDD2 unk, r:
#	[req_pdd2_unk34]='34'	# TPDD2 unk, r:
#	[req_pdd2_unk34]='34'	# TPDD2 unk, r:
#	[req_pdd2_unk34]='34'	# TPDD2 unk, r:
#	[req_pdd2_unk34]='34'	# TPDD2 unk, r:
#	[req_pdd2_unk34]='34'	# TPDD2 unk, r:
#	[req_pdd2_unk34]='34'	# TPDD2 unk, r:
#	[req_pdd2_unk34]='34'	# TPDD2 unk, r:
#	[req_pdd2_unk34]='34'	# TPDD2 unk, r:
	# returns
	[ret_read]='10'
	[ret_dirent]='11'
	[ret_std]='12'	# error open close delete status write pdd2_unk13 pdd2_unk14 pdd2_unk15
	[ret_pdd2_unk23]='14'	# TPDD2 unk23 - "TS-DOS mystery" tpdd2 DETECTION
	[ret_condition]='15'	# TPDD2
	[ret_cache_std]='38'	# TPDD2 cache_load cache_write unk10 unk12
	[ret_cache_read]='39'	# TPDD2
	[ret_pdd2_unk11]='3A'	# TPDD2 unk11 unk33
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
	[get_prev]=3	# TPDD2
	[close]=4	# TPDD2
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

# FDC condition bit flags
typeset -ra fdc_cond=(
	[0x00]='Ready'
	[0x01]='Unknown condition bit 0'
	[0x02]='Unknown condition bit 1'
	[0x04]='Unknown condition bit 2'
	[0x08]='Unknown condition bit 3'
	[0x10]='Unknown condition bit 4'
	[0x20]='Disk Write-Protected'
	[0x40]='Disk Changed'
	[0x80]='Disk Not Inserted'
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
# TPDD2 constants

# bit 3: Disk changed
# bit 2: Disk not inserted
# bit 1: Write protected
# bit 0: Low power

# Condition bit flags
typeset -a pdd2_cond=(
	[0x00]='Ready'
	[0x01]='Low Power'
	[0x02]='Disk Write-Protected'
	[0x04]='Disk Not Inserted'
	[0x08]='Disk Changed'
	[0x10]='Unknown condition bit 4'
	[0x20]='Unknown condition bit 5'
	[0x40]='Unknown condition bit 6'
	[0x80]='Unknown condition bit 7'
)

###############################################################################
# general constants

typeset -ri \
	PHYSICAL_SECTOR_LENGTH=1280 \
	PHYSICAL_SECTOR_COUNT=80 \
	PDD1_SECTOR_ID_LENGTH=12 \
	TPDD_MAX_FILE_LENGTH=65534 \
	TPDD_MAX_FILE_COUNT=40 \
	TPDD_FILENAME_LENGTH=24 \
	PDD2_SECTOR_CHUNK_LENGTH=64 \
	SMT_OFFSET=1240 \
	SMT_LENGTH=21 \
	TPDD_DATA_MAX=128

typeset -r \
	BASIC_EOF='1A' \
	BASIC_EOL='0D'

# Filename field on the drive is 24 bytes. These can not exceed that.
# [platform_compatibility_name]=decimal_file_name_len , decimal_file_ext_len , hex_file_attr_byte
typeset -rA compat=(	# fname(dec.dec) fattr(hex)
	[floppy]='6,2,46'	# 6.2  F
	[wp2]='8,2,46'		# 8.2  F
#	[z88]='24,,00'		# 24   null     # not sure what z88 wants yet
	[raw]='24,,20'		# 24   space
)

#
# CONSTANTS
###############################################################################

###############################################################################
# generic/util functions

perr () {
	echo "${_c:+${_c}: }$@" >&2
}

abrt () {
	perr "$0: $@"
	exit 1
}

vecho () {
	(($1>v)) && return 0;
	shift ;echo "$@" >&2
}

_sleep () {
	local x
	read -t ${1:-1} -u 4 x
	:
}

# Milliseconds to seconds
ms_to_s () {
	_s="000$1" ;_s="${_s:0:-3}.${_s: -3}"
}

# Convert a plain text string to hex pairs stored in shex[]
str_to_shex () {
	vecho 3 "${FUNCNAME[0]}($@)"
	local x="$*" ;local -i i l=${#x} ;shex=()
	for ((i=0;i<l;i++)) { printf -v shex[i] '%02X' "'${x:i:1}" ; }
	vecho 3 "shex[] ${shex[*]}"
}

# Convert a local filename to the on-disk tpdd filename
# "A.BA" -> "A     .BA"
mk_tpdd_file_name () {
	vecho 3 "${FUNCNAME[0]}($@)"
	local -i nl el ;local n e f="$1" ;tpdd_file_name=
	((FNL<TPDD_FILENAME_LENGTH)) && {
		n="${f%.*}" e="${f##*.}" ;[[ ":$n" == ":$e" ]] && e= ;n=${n//./_}
		printf -v f "%-${FNL}.${FNL}s.%-${FEL}.${FEL}s" "$n" "$e"
	}
	printf -v tpdd_file_name "%-${TPDD_FILENAME_LENGTH}.${TPDD_FILENAME_LENGTH}s" "$f"
}

# Floppy/WP-2 compat modes, just strip all spaces.
un_tpdd_file_name () {
	vecho 3 "${FUNCNAME[0]}($@)"
	file_name="$1"
	((FNL<TPDD_FILENAME_LENGTH)) && file_name=${file_name// /}
	:
}

# Read a local file into hex pairs stored in fhex[]
file_to_fhex () {
	vecho 2 "${FUNCNAME[0]}($@)"
	local -i i= ;local x ;fhex=()
	[[ -r "$1" ]] || { err_msg+=("\"$1\" not found") ;return 1 ; }
	while IFS= read -d '' -r -n 1 x ;do
		printf -v fhex[i++] '%02X' "'$x"
		((${#fhex[*]}>TPDD_MAX_FILE_LENGTH)) && { err_msg+=("\"$1\" exceeds $TPDD_MAX_FILE_LENGTH bytes") fhex=() i=-1 ;break ; }
	done <"$1"
	vecho 2 "${#fhex[*]} bytes"
	((i>-1))
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

parse_compat () {
	local a IFS=, c=${1:-$COMPAT}
	[[ "${compat[$c]}" ]] 2>&- >&- || return 1
	a=(${compat[$c]})
	FNL="${a[0]}" FEL="${a[1]}" FAH="${a[2]}"
	printf -v ATTR "%b" "\x$FAH"
}

_init () {
	vecho 2 "${FUNCNAME[0]}($@)"
	$did_init && return
	${FONZIE_SMACK} && fonzie_smack
	${MODEL_DETECTION} && ocmd_pdd2_unk23
	did_init=true MODEL_DETECTION=false FONZIE_SMACK=false
	$pdd2 && {
			trap '' EXIT
	} || {
			trap 'fcmd_mode 1' EXIT # leave pdd1 in opr mode
	}
}

###############################################################################
# serial port operations

get_tpdd_port () {
	vecho 3 "${FUNCNAME[0]}($@)"
	local x=(/dev/${TPDD_TTY_PREFIX#/dev/}*)
	[[ "${x[0]}" == "/dev/${TPDD_TTY_PREFIX}*" ]] && x=(/dev/tty*)
	((${#x[*]}==1)) && { PORT=${x[0]} ;return ; }
	local PS3="Which serial port is the TPDD drive on? "
	select PORT in ${x[*]} ;do [[ -c "$PORT" ]] && break ;done
}

test_com () {
	[[ -t 3 ]]
}

set_stty () {
	vecho 3 "${FUNCNAME[0]}($@)"
	local b=${1:-${BAUD:-19200}} r= x= ;${RTSCTS:-true} || r='-' ;${XONOFF:-false} || x='-'
	stty ${stty_f} "${PORT}" $b ${STTY_FLAGS} ${r}crtscts ${x}ixon ${x}ixoff
	((v>1)) && stty ${stty_f} "${PORT}" -a ;:
}

open_com () {
	vecho 3 "${FUNCNAME[0]}($@)"
	test_com && return
	exec 3<>"${PORT}"
	test_com && set_stty || err_msg+=("Failed to open serial port \"${PORT}\"")
}

close_com () {
	vecho 3 "${FUNCNAME[0]}($@)"
	test_com && exec 3>&-
}

###############################################################################
# TPDD communication primitives

# write $* hex pairs to com port as binary
tpdd_write () {
	vecho 3 "${FUNCNAME[0]}($@)"
	test_com || { err_msg+=("$PORT closed") ;return 1 ; }
	local x=" $*"
	printf '%b' "${x// /\\x}" >&3
}

# read $1 bytes from com port
# store each byte as a hex pair in global rhex[]
#
# We need to read binary data from the drive. The special problem with handling
# binary data in shell is that it's not possible to store or retrieve null/0x00
# bytes in a shell variable. All other values can be handled no problem.
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
# return value from "read" is crucial to distiguish between a timeout and a null byte
# $?=0 = we read a non-null byte normally, $x contains a byte
#    1 = we read a null byte, $x is empty because we ate the null as a delimiter
# >128 = we timed out, $x is empty because there was no data, not even a null
tpdd_read () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local -i i l=$1 ;local x ;rhex=() read_err=0
	tpdd_wait $2 $3 || return $?
	vecho 2 -n "$z: l=$l "
	l=${1:-$PHYSICAL_SECTOR_LENGTH}
	for ((i=0;i<l;i++)) {
		x=
		IFS= read -d '' -r -t $read_timeout -n 1 -u 3 x ;read_err=$?
		((read_err==1)) && read_err=0
		((read_err)) && break
		printf -v rhex[i] '%02X' "'$x"
	}
	((read_err>1)) && err_msg+=("tty read err:$read_err")
	vecho 2 "${rhex[*]}"
	((${#rhex[*]}==l))
}

tpdd_read_unknown () {
	vecho 3 "${FUNCNAME[0]}($@)"
	local -i e= ;local x ;rhex=()
	tpdd_wait_s || return $?
	while : ;do
		x=
		IFS= read -d '' -r -t $read_timeout -n 1 -u 3 x ;e=$?
		((e==1)) && e=0
		((e)) && break
		printf -v x '%02X' "'$x"
		rhex+=($x)
	done
	:
}

tpdd_read_BASIC () {
	vecho 3 "${FUNCNAME[0]}($@)"
	local x e ;printf -v e '%b' "\x$BASIC_EOF"
	tpdd_wait || return $?
	while read -r -t 2 -u 3 x ;do
		printf '%s\n' "$x"
		[[ "${x: -1}" == "$e" ]] && break
	done
}

# check if data is available without consuming any
tpdd_check () {
	vecho 3 "${FUNCNAME[0]}($@)"
	IFS= read -t 0 -u 3
}

# wait for data
# tpdd_wait timeout_ms busy_indication
# _sleep() but periodically check the drive,
# optionally show either a busy or progress indicator,
# return once the drive starts sending data
tpdd_wait () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	test_com || { err_msg+=("$PORT closed") ;return 1 ; }
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
	((i>n)) && { err_msg+=("$z: TIMED OUT / no response from drive") ; return 1 ; }
	${d[b]} 1 1
	((b==1)) && spin -
	((b)) && echo
	vecho 4 "$z: $@:$((i*p))"
}

tpdd_wait_s () {
	test_com || { err_msg+=("$PORT closed") ;return 1 ; }
	until tpdd_check ;do _sleep 0.1 ;done
}

# Drain output from the drive to get in sync with it's input vs output.
tpdd_drain () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local x= s=() ;local -i i
	while tpdd_check ;do
		x= IFS= read -d '' -r -t $read_timeout -n 1 -u 3 x
		((v>2)) && printf -v s[i++] '%02X' "'$x"
	done
	((v>2)) && ((${#s[*]})) && vecho 3 "$z: ${s[*]}"
	:
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
# one's complement of lsb of sum
calc_cksum () {
	local z=${FUNCNAME[0]} ;vecho 3 -n "$z($@):"
	local -i s=0
	while (($#)) ;do ((s+=0x$1)) ;shift ;done
	printf -v cksum '%02X' $((~s&0xFF))
	vecho 3 "$cksum"
}

# verify the checksum of a received packet
# $* = data data data... chk  (hex pairs)
verify_checksum () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local -i l=$(($#-1)) ;local x= h=($*)
	x=${h[l]} ;h[l]=
	calc_cksum ${h[*]}
	vecho 2 "$z: given:$x calc:$cksum"
	((0x$x==0x$cksum))
}

# check if a ret_std format response was ok (00) or error
ocmd_check_err () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local -i e ;local x
	vecho 1 "$z: ret_fmt=$ret_fmt ret_len=$ret_len ret_dat=(${ret_dat[*]}) read_err=\"$read_err\""
	((${#ret_dat[*]}==1)) || { err_msg+=('Corrupt Response') ; ret_dat=() ;return 1 ; }
	vecho 1 -n "$z: ${ret_dat[0]}:"
	((e=0x${ret_dat[0]}))
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
# fmt=$1  data=$2+
ocmd_send_req () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode)) || fcmd_mode 1 || return 1
	local fmt=$1 len ;shift
	printf -v len '%02X' $#
	calc_cksum $fmt $len $*
	vecho 2 "$z: fmt=\"$fmt\" len=\"$len\" dat=\"$*\" chk=\"$cksum\""
	tpdd_write 5A 5A $fmt $len $* $cksum
}

# read an operation-mode return block from the tpdd
# parse it into the parts: format, length, data, checksum
# verify the checksum
# return the globals ret_fmt, ret_len, ret_dat[], ret_sum
# $* is appended to the first tpdd_read() args (timeout_ms busy_indicator)
ocmd_read_ret () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local -i t ;local l x ;ret_fmt= ret_len= ret_dat=() ret_sum=

	vecho 3 "$z: reading 2 bytes (fmt len)"
	tpdd_read 2 $* || return $?
	((${#rhex[*]}==2)) || return 1
	[[ "$ret_list" =~ \|${rhex[0]}\| ]] || { err_msg+=("$z: INVALID RESPONSE") ; return 1 ; }
	ret_fmt=${rhex[0]} ret_len=${rhex[1]}

	((l=0x$ret_len))
	vecho 3 "$z: reading $l bytes (data)"
	tpdd_read $l || return $?
	((${#rhex[*]}==l)) || return 3
	ret_dat=(${rhex[*]})

	vecho 3 "$z: reading 1 byte (checksum)"
	tpdd_read 1 || return $?
	((${#rhex[*]}==1)) || return 4
	ret_sum=${rhex[0]}

	vecho 2 "$z: fmt=$ret_fmt len=$ret_len dat=(${ret_dat[*]}) chk=$ret_sum"
	# compute the checksum and verify it matches the supplied checksum
	verify_checksum $ret_fmt $ret_len ${ret_dat[*]} $ret_sum || { err_msg+=("$z: CHECKSUM FAILED") ;return 1 ; }
}


###############################################################################
# "Operation Mode" drive functions
# wrappers for each "operation mode" function of the drive firmware

# directory entry
# ocmd_dirent filename fileattr action
# fmt = 00
# len = 1A
# filename = 24 bytes
# attribute = 1 byte  - not really used, but KC-85 clients always write 'F', Z88 clients may need 0x00 or 0x20
# search form = 00=set_name | 01=get_first | 02=get_next | 03=get_prev | 04=close
ocmd_dirent () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local -i e ;local r=${opr_fmt[req_dirent]} x f="$1" a="${2:-00}" m=${3:-${dirent_cmd[get_first]}}
	drive_err= file_name= file_attr= file_len= free_sectors=
	((operation_mode)) || fcmd_mode 1 || return 1

	# if tpdd2 bank 1, add 0x40 to opr_fmt[req]
	((bank)) && printf -v r '%02X' $((0x$r+0x40))

	# construct the request
	shex=(00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00)
	((m==${dirent_cmd[set_name]})) && {
		mk_tpdd_file_name "$f"			# pad/truncate filename
		str_to_shex "$tpdd_file_name"		# filename (shex[0-23])
		((${#a}<2)) && printf -v a '%02X' "'$a" ;shex[24]=$a	# attribute
	}
	printf -v shex[25] '%02X' $m		# action

	# send the request
	vecho 1 "$z: req: filename=\"$tpdd_file_name\" attr=0x$a action=$m"
	ocmd_send_req $r ${shex[*]} || return $?

	# read the response
	ocmd_read_ret $DIRENT_WAIT_MS || return $?

	# check which kind of response we got
	case "$ret_fmt" in
		"${opr_fmt[ret_std]}") ocmd_check_err || return $? ;;	# got a valid error return
		"${opr_fmt[ret_dirent]}") : ;;				# got a valid dirent return
		*) err_msg+=("$z: Unexpected Return") ;return 1 ;;	# got no valid return
	esac
	((${#ret_dat[*]}==28)) || { err_msg+=("$z: Got ${#ret_dat[*]} bytes, expected 28") ;return 1 ; }

	# parse a dirent return format
	x="${ret_dat[*]:0:24}" ;printf -v file_name '%-24.24b' "\x${x// /\\x}"
	printf -v file_attr '%b' "\x${ret_dat[24]}"
	((file_len=0x${ret_dat[25]}*0xFF+0x${ret_dat[26]}))
	free_sectors=0x${ret_dat[27]}
	vecho 1 "$z: ret: filename=\"$file_name\" attr=0x${ret_dat[24]} flen=$file_len free_sectors=$free_sectors"

	# If doing set_name, and we got this far, then return success. Only the
	# caller knows if they expected file_name & file_attr to be null or not.
	# If doing close, also just return success. TODO find out more about close
	case $m in
		${dirent_cmd[set_name]}) return 0 ;;
		${dirent_cmd[close]}) return 0 ;;
	esac

	# If doing get_first, get_next, get_prev, filename[0]=00 means no more files. 
	((0x${ret_dat[0]}))
}

# TS-DOS mystery TPDD2 detection - some versions of TS-DOS send this
# TPDD2 gives this response. TPDD1 does not respond.
# request: 5A 5A 23 00 DC
# return : 14 0F 41 10 01 00 50 05 00 02 00 28 00 E1 00 00 00 2A
ocmd_pdd2_unk23 () {
	vecho 3 "${FUNCNAME[0]}($@)"
	# don't do the normal operation_mode/pdd2 checks, since this is itself
	# one of the ways we figure that out in the first place
	# clear err_msg and don't return error on read err because it's expected
	ret_dat=()
	ocmd_send_req ${opr_fmt[req_pdd2_unk23]} && ocmd_read_ret ;err_msg=()
	[[ ":${ret_dat[*]}" == ":${UNK23_RET_DAT[*]}" ]] && {
		vecho 1 'Detected TPDD2'
		pdd2=true operation_mode=2 bd="[$bank]"
		return 0
	} || {
		vecho 1 'Detected TPDD1'
		pdd2=false operation_mode=1 bd=
		return 1
	}
}

# Get Drive Status
# request: 5A 5A 07 00 ##
# return : 07 01 ?? ##
ocmd_ready () {
	vecho 3 "${FUNCNAME[0]}($@)"
	((operation_mode)) || fcmd_mode 1 || return 1
	ocmd_send_req ${opr_fmt[req_status]} || return $?
	ocmd_read_ret $READY_WAIT_MS || return $?
	ocmd_check_err || return $?
}

# Operation-Mode Format Disk
#request: 5A 5A 06 00 ##
#return : 12 01 ?? ##
# Operation-mode format is essentially "mkfs". It creates a filesystem disk.
ocmd_format () {
	vecho 3 "${FUNCNAME[0]}($@)"
	local -i w=$FORMAT_WAIT_MS
	$pdd2 && {
		((w+=FORMAT_TPDD2_EXTRA_WAIT_MS))
		echo 'Formatting Disk, TPDD2 mode'
	} || {
		((operation_mode)) || fcmd_mode 1 || return 1
		echo 'Formatting Disk, TPDD1 "Operation" mode'
	}
	ocmd_send_req ${opr_fmt[req_format]} || return $?
	ocmd_read_ret $w 2 || return $?
	ocmd_check_err || return $?
}

# switch to FDC mode
ocmd_fdc () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	$pdd2 && { echo "$z requires TPDD1" ;return 1 ; }
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
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode)) || fcmd_mode 1 || return 1
	local r=${opr_fmt[req_open]} m ;printf -v m '%02X' $1
	((bank)) && printf -v r '%02X' $((0x$r+0x40))
	ocmd_send_req $r $m || return $?	# open the file
	ocmd_read_ret $OPEN_WAIT_MS || return $?
	ocmd_check_err
}

# Close File
# request: 5A 5A 02 00 ##
# return : 12 01 ?? ##
ocmd_close () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode)) || fcmd_mode 1 || return 1
	local r=${opr_fmt[req_close]}
	((bank)) && printf -v r '%02X' $((0x$r+0x40))
	ocmd_send_req $r
	ocmd_read_ret $CLOSE_WAIT_MS || return $?
	ocmd_check_err
}

# Delete File
# request: 5A 5A 05 00 ##
# return : 12 01 ?? ##
ocmd_delete () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode)) || fcmd_mode 1 || return 1
	local r=${opr_fmt[req_delete]}
	((bank)) && printf -v r '%02X' $((0x$r+0x40))
	ocmd_send_req $r || return $?
	ocmd_read_ret $DELETE_WAIT_MS 1 || return $?
	ocmd_check_err
}

# TPDD2 Rename File (TPDD1 does not have this command)
# $1 = destination filename
# request: 5A 5A 0D 1C ##  (0-24 filename, 25 attr)
# return : 12 01 ?? ##
ocmd_pdd2_rename () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	$pdd2 || { err_msg+=("$z Requires TPDD2") ;return 1 ; }
	local f="$1" a="$2" r=${opr_fmt[req_pdd2_rename]}
	((bank)) && printf -v r '%02X' $((0x$r+0x40))
	((${#}>1)) || a="$ATTR"
	((${#a}==2)) || printf -v a "%02X" "'$a"
	mk_tpdd_file_name "$f"
	str_to_shex "$tpdd_file_name"
	ocmd_send_req $r ${shex[*]} $a || return $?
	ocmd_read_ret $RENAME_WAIT_MS 1 || return $?
	ocmd_check_err
}

# Read File data
# request: 5A 5A 03 00 ##
# return : 10 00-80 1-128bytes ##
ocmd_read () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode)) || fcmd_mode 1 || return 1
	local r=${opr_fmt[req_read]}
	((bank)) && printf -v r '%02X' $((0x$r+0x40))
	ocmd_send_req $r || return $?
	ocmd_read_ret $READ_WAIT_MS || return $?
	vecho 1 "$z: ret_fmt=$ret_fmt ret_len=$ret_len ret_dat=(${ret_dat[*]}) read_err=\"$read_err\""

	# check if the response was an error
	case "$ret_fmt" in
		"${opr_fmt[ret_std]}") ocmd_check_err ;return $? ;;
		"${opr_fmt[ret_read]}") ;;
		*) err_msg+=("$z: Unexpected Response") ;return 1 ;;
	esac

	# return true or not based on data or not
	# so we can do "while ocmd_read ;do ... ;done"
	((${#ret_dat[*]}))
}

# Write File Data
# request: 5A 5A 04 ?? 1-128 bytes ##
# return : 12 01 ?? ##
ocmd_write () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode)) || fcmd_mode 1 || return 1
	(($#)) || return 128
	local r=${opr_fmt[req_write]}
	((bank)) && printf -v r '%02X' $((0x$r+0x40))
	ocmd_send_req $r $* || return $?
	ocmd_read_ret $WRITE_WAIT_MS || return $?
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

# Read a standard FDC-mode 4-pair result
# essentially the FDC-mode version of ocmd_read_ret
# $* timout & busy indication forwarded to tpdd_read()
fcmd_read_ret () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==0)) || ocmd_fdc || return 1
	local -i i ;local x ;fdc_err= fdc_res= fdc_len=

	# read 8 bytes & reconstitute the hex pairs back to the original bytes
	tpdd_read 8 $* || return $?
	x="${rhex[*]}" ;printf -v x '%b' "\x${x// /\\x}"
	vecho 2 "$z: $x"

	# decode the 8 bytes as
	fdc_err=0x${x:0:2} # hex pair    uint8  error code
	fdc_res=0x${x:2:2} # hex pair    uint8  result data
	fdc_len=0x${x:4:4} # 2 hex pairs uint16 length or offset

	# look up the status/error message for fdc_err
	x= ;[[ "${fdc_msg[fdc_err]}" ]] && x="${fdc_msg[fdc_err]}"
	((fdc_err)) && err_msg+=("${x:-ERROR:${fdc_err}}")

	vecho 2 "$z: err:$fdc_err=\"${fdc_msg[fdc_err]}\" res:$fdc_res len:$fdc_len"
}

###############################################################################
# "FDC Mode" drive functions
# wrappers for each "FDC mode" function of the drive firmware

# Select operation mode
# fcmd_mode <0|1>
# 0=fdc 1=operation
fcmd_mode () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	$pdd2 && { err_msg+=("$z requires TPDD1") ;return 1 ; }
	((operation_mode)) && return
	(($#)) || return
	str_to_shex "${fdc_cmd[mode]}$1"
	tpdd_write ${shex[*]} 0D || return $?
	operation_mode=$1
	_sleep 0.1
	tpdd_drain
}

# Report not-ready conditions
# bit flags for some not-ready conditions
fcmd_ready () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==0)) || ocmd_fdc || return 1
	str_to_shex "${fdc_cmd[condition]}"
	tpdd_write ${shex[*]} 0D || return $?
	fcmd_read_ret $READY_WAIT_MS || return $?
	((fdc_err)) && return $fdc_err
	local -i b ;((fdc_res)) && { # bit flags
		for b in ${!fdc_cond[@]} ;do ((fdc_res&b)) && echo "${fdc_cond[b]}" ;done ;:
	} || echo "${fdc_cond[fdc_res]}"
}

# FDC-mode format disk
# The FDC-mode format command is a low level format that only writes the
# physical sector ID sections, including the logical sector size code.
# It allows the disk to be used with FDC-mode sector access commands to
# read and write raw data. It does not create the filesystem in sector 0.
# fcmd_format [logical_sector_size_code]
# size codes: 0=64 1=80 2=128 3=256 4=512 5=1024 6=1280 bytes
# The drive firmware defaults to 3 when not given, so this does too,
# but all disks with filesystems are actually either 0 or 6.
fcmd_format () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==0)) || ocmd_fdc || return 1
	typeset -i s=${1:-3}
	str_to_shex ${fdc_cmd[format]}$s
	echo "Formatting Disk, TPDD1 \"FDC\" mode, ${fdc_format_sector_size[s]:-\"\"}-Byte Logical Sectors"
	tpdd_write ${shex[*]} 0D || return $?
	fcmd_read_ret $FORMAT_WAIT_MS 2 || return $?
	((fdc_err)) && err_msg+=(", Sector:$fdc_res")
	return $fdc_err
}

# Sector ID section - See the software manual page 11
# There is one ID section per physical sector.
# There are 19 bytes described there, but the leading 5 header bytes and the
# trailing 2 crc bytes are used by the drive itself. In the 5-byte header,
# the logical sector size code is written by the format command. Other than
# that, only the 12 byte reserve section is readable/writable by the user.
# The read_id/write_id/search_id functions operate only on that field.
#
# The data can be anything. The drive's built-in filesystem
# (aka Operation-mode) uses only the first byte:
#   00 - current sector is not used by a file
#   ** - sector number of next sector in current file
#   FF - current sector is the last sector in current file

# Read sector ID section
# ri P [quiet]
# P : physical sector number 0-79 as plain ascii decimal integer
# [quiet] :used internally to suppress output during disk dump
fcmd_read_id () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==0)) || ocmd_fdc || return 1
	str_to_shex "${fdc_cmd[read_id]}$1"
	tpdd_write ${shex[*]} 0D || return $?
	fcmd_read_ret $RI_WAIT_MS || { err_msg+=("err:$? res:${fdc_res}") ;return $? ; }
	((fdc_err)) && { err_msg+=("err:$fdc_err res:${fdc_res}") ;return $fdc_err ; }
	tpdd_write 0D || return $?
	while _sleep 0.1 ;do tpdd_check && break ;done # sleep at least once
	tpdd_read $PDD1_SECTOR_ID_LENGTH || return $?
	((${#rhex[*]}<PDD1_SECTOR_ID_LENGTH)) && { err_msg+=("Got ${#rhex[*]} of $PDD1_SECTOR_ID_LENGTH bytes") ; return 1 ; }
	((${#2})) || printf "I %02u %04u %s\n" "$1" "$fdc_len" "${rhex[*]}"
}

# Read a logical sector
# A logical sector is a 64-1280 byte chunk of a 1280-byte physical sector.
# rl P L [quiet]
# P : physical sector number 0-79 as plain ascii decimal integer
# L : logical sector number 1-20 as plain ascii decimal integer
# [quiet] :used internally to suppress output during disk dump
fcmd_read_logical () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==0)) || ocmd_fdc || return 1
	local -i ps=$1 ls=${2:-1} || return $? ;local x
	str_to_shex "${fdc_cmd[read_sector]}$ps,$ls"
	tpdd_write ${shex[*]} 0D || return $?
	fcmd_read_ret $RL_WAIT_MS || { err_msg+=("err:$? res:${fdc_res}") ;return $? ; }
	((fdc_err)) && { err_msg+=("err:$fdc_err res:${fdc_res}") ;return $fdc_err ; }
	((fdc_res==ps)) || { err_msg+=("Unexpected Physical Sector \"$ps\" Returned") ;return 1 ; }
	tpdd_write 0D || return $?
	# tpdd_check() will say there is data available immediately, but if you
	# read too soon the data will be corrupt or incomplete. Take 2/3 of the
	# number of bytes we expect to read (64 to 1280), and sleep that many ms.
	ms_to_s $(((fdc_len/3)*2)) ;_sleep $_s
	tpdd_read $fdc_len || return $?
	((${#rhex[*]}<fdc_len)) && { err_msg+=("Got ${#rhex[*]} of $fdc_len bytes") ; return 1 ; }
	((${#3})) || printf "S %02u %02u %04u %s\n" "$ps" "$ls" "$fdc_len" "${rhex[*]}"
}

# Write a sector ID section
# wi P hex_pairs...
# P : physical sector number 0-79 as plain ascii decimal integer
# hex-pairs... : 12 hex pairs of sector ID data
fcmd_write_id () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==0)) || ocmd_fdc || return 1
	local -i p=$((10#$1)) ;shift
	str_to_shex "${fdc_cmd[write_id]}$p"
	tpdd_write ${shex[*]} 0D || return $?
	fcmd_read_ret $WI_WAIT_MS || { err_msg+=("err:$? res:${fdc_res}") ;return $? ; }
	((fdc_err)) && { err_msg+=("err:$fdc_err res:${fdc_res}") ;return $fdc_err ; }
	tpdd_write $* || return $?
	fcmd_read_ret $WI_WAIT_MS || { err_msg+=("err:$? res:${fdc_res}") ;return $? ; }
	((fdc_err)) && { err_msg+=("err:$fdc_err res:${fdc_res}") ;return $fdc_err ; }
	:
}

# Write a logical sector
# wl P L hex-pairs...
# P : physical sector number 0-79 as plain ascii decimal integer
# L : logical sector number 1-20 as plain ascii decimal integer
# hex-pairs... : 64-1280 bytes of binary sector data as spaced hex pairs
# The number of bytes of data must match the target sector's logical
# sector size. (written into the ID section by the format command)
fcmd_write_logical () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==0)) || ocmd_fdc || return 1
	local -i ps=$((10#$1)) ls=$((10#$2)) ;shift 2
	str_to_shex "${fdc_cmd[write_sector]}$ps,$ls"
	tpdd_write ${shex[*]} 0D || return $?
	fcmd_read_ret $WL_WAIT_MS || { err_msg+=("err:$? res:${fdc_res}") ;return $? ; }
	((fdc_err)) && { err_msg+=("err:$fdc_err res:${fdc_res}") ;return $fdc_err ; }
	tpdd_write $* || return $?
	fcmd_read_ret $WL_WAIT_MS || { err_msg+=("err:$? res:${fdc_res}") ;return $? ; }
	((fdc_err)) && { err_msg+=("err:$fdc_err res:${fdc_res}") ;return $fdc_err ; }
	:
}


###############################################################################
# TPDD2

# TPDD2 Get Drive Status
# request: 5A 5A 0C 00 ##
# return : 15 01 ?? ##
pdd2_ready () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	$pdd2 || { err_msg+=("$z requires TPDD2") ;return 1 ; }
	local -i i b
	ocmd_send_req ${opr_fmt[req_condition]} || return $?
	ocmd_read_ret $READY_WAIT_MS || return $?
	i=0x${ret_dat[0]} ;((i)) && { # bit flags
		for b in ${!pdd2_cond[@]} ;do ((i&b)) && echo "${pdd2_cond[b]}" ;done ;:
	} || echo "${pdd2_cond[i]}"
}

# TPDD2 read from cache
# pdd2_cache_read mode offset length [filename]
pdd2_cache_read () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	$pdd2 || { err_msg+=("$z requires TPDD2") ;return 1 ; }
	local x

	# 4-byte request data
	# 00         mode
	# 0000-04C0  offset
	# 00-FC      length
	printf -v x '%02X %02X %02X %02X' $1 $((($2>>8)&0xFF)) $(($2&0xFF)) $3
	ocmd_send_req ${opr_fmt[req_cache_read]} $x || return $?
	ocmd_read_ret $RC_WAIT_MS || return $?

	# returned data:
	# [0]     mode
	# [1][2]  offset
	# [3]+    data
	((${#4})) && {
		printf '%02X %02X %s\n' "$track_num" "$sector_num" "${ret_dat[*]}" >>$4
	} || {
		printf 'T:%02u S:%u m:%u O:%05u %s\n' "$track_num" "$sector_num" "$((0x${ret_dat[0]}))" "$((0x${ret_dat[1]}${ret_dat[2]}))" "${ret_dat[*]:3}"
	}
}

# TPDD2 write to cache
# pdd2_cache_write mode offset_msb offset_lsb data...
pdd2_cache_write () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	$pdd2 || { err_msg+=("$z requires TPDD2") ;return 1 ; }
	ocmd_send_req ${opr_fmt[req_cache_write]} $* || return $?
	ocmd_read_ret $WC_WAIT_MS || return $?
	ocmd_check_err
}

# TPDD2 copy sector between disk and cache
# pdd2_cache_load track sector mode
# pdd2_cache_load 0-79 0-1 0|2
# mode: 0=disk-to-cache 2=cache-to-disk
pdd2_cache_load () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	$pdd2 || { err_msg+=("$z requires TPDD2") ;return 1 ; }
	local x m=${3:-0} ;track_num=$1 sector_num=$2

	# 5-byte request data
	# 00|02 mode
	# 00    unknown
	# 00-4F track#
	# 00    unknown
	# 00-01 sector
	printf -v x '%02X 00 %02X 00 %02X' $m $track_num $sector_num

	ocmd_send_req ${opr_fmt[req_cache_load]} $x || return $?
	ocmd_read_ret $SC_WAIT_MS || return $?
	ocmd_check_err
}

pdd2_flush_cache () {
	# mystery metadata writes - no idea, copied from backup log
	pdd2_cache_write 01 00 83 || return $?
	pdd2_cache_write 01 00 96 || return $?
	# flush the cache to disk
	pdd2_cache_load $1 $2 2 || return $?
}


###############################################################################
# Server Functions
# These functions are for talking to a client not a drive

# write $* to com port with per-character delay
# followed by the BASIC EOF character
slowbyte () {
	printf '%b' "\x$1" >&3
	_sleep $s
}

srv_send_loader () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local -i i l ;local s REPLY x="${XONOFF:-false}"
	ms_to_s $LOADER_PER_CHAR_MS ;s=${_s}
	file_to_fhex $1

	XONOFF=true ;set_stty

	echo "Installing $1"
	echo 'Prepare the portable to receive:'
	echo 'TANDY, Kyotronic, Olivetti:  RUN "COM:98N1ENN"'
	echo '                       NEC:  RUN "COM:9N81XN"'
	read -p 'Press [Enter] when ready...'

	l=${#fhex[*]}
	for ((i=0;i<l;i++)) ;do
		slowbyte ${fhex[i]}
		((v)) && {
			((i && 0x${fhex[i-1]}==0x$BASIC_EOL && 0x${fhex[i]}!=0x0A)) && echo
			printf '%b' "\x${fhex[i]}"
		} || pbar $((i+1)) $l 'bytes'
	done

	# Send trailing CR and/or Ctrl-Z, if the file didn't. Don't pbar() just
	# so the final bytes-sent display still matches the expected file size.
	case ${fhex[i]} in
		$BASIC_EOF) : ;;
		$BASIC_EOL) slowbyte $BASIC_EOF ;;
		*) slowbyte $BASIC_EOL ;slowbyte $BASIC_EOF ;;
	esac

	XONOFF=$x ;set_stty ;echo
}

###############################################################################
# Local Commands
# high level functions implemented here in the client

# Unconditional blind send: fdc set mode 1, opr switch to fdc, fdc set mode 1
# Drain any output. To recover the drive from an unknown / out-of-sync state
# to a known state. Send without the normal checking if they're valid in context.
fonzie_smack () {
	vecho 2 "${FUNCNAME[0]}($@)"
	tpdd_drain
	tpdd_write 4D 31 0D       # M1\r - fdc set mode 1 (switch from fdc to opr)
	_sleep 0.01
	tpdd_drain
	tpdd_write 5A 5A 08 00 F7 # ZZ 08 - opr switch to fdc
	_sleep 0.01
	tpdd_drain
	tpdd_write 4D 31 0D       # M1\r - fdc set mode 1 (switch from fdc to opr)
	_sleep 0.01
	tpdd_drain
	operation_mode=1 bd=
}

bank () {
	$pdd2 || { bank=0 bd= operation_mode=1 ;perr "requires TPDD2" ; return 1; }
	(($#)) && bank=$1 || { ((bank)) && bank=0 || bank=1 ; }
	bd="[$bank]"
	echo "Bank: $bank"
}

# select one of the pre-defined compatibility modes for filename format & attr byte
ask_compat () {
	local PS3="Filenames Compatibility Mode: "
	((${#1})) && parse_compat $1 || select COMPAT in ${!compat[@]} ;do
		parse_compat && break || continue
	done
}

# set the filename format without changing anything else
ask_names () {
	local x m=() a="$ATTR" PS3="On-disk filename format: "
	((${#1})) && parse_compat $1 || {
		for COMPAT in ${!compat[@]} ;do
			parse_compat ;ATTR="$a" ;printf -v x "%8s: %d" "$COMPAT" "$FNL"
			((FNL<TPDD_FILENAME_LENGTH)) && x+=".$FEL"
			m+=("$x")
		done
		select x in "${m[@]}" ;do x="${x%:*}"
			parse_compat "${x// /}" && break || continue
		done
	}
	[[ ":$ATTR" != ":$a" ]] && ATTR="$a" COMPAT="none"
}

set_attr () {
	case ${#1} in
		1) ATTR="$1" ;printf -v FAH "%02X" "'$ATTR" 2>&- >&- || return 1 ;;
		2) FAH="$1" ;printf -v ATTR "%b" "\x$FAH" 2>&- >&- || return 1 ;;
		*) return 1;
	esac
}

# set the attr byte without changing anything else
# surely this can be smaller
ask_attr () {
	local -i n="$FNL" e="$FEL" ;local x a=() m=() PS3="Attribute byte: "
	((${#1})) && set_attr "$1" || {
		for COMPAT in ${!compat[@]} ;do
			parse_compat ;FNL="$n" FEL="$e"
			[[ "${a[$FAH]}" ]] || a[$FAH]="$ATTR" m+=("$FAH '$ATTR'")
		done
		select x in "${m[@]}" other ;do
		x="${x%% *}"
		case "$x" in
			other) x= ;read -p "Enter a single byte or a hex pair: " x ;;
			*) [[ "${a[$x]}" ]] && x="${a[$x]}" || x= ;;
		esac
			set_attr "$x" && break
		done
	}
	((FNL==n && FEL==e)) || COMPAT="none" FNL="$n" FEL="$e"
}

# list disk directory
lcmd_ls () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local -i m=${dirent_cmd[get_first]} ;local t f

	$pdd2 && {
		echo "-----  Directory Listing   [$bank]  -----"
	} || {
		echo '--------  Directory Listing  --------'
	}
	while ocmd_dirent '' "$1" $m ;do
		un_tpdd_file_name "$file_name"

		$EXPOSE_FILENAMES && { # expose non-printable bytes in filenames
			local -i i x ;local t f=
			for ((i=0;i<24;i++)) {
				t="${file_name:i:1}"
				printf -v x "%u" "'$t"
				((x>0&&x<32||x>126)) && printf -v t "\033[7m%02X\033[m" $x
				((x)) || t=' '
				f+="$t"
			}
			t="$file_attr"
			printf -v x "%u" "'$t"
			((x<32||x>126)) && printf -v t "\033[7m%02X\033[m" $x
			printf '%s | %s | %6u\n' "$f" "$t" "$file_len"
		} || { # normal filename display
			printf '%-24.24b | %1s | %6u\n' "$file_name" "$file_attr" "$file_len"
		}

		((m==${dirent_cmd[get_first]})) && m=${dirent_cmd[get_next]}
	done
	echo '-------------------------------------'
	echo "$((free_sectors*PHYSICAL_SECTOR_LENGTH)) bytes free"
}


# load a file (copy a file from tpdd to local file or memory)
# lcmd_load src [dest] [attr]
# If $2 is absent, use local filename same as tpdd filename
# If $#=4 read into global fhex[] instead of writing a file
# (load needs seperate way to detect load-to-ram because
#  $2 can be set-but-empty when specifying attr)
lcmd_load () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local x s="$1" d="${2:-$1}" a="$3" r=false ;local -i p= l= ;fhex=()
	((${#}<3)) && a="$ATTR"
	((${#}>3)) && r=true
	$r && d= || {
		((${#d})) || {
			echo "save src [dest] [attr]"
			echo "src  - tpdd filename"
			echo "dest - local filename - absent or '' = same as src"
			echo "attr - attribute - absent=default '$ATTR'  ''=0x00  ' '=0x20"
			return 1
		}
	}
	echo -n "Loading TPDD$bd:$s ($a)"
	vecho 1 ""
	ocmd_dirent "$s" "$a" ${dirent_cmd[set_name]} || return $?	# set the source filename
	((${#file_name})) || { err_msg+=('No Such File') ;return 1 ; }
	l=$file_len							# file size provided by dirent()
	((${#d})) && {
		echo " to $d"
		[[ -e "$d" ]] && { err_msg+=('File Exists') ;return 1 ; }
		> "$d"
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
		((p>=l)) && break	# done # $l is inaccurate, but it's worse if we don't halt on it
	done
	ocmd_close || return $?				# close the source file
	# Can't do this sanity check because the file size from dirent() is worthless.
	#((p==l)) || { err_msg+=("Error: Expected $l bytes, got $p") ; return 1 ; }
	((p<l)) && { err_msg+=("Error: Expected $l bytes, got $p") ; return 1 ; }
	((v>1)) && ((p!=l)) && err_msg+=("Expected $l bytes, got $p")
	echo
}

# save a file (copy a file from local file or memory to tpdd)
# lcmd_save source [dest] [attr]
# If $1 is set but '', get data from global fhex[] instead of reading a file
lcmd_save () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local -i n p l ;local s d a t=false
	((${#1}+${#2})) || set -- # either may be '', both trigger help
	((${#2})) || t=true # remember if dest was not supplied originally
	case $# in
		1|2) s="$1" d="${2:-$1}" a="$ATTR" ;;
		3) s="$1" d="$2" a="$3" ;((${#d})) || d="$s" ;;
		*) echo "save src [dest] [attr]"
			echo "src  - local filename"
			echo "dest - tpdd filename - absent or '' = same as src"
			echo "attr - attribute - absent=default '$ATTR'  ''=0x00  ' '=0x20"
			return 2 ;;
	esac
	((${#s})) && {
		[[ -r "$s" ]] || { err_msg+=("\"$s\" not found") ;return 1 ; }
		file_to_fhex "$s" || return 4
	}
	l=${#fhex[*]}
	echo "Saving TPDD$bd:$d ($a)"
	ocmd_dirent "$d" "$a" ${dirent_cmd[set_name]} || return $?
	((${#file_name})) && { err_msg+=('File Exists') ; return 1 ; }
	ocmd_open ${open_mode[write_new]} || return $?
	for ((p=0;p<l;p+=TPDD_DATA_MAX)) {
		pbar $p $l 'bytes'
		ocmd_write ${fhex[*]:p:$TPDD_DATA_MAX} || return $?
	}
	pbar $l $l 'bytes'
	echo
	ocmd_close || return $?
}

# delete a file
# lcmd_rm filename [attr]
lcmd_rm () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local a
	vecho 2 "#=$# @=\"$@\""
	case $# in # $2 empty distinct from absent
		2) a="$2" ;;
		1) a="$ATTR" ;;
		*) return 1 ;;
	esac
	echo -n "Deleting TPDD$bd:$1 ($a) "
	ocmd_dirent "$1" "$a" ${dirent_cmd[set_name]} || return $?
	((${#file_name})) || { err_msg+=('No Such File') ;return 1 ; }
	ocmd_delete || return $?
}

lcmd_mv () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local sn dn sa da
	case $# in
		2) sn="$1" sa="$ATTR" dn="$2" da="$ATTR" ;;
		3) sn="$1" sa="$2" dn="$3" da="$2" ;;
		4) sn="$1" sa="$2" dn="$3" da="$4" ;;
		*) err_msg+=('mv: usage:\nsrc_name dest_name\nsrc_name src_attr dest_name [dest_attr]') ;return 1 ;;
	esac
	$pdd2 && { # TPDD2 has a rename function
		echo "Moving TPDD$bd: $sn ($sa) -> $dn ($da)"
		ocmd_dirent "$sn" "$sa" ${dirent_cmd[set_name]} || return $?
		ocmd_pdd2_rename "$dn" "$da" ;return $?
	} # TPDD1 requires load>rm>save, or edit the SMT
	lcmd_load "$sn" '' "$sa" r && lcmd_rm "$sn" "$sa" && lcmd_save '' "$dn" "$da"
}

lcmd_cp () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local sn sa dn da
	case $# in
		2) sn="$1" sa="$ATTR" dn="$2" da="$ATTR" ;;
		4) sn="$1" sa="$2" dn="$3" da="$4" ;;
		*) err_msg+=('cp: usage:\nsrc_name dest_name\nsrc_name src_attr dest_name dest_attr') ;return 1 ;;
	esac
	lcmd_load "$sn" '' "$sa" r && lcmd_save '' "$dn" "$da"
}

# read all logical sectors in a physical sector
# lcmd_read_physical physical [quiet]
pdd1_read_physical () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
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
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local -i p t=$PHYSICAL_SECTOR_COUNT n ;local f=$1
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

		# read the DATA section
		pdd1_read_physical $p $f || return $?
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
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
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
		fcmd_write_id ${r[0]} ${r[@]:2:$((PDD1_SECTOR_ID_LENGTH))} || return $?

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

# TPDD2 dump disk
# pdd2_dump_disk [filename]
pdd2_dump_disk () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	$pdd2 || { err_msg+=("$z requires TPDD2") ;return 1 ; }
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
			pdd2_cache_load $t $s 0 || return $?
			pdd2_cache_read 1 32772 4 $1 || return $? # metadata, total mystery but backup program does it
			for ((f=0;f<fq;f++)) {
				pdd2_cache_read 0 $((PDD2_SECTOR_CHUNK_LENGTH*f)) $PDD2_SECTOR_CHUNK_LENGTH $1 || return $?
				((${#1})) && pbar $((b+=PDD2_SECTOR_CHUNK_LENGTH)) $tb bytes
			}
		}
	}

	((${#1})) && echo
}

pdd2_restore_disk () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	$pdd2 || { err_msg+=("$z requires TPDD2") ;return 1 ; }
	local d r ;local -i i n t s m b= tb=$((PHYSICAL_SECTOR_LENGTH*PHYSICAL_SECTOR_COUNT*2)) ;track_num= sector_num=

	# Format the disk
	ocmd_format || return $?

	# Read the dump file into d[]
	exec 5<"$1" || return $?
	mapfile -u 5 d || return $?
	exec 5<&-
	n=${#d[@]}

	# Write the sectors
	# each d[i] is a record in the file -> one chunk of a 1280-byte sector:
	# track# sector# mode offset_msb offset_lsb data...
	# for each record: parse the 5 header bytes, write data to cache
	# repeat until sector number changes,
	#    then flush cache to disk before writing the new chunk to cache
	# repeat until EOF, flush the cache for the final sector
	echo "Restoring Disk from $1"
	for ((i=0;i<n;i++)) {
		r=(${d[i]})
		vecho 2 "${r[*]}"

		t=0x${r[0]} s=0x${r[1]} m=0x${r[2]}

		# encountered new sector in file, write cache to disk
		((t==track_num)) && ((s==sector_num)) || {
			((i)) && { pdd2_flush_cache $track_num $sector_num || return $? ; }
			track_num=$t sector_num=$s
		}

		((m)) || pbar $((b+=${#r[*]}-5)) $tb 'bytes'

		# write to cache
		pdd2_cache_write ${r[*]:2} || return $?
	}
	pdd2_flush_cache $track_num $sector_num || return $?
	echo
}

# read the Space Managment Table
# track 0 sector 0, bytes 1240-1261
# The first 20 bytes are 80 pairs of bit flags
# for each byte 1-20:
#   bit 8: 1=used flag for the first sector
#   bit 7: TPDD1:reserved / TPDD2: used flag for next sector
#   bit 6: used flag for the next sector
#   bit 5: TPDD1:reserved / TPDD2: used flag for next sector
#   ... repeat for: TPDD1: 4 pairs, -> 4 sectors per byte
#                   TPDD2: 8 bits, -> 8 sectors per byte
# ... repeat for 20 bytes -> 80 sectors (TPDD2: 80 tracks, 2 sectors each)
# byte 21 = used sectors counter
read_smt () {
	local x=() s=() ci co f=() w ;local -i y i= l=
	# read the 21 bytes
	$pdd2 && {
		pdd2_cache_load 0 $bank 0 || return $?
		pdd2_cache_read 0 $SMT_OFFSET $SMT_LENGTH >/dev/null || return $?
		x=(${ret_dat[*]:3})
		echo "warning: read_smt() is probably wrong for tpdd2"
	} || {
		pdd1_read_physical 0 >/dev/null || return $?
		x=(${rhex[*]:$SMT_OFFSET:$SMT_LENGTH})
	}
	echo "SMT${bd}: ${x[*]}"
	# parse the bit flags and counter
	echo "Bytes 1-20: bit-flags of used sectors:"
	f=(0x80 0x20 0x08 0x02) w='02'
	$pdd2 && f=(0x80 0x40 0x20 0x10 0x08 0x04 0x02 0x01) w='03'
	for ((y=0;y<SMT_LENGTH-1;y++)) {
		for b in ${f[*]} ;do
			ci= co= ;((0x${x[y]}&b)) && ci="\e[7m" co="\e[m"
			printf "%b%${w}u%b" "$ci" $((i++)) "$co"
			((++l<20)) && printf ' ' || { printf "\n" ;l=0 ; }
		done
	}
	printf "Byte 21: sectors used count: %d sectors (%d bytes)\n" "0x${x[y]}" "$((0x${x[y]}*PHYSICAL_SECTOR_LENGTH))"
}

###############################################################################
# manual/raw debug commands

lcmd_com_show () {
	local -i e=
	lcmd_com_test ;e=$?
	stty ${stty_f} "${PORT}" -a
	return $e
}

lcmd_com_test () {
	local -i e=
	test_com ;e=$?
	((e)) && echo 'com is closed' || echo 'com is open'
	return $e
}

lcmd_com_open () {
	open_com
	lcmd_com_test
}

lcmd_com_close () {
	close_com
	lcmd_com_test
}

# TPDD2 write to cache, decimal offset for cli convenience
# lcmd_cache_write mode offset data...
lcmd_cache_write () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	$pdd2 || { err_msg+=("$z requires TPDD2") ;return 1 ; }
	local x

	# payload header
	# 00|01      mode
	# 0000-0500  offset
	printf -v x '%02X %02X %02X' $1 $((10#$2/256)) $((10#$2%256)) ;shift 2

	pdd2_cache_write $x $* || return $?
}

###############################################################################
# experimental junk

# Emulate a client performing the TPDD1 boot sequence
# pdd1_boot [100|200]
pdd1_boot () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local REPLY M mdl=${1:-100}

	close_com
	open_com 9600

	echo -en "------ TDPP1 (26-3808) bootstrap ------\n" \
		"Turn the drive power OFF.\n" \
		"Set all 4 dip switches to ON.\n" \
		"Insert a TPDD1 (26-3808) Utility Disk.\n" \
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
	close_com
	echo

	# cycle the port (close & open) between reads
	echo -e " Don't trust the following binary reads.\n" \
		"They come out a little different every time.\n" \
		"tpdd_read_unknown() isn't good enough yet.\n" >&2

	# collect some binary
	open_com 9600
	tpdd_read_unknown
	close_com
	printf '%s\n\n' "${rhex[*]}"

	# collect some more binary
	open_com 9600
	tpdd_read_unknown
	close_com
	printf '%s\n\n' "${rhex[*]}"

	# collect some more binary
	open_com 9600
	tpdd_read_unknown
	close_com
	printf '%s\n\n' "${rhex[*]}"

	echo -e " IPL done.\n" \
		"Turn the drive power OFF.\n" \
		"Set all 4 dip switches to OFF.\n" \
		"Turn the drive power ON." >&2

	open_com
}

# Emulate a client performing the TPDD2 boot sequence
# pdd2_boot [100|200]
pdd2_boot () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local REPLY M mdl=${1:-100}

	echo -en "------ TDPP2 (26-3814) bootstrap ------\n" \
		"Turn the drive power OFF.\n" \
		"Insert a TPDD2 (26-3814) Utility Disk.\n" \
		"(Verify that the write-protect hole is OPEN)\n" \
		"Leave the drive power OFF.\n" \
		"Press [Enter] when ready: " >&2
	read -s
	echo -e "\n\nNow turn the drive power ON." >&2


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
	close_com
	echo

	# cycle the port (close & open) between reads
	echo -e " Don't trust the following binary reads.\n" \
		"They come out a little different every time.\n" \
		"tpdd_read_unknown() isn't good enough yet.\n" >&2

	# collect binary
	open_com
	tpdd_read_unknown
	close_com
	printf '%s\n\n' "${rhex[*]}"

	# collect binary
	open_com
	tpdd_read_unknown
	close_com
	printf '%s\n\n' "${rhex[*]}"

	# collect binary
	open_com
	tpdd_read_unknown
	close_com
	printf '%s\n\n' "${rhex[*]}"

	open_com
}

###############################################################################
# Main Command Dispatcher

do_cmd () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local -i _i _e _det=256 ;local _a=$@ _c ifs=$IFS
	local IFS=';' ;_a=(${_a}) ;IFS=$ifs
	for ((_i=0;_i<${#_a[@]};_i++)) {
		eval set ${_a[_i]}
		_c=$1 ;shift
		_e=${_det} err_msg=()

	# commands that don't need or are even broken by _ini()
	# mostly options, controls, mode-setting, local/internal functions,
	# mostly things that don't send commands to the drive
		case ${_c} in
			1|pdd1|tpdd1) pdd2=false operation_mode=1 bd= _e=$? ;;
			2|pdd2|tpdd2) pdd2=true operation_mode=2 bd="[$bank]" _e=$? ;;
			b|bank) bank $1 ;_e=$? ;;
			names) ask_names "$@" ;_e=$? ;;
			attr|attrib|attribute) ask_attr "$@" ;_e=$? ;;
			compat) ask_compat "$@" ;_e=$? ;;
			floppy|wp2|raw) ask_compat "${_c}" ;_e=$? ;;
			baud|speed) BAUD=$1 ;set_stty ;lcmd_com_show ;_e=$? ;;
			rts|cts|rtscts) RTSCTS=${1:-true} ;set_stty ;lcmd_com_show ;_e=$? ;;
			xon|xoff|xonoff|xonxoff) XONOFF=${1:-false} ;set_stty ;lcmd_com_show ;_e=$? ;;
			com_test) lcmd_com_test ;_e=$? ;; # check if port open
			com_show) lcmd_com_show ;_e=$? ;; # check if port open
			com_open) lcmd_com_open ;_e=$? ;; # open the port
			com_close) lcmd_com_close ;_e=$? ;; # close the port
			sync|drain) tpdd_drain ;_e=$? ;;
			sum|checksum) calc_cksum $* ;_e=$? ;;
			ocmd_check_err) ocmd_check_err ;_e=$? ;;
			boot|bootstrap|send_loader) srv_send_loader "$@" ;_e=$? ;;
			sleep) _sleep $* ;_e=$? ;;
			debug|verbose) ((${#1})) && v=$1 || { ((v)) && v=0 || v=1 ; } ;_e=0 ;;
			expose) $EXPOSE_FILENAMES && EXPOSE_FILENAMES=false || EXPOSE_FILENAMES=true ; echo "Expose non-printable bytes in filenames: $EXPOSE_FILENAMES" ;_e=0 ;;
			q|quit|bye|exit) exit ;;
			'') _e=0 ;;
		esac
		((_e!=_det)) && { # detect if we ran any of the above
			((${#err_msg[*]})) && printf '\n%s: %s\n' "${_c}" "${err_msg[*]}" >&2
			continue
		}

	# We need this split and delayed _init(), instead of just doing _init()
	# once at start=up right in main, to avoid doing _init() until we
	# actually have a drive connected, or at least until the user asks for
	# a command that sends to a drive.
	#
	# Especially avoid doing _init() for bootstrap. In bootstrap scenario,
	# there is either no cable connected yet, or it's connected but the
	# serial port is not open and the client is not receiving, and we would
	# block while trying to send the TPDD2 detect command,
	# and again later when trying to send the FDC->OPR command on exit.
		$did_init || _init
		_e=0

	# TPDD1 operation-mode commands
	# TPDD1 & TPDD2 file access
	# All of the drive firmware "operation mode" functions.
	# Most of these are low-level, not used directly by a user.
	# Higher-level commands like ls, load, & save are built out of these.
		case ${_c} in
			dirent) ocmd_dirent "$@" ;_e=$? ;;
			open) ocmd_open $* ;_e=$? ;;
			close) ocmd_close ;_e=$? ;;
			read) ocmd_read $* ;_e=$? ;;
			write) ocmd_write $* ;_e=$? ;;
			delete) ocmd_delete ;_e=$? ;;
			format|mkfs) ocmd_format ;_e=$? ;;
			ready|status) ocmd_ready ;_e=$? ;((_e)) && printf "Not " ;echo "Ready" ;;

	# TPDD1 switch between operation and fdc-modes
			fdc) ocmd_fdc ;_e=$? ;;
			opr) fcmd_mode 1 ;_e=$? ;;
			pdd1_reset) pdd1_mode_reset ;_e=$? ;;

	# TPDD1 sector access
	# All of the drive firmware "FDC mode" functions.
			${fdc_cmd[mode]}|set_mode|mode) fcmd_mode $* ;_e=$? ;; # select operation-mode or fdc-mode
			${fdc_cmd[condition]}|condition|cond) $pdd2 && { pdd2_ready ;_e=$? ; } || { fcmd_ready ;_e=$? ; } ;; # get disk/drive readiness condition flags
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
			cache_load) pdd2_cache_load $* ;_e=$? ;;	# load cache to or from disk
			cache_read) pdd2_cache_read $* ;_e=$? ;;	# read from cache to client
			cache_write) lcmd2_cache_write $* ;_e=$? ;;	# write from client to cache

	# TPDD1 & TPDD2 local/client commands
			ls|dir) lcmd_ls "$@" ;_e=$? ;;
			rm|del|delete) lcmd_rm "$@" ;_e=$? ;;
			load) (($#<4)) && lcmd_load "$@" ;_e=$? ;; # 4 args is internal use
			save) lcmd_save "$@" ;_e=$? ;;
			mv|ren|rename) lcmd_mv "$@" ;_e=$? ;;
			cp|copy) lcmd_cp "$@" ;_e=$? ;;
			rp|read_physical) $pdd2 || { pdd1_read_physical "$@" ;_e=$? ; } ;;
			dd|dump_disk) $pdd2 && { pdd2_dump_disk "$@" ;_e=$? ; } || { pdd1_dump_disk "$@" ;_e=$? ; } ;;
			rd|restore_disk) $pdd2 && { pdd2_restore_disk "$@" ;_e=$? ; } || { pdd1_restore_disk "$@" ;_e=$? ; } ;;

	# other
			read_smt) read_smt ;_e=$? ;;
			model|detect|detect_model) ocmd_pdd2_unk23 ;_e=$? ;;
			pdd1_boot) pdd1_boot "$@" ;_e=$? ;; # [100|200]
			pdd2_boot) pdd2_boot "$@" ;_e=$? ;; # [100|200]
			*) ${_c} "$@" ;_e=$? ;;

		esac
		((${#err_msg[*]})) && printf '\n%s: %s\n' "${_c}" "${err_msg[*]}" >&2
	}
	return ${_e}
}

###############################################################################
# Main
typeset -a err_msg=() shex=() fhex=() rhex=() ret_dat=()
typeset -i _y= bank= operation_mode=1 read_err= fdc_err= fdc_res= fdc_len= track_num= sector_num= _om=99 FNL # allow FEL to be unset or ''
cksum=00 ret_err= ret_fmt= ret_len= ret_sum= tpdd_file_name= file_name= file_attr= ret_list='|' _s= pdd2=false bd= did_init=false
readonly LANG=C
ms_to_s $TTY_READ_TIMEOUT_MS ;read_timeout=${_s}
MODEL_DETECTION=true ;[[ "$0" =~ .*pdd[12](\.sh)?$ ]] && MODEL_DETECTION=false
((TPDD_MODEL==2)) || [[ "$0" =~ .*pdd2(\.sh)?$ ]] && pdd2=true operation_mode=2 bd="[$bank]" FONZIE_SMACK=false
for x in ${!opr_fmt[*]} ;do [[ "$x" =~ ^ret_.* ]] && ret_list+="${opr_fmt[$x]}|" ;done ;unset x
parse_compat

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
(($#)) && { do_cmd "$@" ;exit $? ; }

# interactive mode
while read -p"PDD(${mode[operation_mode]}$bd:$FNL${FEL:+.$FEL},$ATTR)> " __c ;do do_cmd "${__c}" ;done
