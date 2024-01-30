#!/usr/bin/env bash
[ -n "${BASH_VERSION}" ] || exec bash $0 $@
set +o posix
((${BASH_VERSINFO[0]}<4)) && { echo "Requires bash 4+" ;exit 1 ; }

#h pdd.sh - Tandy Portable Disk Drive client in pure bash
# Brian K. White - b.kenyon.w@gmail.com
#h github.com/bkw777/pdd.sh
# https://archive.org/details/tandy-service-manual-26-3808-s-software-manual-for-portable-disk-drive
# https://archive.org/details/tpdd-2-service-manual
# https://trs80stuff.net/tpdd/tpdd2_boot_disk_backup_log_hex.txt

###############################################################################
# CONFIG
#

###############################################################################
# behavior

# verbose/debug
case "${VERBOSE:=$DEBUG}" in
	false|off|n|no|"") VERBOSE=0 ;;
	true|on|y|yes|:) VERBOSE=1 ;;
esac

# print millisecond timestamps
: ${MSLOG:=false} # true|false

# see "help compat"
: ${COMPAT:=floppy}

# see "help expose"
: ${EXPOSE_BINARY:=1}

# see "help ffsize"
# default off because it only works on real drives and it's slower
# TODO: fail gracefully on emulators so this can be enabled by default
: ${FCB_FSIZE:=false} # true|false

# see "help verify"
: ${WITH_VERIFY:=true} # true|false

# assume "yes" to all confirmation prompts for scripting
: ${YES:=false} # true|false

# joggle the drive from an unknown to a known state in _init()
: ${FONZIE_SMACK:=true} # true|false

# see pdd1_restore_disk()
: ${PDD1_RD_CHECK_MIXED_LSC:=true} # true|false

# Default rs232 tty device name, with platform differences
# The automatic TPDD port detection will search "/dev/${TPDD_TTY_PREFIX}*"
			stty_f="-F" TPDD_TTY_PREFIX=ttyUSB	# linux
case "${OSTYPE,,}" in
	*bsd*) 		stty_f="-f" TPDD_TTY_PREFIX=ttyU ;;	# *bsd
	darwin*) 	stty_f="-f" TPDD_TTY_PREFIX=cu.  ;;	# osx
esac

# Default serial port settings and tty behavior.
: ${BAUD:=19200}
: ${RTSCTS:=true}
: ${XONOFF:=false}
STTY_FLAGS='raw pass8 clocal cread -echo time 1 min 1'

# filename extensions for disk image files
PDD1_IMG_EXT=pdd1
PDD2_IMG_EXT=pdd2

# terminal emulation
typeset -r \
	tstandout='\e[1m' \
	tinverse='\e[7m' \
	tclear='\e[m'

###############################################################################
# tunables

# tpdd_read() timeout
# When issuing the "read -t ..." command to read bytes from the serial port,
# wait up to this long (in ms) for the first byte to appear before giving up.
# It's long because the drive can require time to wake up.
TTY_READ_TIMEOUT_MS=5000

# tpdd_wait() polling interval
TPDD_WAIT_POLL_INTERVAL_MS=100

# tpdd_wait() timeouts
# How long to wait for a response from the drive before giving up.
# This is different from TTY_READ_TIMEOUT_MS. tpdd_wait() is a polling loop
# that only looks to see if bytes are available or not, without trying to
# actually read any. Each poll happens instantly regardless if data is available
# or not. The timeouts are how long to poll before giving up.
#
# These timouts need to account for the worst case scenario for each command.
#
# Several operations need longer or shorter timeouts than the default.
# Some operations take different amounts of time depending on the data or the
# disk contents, plus sometimes the drive takes an extra few seconds to wake up.
#
# So for example deleting a file might take as little as 3 seconds or as long
# as 20 depending on the other contents of the disk and the size of the file,
# plus possibly a few more to wake up first = allow 25 seconds to be safe.
#
# pdd2_version is an opposite case where we need to set a deliberately short
# timeout because TPDD2 will always respond fast, and TPDD1 will never respond,
# and we don't want to make every TPDD1 hang for 5 seconds on every _init().
#
# The 3 different format timeouts instead of 1 longer one are just for the
# the progress bar. Format takes so long that we want a percent-done progress
# indicator. The drive does not send any data during format, and we can't query
# the drive either, we can poll the tty to see if data is available but
# otherwise must just sit and wait at least the expected time before even
# considering giving up. So the progress bar is just an estimate based on
# elapsed time. If the expected time is too much longer than the actual time,
# then the job will appear to complete early and look like an error to the user.
DEFAULT_TIMEOUT_MS=5000
FORMAT1_WAIT_MS=105000      # ocmd_format on tpdd1 and fcmd_format
FORMAT1NV_WAIT_MS=85000     # fcmd_format no-verify
FORMAT2_WAIT_MS=115000      # ocmd_format on tpdd2
DELETE_WAIT_MS=25000        # ocmd_delete
RENAME_WAIT_MS=10000        # pdd2_rename
CLOSE_WAIT_MS=20000         # ocmd_close
DIRENT_WAIT_MS=10000        # ocmd_dirent
SEARCHID_WAIT_MS=25000      # fcmd_search_id
PDD2_VERSION_WAIT_MS=100    # pdd2_version
PDD2_SYSINFO_WAIT_MS=100    # pdd2_sysinfo
PDD2_CACHE_WAIT_MS=20000    # pdd2_cache

# Per-byte delay in send_loader()
LOADER_PER_CHAR_MS=8

#
# CONFIG
###############################################################################

###############################################################################
# CONSTANTS
#

###############################################################################
# operating modes
typeset -ra mode=(
	[0]=fdc     # operate a TPDD1 drive, in "FDC mode"
	[1]=opr     # operate a TPDD1 drive, in "Operation mode"
	[2]=pdd2    # operate a TPDD2 drive
	[3]=loader  # send an ascii BASIC file and BASIC_EOF out the serial port
	[4]=server  # vaporware
	[9]=-       # drive model/mode not determined yet
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
#	[req_nadsbox_seek]='09'
#	[req_nadsbox_tell]='0A'
#	[req_nadsbox_set_ext]='0B'
	[req_pdd2_condition]='0C'   # TPDD2
	[req_pdd2_rename]='0D'      # TPDD2
#	[req_nadsbox_get_ext]='0E'
#	[req_nadsbox_cond_list]='0F'
#	[req_pdd2_unk10]='10'
#	[req_pdd2_undoc11]='11'
#	[req_pdd2_unk12]='12'
#	[req_pdd2_unk13]='13'
#	[req_pdd2_unk14]='14'
#	[req_pdd2_unk15]='15'
	[req_pdd2_version]='23'     # TPDD2
	[req_pdd2_cache]='30'       # TPDD2
	[req_pdd2_mem_write]='31'   # TPDD2
	[req_pdd2_mem_read]='32'    # TPDD2
	[req_pdd2_sysinfo]='33'     # TPDD2
	[req_pdd2_exec]='34'        # TPDD2 exec: load cpu registers A & X and jump to address

# 0x47 is undocumented, but PakDOS uses it.
# TPDD2 responds the same as 0x07 drive status.
# TPDD1 ignores it.
# With every directory listing, PakDOS tries 0x47 first,
# and only if 0x47 is ignored, then does 0x07.
	[req_undoc47]='47'          # TPDD2: undocumented synonym for drive_status TPDD1: no response

	# returns
	[ret_read]='10'
	[ret_dirent]='11'
	[ret_std]='12'              # error open close delete status write pdd2_unk13 pdd2_unk14 pdd2_unk15
	[ret_pdd2_version]='14'     # TPDD2 pdd2_version
	[ret_pdd2_condition]='15'   # TPDD2
	[ret_pdd2_mem_write]='38'   # TPDD2 cache mem_write mem_read* unk0F unk10 unk12
	[ret_pdd2_mem_read]='39'    # TPDD2 mem_read* (*)mem_read returns 0x38 in the case of error
	[ret_pdd2_sysinfo]='3A'     # TPDD2 pdd2_sysinfo
	[ret_pdd2_exec]='3B'        # TPDD2 pdd2_exec
)

# Operation Mode Error Codes
typeset -rA opr_msg=(
	[00]='Operation Complete'
	# File
	[10]='File Not Found'
	[11]='File Exists'
	# Sequence
	[30]='Missing Filename'
	[31]='Directory Search Error'
	[35]='Bank Error'
	[36]='Parameter Error'
	[37]='Open Format Mismatch'
	[3F]='End of File'
	# Disk I/O
	[40]='No Start Mark'
	[41]='ID CRC Error'
	[42]='Sector Length Error'
	[44]='Format Verify Error'
	[45]='Disk Not Formatted'
	[46]='Format Interruption'
	[47]='Erase Offset Error'
	[49]='DATA CRC Error'
	[4A]='Sector Number Error'
	[4B]='Read Data Timeout'
	[4D]='Sector Number Error'
	# Protect
	[50]='Write-Protected Disk'
	[5E]='Disk Not Formatted' # Really just "No SMT"
	[5F]='Write-Protected TPDD1 Disk'
	# File Territory
	[60]='Directory Full'
	[61]='Disk Full'
	[6E]='File Too Long'
	# Disk Condition
	[70]='Disk Not Inserted'
	[71]='Disk Change Error'
	# Sensor
	[80]='No Index Signal'
	[81]='Abnormal Track 0 Signal'
	[82]='Abnormal Index Signal'
	[83]='Defective Disk (power-cycle to clear error)' # not in the manual but you can get the actual error
)

# Directory Entry Search Forms
typeset -rA dirent_cmd=(
	[set_name]=0
	[get_first]=1
	[get_next]=2
	[get_prev]=3	# TPDD2
	[close]=4		# TPDD2
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
	[60]='ID not found'
	[61]='Search ID Unexpected Parameter'
	[160]='Disk Not Formatted'
	[161]='Read Error'
	[176]='Write-Protected Disk'
	[193]='Invalid Command'
	[209]='Disk Not Inserted'
	[216]='Operation Interrupted'
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
typeset -ra lsl=(
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
typeset -ra pdd2_cond=(
	[0x00]='Ready'
	[0x01]='Low Battery'
	[0x02]='Disk Write-Protected'
	[0x04]='Disk Not Inserted'
	[0x08]='Disk Changed'
	[0x10]='Unknown condition bit 4'
	[0x20]='Unknown condition bit 5'
	[0x40]='Unknown condition bit 6'
	[0x80]='Unknown condition bit 7'
)

# version and sysinfo values
typeset -ra cpu_codes=(
	[0x10]='HD6301'
)
typeset -ra model_codes=(
	[0xE1]='Tandy Portable Disk Drive 2'
)


###############################################################################
# general constants

# PDD2_MEM_RD_LEN must divide SECTOR_DATA_LEN evenly and be < 253
# PDD2_MEM_WR_LEN must divide SECTOR_DATA_LEN evenly and be < 128

typeset -ri \
	OLD_PDD2_ID_LEN=4 \
	SECTOR_ID_LEN=12 \
	SECTOR_DATA_LEN=1280 \
	PDD1_SECTORS=80 \
	PDD2_TRACKS=80 \
	PDD2_SECTORS=2 \
	PDD2_MEM_RD_LEN=64 \
	PDD2_MEM_WR_LEN=64 \
	FILE_RW_LEN=128 \
	PDD1_MAX_FLEN=65534 \
	PDD2_MAX_FLEN=65535 \
	PDD2_ID_ADDR=0x8004 \
	SMT_LEN=21 \
	PDD_FCBS=40 \
	PDD_FNAME_LEN=24 \
	FCB_FATTR_LEN=1 \
	FCB_FSIZE_LEN=2 \
	FCB_FRESV_LEN=2 \
	FCB_FHEAD_LEN=1 \
	FCB_FTAIL_LEN=1 \
	CACHE_LOAD=0 \
	CACHE_COMMIT=1 \
	CACHE_COMMIT_VERIFY=2 \
	MEM_CACHE=0 \
	MEM_CPU=1 \
	ROM_START=0xF000 \
	ROM_LEN=0x1000

typeset -ri \
	PDD2_CHUNKS_R=$((SECTOR_DATA_LEN/PDD2_MEM_RD_LEN)) \
	PDD2_CHUNKS_W=$((SECTOR_DATA_LEN/PDD2_MEM_WR_LEN)) \
	PDD2_SECTORS_D=$((PDD2_TRACKS*PDD2_SECTORS)) \
	SMT_OFFSET=$(((PDD_FNAME_LEN+FCB_FATTR_LEN+FCB_FSIZE_LEN+FCB_FRESV_LEN+FCB_FHEAD_LEN+FCB_FTAIL_LEN)*PDD_FCBS))

typeset -r \
	BASIC_EOF='1A' \
	BASIC_EOL='0D'

# Filename field on the drive is 24 bytes. These can not exceed that.
# [platform_compatibility_name]=file_name_len , file_ext_len , hex_file_attr_byte
typeset -rA compat=(	# fname(dec.dec) fattr(hex)
	[floppy]='6,2,46'	# 6.2  F
	[wp2]='8,2,46'		# 8.2  F
#	[z88]='24,,00'		# 24   null     # not sure what z88 wants yet
#	[cpm]='24,,00'		# 24   null     # not sure what cp/m wants yet
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

mslog () {
	$MSLOG || return
	local -i nowms=$((${EPOCHREALTIME//./}/1000))
	echo "ms: $((nowms-lastms))"
	lastms=$nowms
}

# help [cmd]
help () {
	local a b ;local -i i c=0 d=$((v+1)) w=${COLUMNS:-80} s=0 x ;local -a f=() l=() ;((w--))
	mapfile -t f < $0
	for ((i=0;i<${#f[*]};i++)) {
		l=(${f[i]}) ;a=${l[0]}
		case "${a}" in
			\#h) a= b=${f[i]} ;b=${b#*#} ;b=${b:2} ;((${#b})) || b=' ' ;;
			\#c) a= b= c=${l[1]} ;;
			\#*) a= b= ;;
			*\)) ((c)) && ((d>=c || ${#1})) && {
					s=0 a=${a%%)*} b=${f[i]} ;a=${a//\\/}
					((${#1})) && [[ "|$a|" =~ "|$1|" ]] && s=1
					[[ "$b" =~ '#' ]] && b="${b##*#}" || b=
					printf -v b '\n %b%s%b %s' "$tstandout" "${a//|/ | }" "$tclear" "${b:1}"
				} || a= b=
				;;
			*) a= b= ;;
		esac
		((${#1})) && ((s==0)) && continue
		((c)) && ((d<c)) && ((s==0)) && continue
		[[ $b == ' ' ]] && { echo ;continue ; }
		while ((${#b})) ;do
			((c)) && ((${#a}==0)) && b="    $b"
			x=$w ;until [[ "$IFS" =~ "${b:x:1}" || $x -lt 1 ]] ;do ((x--)) ;done
			((x<1)) && x=$w
			printf '%s\n' "${b:0:x}"
			b=${b:x}
		done
	}
	((v)) || ((${#1})) || printf '\nSet verbose 1 or greater to see more commands.\n'
	echo
}

_sleep () {
	read -t ${1:-1} -u 4 ;:
}

ask () {
	$YES && return 0
	local r=
	read -p"${@}" r
	[[ ${r,,} == y ]]
}

confirm () {
	ask "${@}: Are you sure? (y/N) "
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
	((FNL<PDD_FNAME_LEN)) && {
		n="${f%.*}" e="${f##*.}" ;[[ $n == $e ]] && e= ;n=${n//./_}
		printf -v f "%-${FNL}.${FNL}s.%-${FEL}.${FEL}s" "$n" "$e"
	}
	printf -v tpdd_file_name "%-${PDD_FNAME_LEN}.${PDD_FNAME_LEN}s" "$f"
}

# Floppy/WP-2 compat modes, just strip all spaces.
un_tpdd_file_name () {
	vecho 3 "${FUNCNAME[0]}($@)"
	file_name="$1"
	((FNL<PDD_FNAME_LEN)) && file_name=${file_name// /}
	:
}

# Read a local file into hex pairs stored in fhex[]
file_to_fhex () {
	$quiet || vecho 2 "${FUNCNAME[0]}($@)"
	local -i i= m=${2:-$PDD_MAX_FLEN} ;local x ;fhex=()
	[[ -r $1 ]] || { $quiet || err_msg+=("\"$1\" not found or not readable") ;return 1 ; }
	while IFS= read -d '' -r -n 1 x ;do
		printf -v fhex[i++] '%02X' "'$x"
		((m)) && ((i>m)) && { $quiet || err_msg+=("\"$1\" exceeds $PDD_MAX_FLEN bytes") ;fhex=() i=-1 ;break ; }
	done <"$1"
	$quiet || vecho 2 "${#fhex[*]} bytes"
	((i>-1))
}

# Progress indicator
# pbar part whole [units]
#   pbar 14 120
#   [####....................................] 11%
#   pbar 14 120 seconds
#   [####....................................] 11% (14/120 seconds)
pbar () {
	((v)) && return
	local -i i c p=$1 w=$2 p_len w_len=40 ;local b= s= u=$3
	((w)) && c=$((p*100/w)) p_len=$((p*w_len/w)) || c=100 p_len=$w_len
	for ((i=0;i<w_len;i++)) { ((i<p_len)) && b+='#' || b+='.' ; }
	printf '\r%79s\r[%s] %d%%%s ' '' "$b" "$c" "${u:+ ($p/$w $u)}" >&2
}

# Busy indicator
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

# scan global $g_x for non-printing bytes
# and replace them with a displayable rendition
expose_bytes () {
	local -i i n ;local t x=
	for ((i=0;i<${#g_x};i++)) {
		t="${g_x:i:1}"
		printf -v n '%u' "'$t"
		case $EXPOSE_BINARY in
			2)
				((n>0&&n<32||n>126)) && printf -v t '%b%02X%b' "$tinverse" $n "$tclear"
				((n)) || t=' '
				;;
			*)
				((n<32)) && { printf -v t '%02X' $((n+64)) ;printf -v t '%b%b%b' "$tinverse" "\x$t" "$tclear" ; }
				((n>126)) && printf -v t '%b.%b' "$tinverse" "$tclear"
				;;
		esac
		x+="$t"
	}
	g_x="$x"
}

parse_compat () {
	local a IFS=, c=${1:-$COMPAT}
	[[ ${compat[$c]} ]] 2>&- >&- || return 1
	a=(${compat[$c]})
	FNL="${a[0]}" FEL="${a[1]}" FAH="${a[2]}"
	printf -v ATTR "%b" "\x$FAH"
}

# List the files in the local directory without /bin/ls
# gross way to get file sizes but ok for tpdd-sized files
#
# Based on mapfile(). Fast(ish) but risk of eating all ram.
# mapfile() reads entire file into ram, then we walk the array
#lcmd_llm () {
#	local -i p b e ;local -a a ;local f
#	echo "__________Local Directory Listing__________"
#	for f in * ;do
#		IFS= mapfile -d '' a < "$f"
#		b=0 ;for ((p=0;p<${#a[*]};p++)) { e=${#a[p]} ;((b+=e+1)) } ;((e)) && ((b--))
#		[[ -d $f ]] && f+='/'
#		printf '%-32s %12d\n' "$f" $b
#	done
#}
#
# Based on read(). Even faster and no risk of eating all ram.
# read() only reads until the next null into ram at any given time.
# The reads are slightly slower than mapfile if we read the same 100%,
# but with reads we can abort mid way and never need to read more than
# 64k per file, because tpdd can't use them anyway.
lcmd_lls () {
	local -i b ;local f x s
	echo "________Local Directory Listing________"
	for f in * ;do
		b=0 x= 
		[[ -f $f ]] && while IFS= read -d '' -r -s x ;do ((b+=${#x}+1)) ;((b>PDD_MAX_FLEN)) && break ;done <"$f"
		((b+=${#x}))
		((b>PDD_MAX_FLEN)) && s='>64k' || s=$b
		[[ -d $f ]] && f+=/ s=
		printf '%-32s %6s\n' "$f" $s
	done
}

lcmd_ll () {
	local f
	echo "__________Local Directory Listing__________"
	for f in * ;do
		[[ -d $f ]] && f+='/'
		echo "$f"
	done
}

_init () {
	vecho 2 "${FUNCNAME[0]}($@)"
	$did_init && return
	did_init=true
	trap '_quit' EXIT
	((operation_mode==9)) || return
	fonzie_smack # ensure we can not be tpdd1 in fdc-mode, so we can send opr-mode or tpdd2 commands without locking up
	pdd2_version # determine which we are, tpdd1 in opr-mode, or tpdd2
	:
}

_quit () {
	((operation_mode)) || fcmd_mode 1
}

###############################################################################
# serial port operations

get_tpdd_port () {
	vecho 3 "${FUNCNAME[0]}($@)"
	local x=(/dev/${TPDD_TTY_PREFIX#/dev/}*)
	[[ ${x[0]} == /dev/${TPDD_TTY_PREFIX}\* ]] && x=(/dev/tty*)
	((${#x[*]}==1)) && { PORT=${x[0]} ;return ; }
	local PS3="Which serial port is the TPDD drive on? "
	select PORT in ${x[*]} ;do [[ -c $PORT ]] && break ;done
}

test_com () {
	[[ -t 3 ]]
}

set_stty () {
	vecho 3 "${FUNCNAME[0]}($@)"
	local b=${1:-${BAUD:-19200}} r= x= ;${RTSCTS:-true} || r='-' ;${XONOFF:-false} || x='-'
	stty ${stty_f} "${PORT}" $b ${STTY_FLAGS} ${r}crtscts ${x}ixon ${x}ixoff || return $?
	((v>1)) && stty ${stty_f} "${PORT}" -a ;:
}

open_com () {
	vecho 3 "${FUNCNAME[0]}($@)"
	test_com && return
	local -i e=
	exec 3<>"${PORT}"
	test_com && set_stty ;e=$?
	((e)) && err_msg+=("Failed to open serial port \"${PORT}\"")
	return $e
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
	local -i e
	mslog
	#test_com || { err_msg+=("$PORT not open") ;return 1 ; }
	local x=" $*"
	printf '%b' "${x// /\\x}" >&3 ;e=$?
	vecho 3 "SENT: $*"
	mslog
	return $e
}

# read $1 bytes from com port
# store each byte as a hex pair in global rhex[]
# tpdd_read #_of_bytes initial_ready_timeout 
#
# We need to read binary data from the drive. The special problem with handling
# binary data in shell is that it's not possible to store or retrieve a 0x00
# byte in a shell variable. All other byte values can be handled with the right care.
#
# But we can *detect* 0x00 bytes on input and store the knowledge of them,
# and we can emit them so we can re-create them on output later.
#
# For reference, this will read and store all bytes except 0x00
# LANG=C IFS= read -r -d ''
#
# To get the 0x00s what we do here is tell read() to treat 0x00 as the delimiter,
# then read one byte at a time for the expected number of bytes.
# (In the case of TPDD we always know the expected number of bytes, but we could
# also just read until end of data.) After each read, the variable holding the
# data will be empty if we read a 0x00 byte or if there was no data at all.
# For each byte that comes back empty, the return value from read() tells the
# difference between whether the drive sent a 0x00 byte, or didn't send anything.
#
# Thanks to Andrew Ayers in the M100 group on Facebook for help finding the key trick.
#
# return value from read() is the key to distiguish between null and timeout
#     0 = received a non-null byte, $x contains a byte
#     1 = received a null byte, $x is empty because read() ate the null as a delimiter
# 2-128 = read error, $x is empty because there was no data, not even a null
#  >128 = timed out, $x is empty because there was no data, not even a null
tpdd_read () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local -i i l=$1 ;local x ;rhex=() read_err=0
	((l<1)) && return 1
	tpdd_wait $2 $3 || return $?
	mslog
	#vecho 2 -n "$z: l=$l "
	for ((i=0;i<l;i++)) {
		((operation_mode==2)) && tpdd_wait
		x=
		IFS= read -d '' -r -t $read_timeout -n 1 -u 3 x ;read_err=$?
		((read_err==1)) && read_err=0
		((read_err)) && break
		printf -v rhex[i] '%02X' "'$x"
	}
	((read_err)) && err_msg+=("tty read err:$read_err")
	#vecho 2 "${rhex[*]}"
	vecho 3 "RCVD: ${rhex[*]}"
	mslog
	((${#rhex[*]}==l))
}

tpdd_read_unknown () {
	vecho 3 "${FUNCNAME[0]}($@)"
	local -i e= ;local x ;rhex=()
	tpdd_wait || return $?
	while : ;do
		((operation_mode==2)) && tpdd_wait
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
		[[ ${x: -1} == $e ]] && break
	done
}

# check if data is available without consuming any
tpdd_check () {
	vecho 3 "${FUNCNAME[0]}($@)"
	IFS= read -t 0 -u 3
}

# wait for data from the drive
# tpdd_wait timeout_ms busy_indication
# _sleep() but periodically check the drive for data-available,
# optionally show either a busy or progress indicator,
# return once the drive starts sending data
tpdd_wait () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	#test_com || { err_msg+=("$PORT not open") ;return 1 ; }
	local d=(: spin pbar) s
	local -i i=-1 n p=${TPDD_WAIT_POLL_INTERVAL_MS} t=${1:-$DEFAULT_TIMEOUT_MS} b=$2
	ms_to_s $p ;s=$_s
	((t<p)) && t=p ;((n=(t+50)/p))
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
	vecho 4 "$z: waited $((i*p)) of ${t} ms"
}

# stripped & hardcoded for speed
# risky because no timout, may loop forever
tpdd_wait_s () {
	until read -t 0 -u 3 ;do read -t 0.1 -u 4 ;done
}

# Drain output from the drive to get in sync with it's input vs output.
tpdd_drain () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local x= s=() ;local -i i
	while tpdd_check ;do
		x= ;IFS= read -d '' -r -t $read_timeout -n 1 -u 3 x
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
	local d=($*) s
	s=${d[-1]} ;unset d[-1]
	calc_cksum ${d[*]}
	vecho 2 "$z: given:$s calc:$cksum"
	((0x$s==0x$cksum))
}

# Check if a ret_std format response was ok (00) or error.
# This is used by all OPR commands, but some need special behavior.
# lcmd_load() needs to run ocmd_read() in a loop until it fails.
# In that case, we don't want the "error" to display on screen.
# If quiet=true, suppress normal output but still allow debugging
# by just increasing the verbose threshold. With quiet=true, you can
# still see errors with debug 2 or higher.
# Sometimes like in ocmd_read() we expect to hit an "error"
# and it's not really an error, just the end of a procedure.
# maybe todo: take argument for list of non-zero err codes
# to be treated as not-error?
ocmd_check_err () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local -i e _v=1 ;local x='OK'
	$quiet && _v=2
	vecho $_v "$z: ret_fmt=$ret_fmt ret_len=$ret_len ret_dat=(${ret_dat[*]}) read_err=\"$read_err\""
	((${#ret_dat[*]}==1)) || { err_msg+=('Corrupt Response') ; ret_dat=() ;return 1 ; }
	vecho $_v -n "$z: ${ret_dat[0]}:"
	((e=0x${ret_dat[0]}))
	((e)) && {
		x='UNKNOWN ERROR'
		((${#opr_msg[${ret_dat[0]}]})) && x="${opr_msg[${ret_dat[0]}]}"
		ret_err=${ret_dat[0]}
		$quiet || err_msg+=("$x")
	}
	vecho $_v "$x"
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
	_sleep 0.01
}

# ocmd_read_ret [timeout_ms [busy_indicator]]
# read an operation-mode return block from the drive
# parse it into the parts: format, length, data, checksum
# verify the checksum
# return the globals ret_fmt, ret_len, ret_dat[], ret_sum
ocmd_read_ret () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local -i t ;local l x ;ret_fmt= ret_len= ret_dat=() ret_sum=

	vecho 3 "$z: reading 2 bytes (fmt & len)"
	tpdd_read 2 $* || return $?
	((${#rhex[*]}==2)) || return 1
	[[ $ret_list =~ \|${rhex[0]}\| ]] || { err_msg+=("$z: INVALID RESPONSE") ;tpdd_drain ;return 1 ; }
	ret_fmt=${rhex[0]} ret_len=${rhex[1]}

	((l=0x$ret_len+1))
	vecho 3 "$z: reading $l bytes (data & checksum)"
	tpdd_read $l || return $?
	((${#rhex[*]}==l)) || return 3
	ret_sum=${rhex[-1]}
	unset rhex[-1]
	ret_dat=(${rhex[*]})

	vecho 2 "$z: fmt=$ret_fmt len=$ret_len dat=(${ret_dat[*]}) chk=$ret_sum"
	# compute the checksum and verify it matches the supplied checksum
	verify_checksum $ret_fmt $ret_len ${ret_dat[*]} $ret_sum || { err_msg+=("$z: CHECKSUM FAILED") ;return 1 ; }
}


###############################################################################
# "Operation Mode" drive functions
# wrappers for each "operation mode" function of the drive firmware

# directory entry
# ocmd_dirent filename attr action
# fmt = 00
# len = 1A
# filename = 24 bytes
# attr = 1 byte
# action = 00=set_name | 01=get_first | 02=get_next | 03=get_prev | 04=close
ocmd_dirent () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local -i e i ;local r=${opr_fmt[req_dirent]} x f="$1" a="${2:-00}" m=${3:-${dirent_cmd[get_first]}}
	drive_err= file_name= file_attr= file_len= free_sectors= tpdd_file_name= shex=()
	((operation_mode)) || fcmd_mode 1 || return 1
	# if tpdd2 bank 1, add 0x40 to opr_fmt[req]
	((bank)) && printf -v r '%02X' $((0x$r+0x40))

	# read the FCB table to get the true file lengths
	$FCB_FSIZE && ((m==${dirent_cmd[get_first]} || m==${dirent_cmd[set_name]})) && {
		printf   '...reading FCB table... '
		quiet=true read_fcb
		_sleep 0.03
		printf '\r                         \r'
	}

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
		*) err_msg+=("$z: Unexpected response from drive") ;return 1 ;;	# got no valid return
	esac
	((${#ret_dat[*]}==28)) || { err_msg+=("$z: Got ${#ret_dat[*]} bytes, expected 28") ;return 1 ; }

	# parse a dirent return format
	x="${ret_dat[*]:0:24}" ;printf -v file_name '%-24.24b' "\x${x// /\\x}"
	printf -v file_attr '%b' "\x${ret_dat[24]}"

	((file_len=0x${ret_dat[25]}*0xFF+0x${ret_dat[26]})) # file length from dirent()
	$FCB_FSIZE && { # file length from FCB
		for ((i=0;i<PDD_FCBS;i++)) {
			[[ ${fcb_fname[i]} == $file_name ]] && [[ ${fcb_attr[i]} == $file_attr ]] && { file_len=${fcb_size[i]} ;break ; }
		}
	}

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

# Get Drive Status
# request: 5A 5A 07 00 ##
# return : 07 01 ?? ##
ocmd_ready () {
	vecho 3 "${FUNCNAME[0]}($@)"
	((operation_mode)) || fcmd_mode 1 || return $?
	local r=${opr_fmt[req_status]}
	(($1)) && printf -v r '%02X' $((0x$r+0x40))
	ocmd_send_req $r || return $?
	ocmd_read_ret || return $?
	ocmd_check_err
}

# Operation-Mode Format Disk / also TPDD2 Format Disk
#request: 5A 5A 06 00 ##
#return : 12 01 ?? ##
# Operation-mode format is essentially "mkfs". It creates a filesystem disk.
ocmd_format () {
	vecho 3 "${FUNCNAME[0]}($@)"
	local -i w=$FORMAT1_WAIT_MS ;local m='Formatting Disk, TPDD1 filesystem'
	case $operation_mode in
		2) w=$FORMAT2_WAIT_MS m='Formatting Disk, TPDD2' ;;
		0) fcmd_mode 1 || return 1 ;;
	esac
	echo $m
	confirm || return $?
	ocmd_send_req ${opr_fmt[req_format]} || return $?
	ocmd_read_ret $w 2 || return $?
	ocmd_check_err
}

# switch to FDC mode
ocmd_fdc () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	case $operation_mode in
		2) perr "$z requires TPDD1" ;return 1 ;;
		0) [[ $1 == "force" ]] || return ;;
	esac
	ocmd_send_req ${opr_fmt[req_fdc]} || return $?
	_sleep 0.003
	tpdd_drain
	operation_mode=0
}

# Open File
# ocmd_open MM
# request: 5A 5A 01 01 MM ##
# return : 12 01 ?? ##
# MM = access mode: 01=write_new, 02=write_append, 03=read
ocmd_open () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode)) || fcmd_mode 1 || return 1
	local r=${opr_fmt[req_open]} m ;printf -v m '%02X' $1
	((bank)) && printf -v r '%02X' $((0x$r+0x40))
	ocmd_send_req $r $m || return $?	# open the file
	ocmd_read_ret || return $?
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
pdd2_rename () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==2)) || { err_msg+=("$z Requires TPDD2") ;return 1 ; }
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
# takes no arguments
# request: 5A 5A 03 00 ##
# return : 10 00-80 0-128bytes ##
ocmd_read () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode)) || fcmd_mode 1 || return 1
	local r=${opr_fmt[req_read]}
	((bank)) && printf -v r '%02X' $((0x$r+0x40))
	ocmd_send_req $r || return $?
	tpdd_wait
	_sleep 0.03
	ocmd_read_ret || return $?
	vecho 1 "$z: ret_fmt=$ret_fmt ret_len=$ret_len ret_dat=(${ret_dat[*]}) read_err=\"$read_err\""

	# check if the response was an error
	case "$ret_fmt" in
		"${opr_fmt[ret_std]}") quiet=true ocmd_check_err ;return $? ;;
		"${opr_fmt[ret_read]}") : ;;
		*) err_msg+=("$z: Unexpected Response") ;return 1 ;;
	esac

	# return true or not based on data or not
	# so we can do "while ocmd_read ;do ... ;done"
	((${#ret_dat[*]}))
}

# Write File Data
# ocmd_write hex_pairs...
# request: 5A 5A 04 01-80 1-128bytes ##
# return : 12 01 ?? ##
ocmd_write () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode)) || fcmd_mode 1 || return 1
	(($#)) || return 128
	local r=${opr_fmt[req_write]}
	((bank)) && printf -v r '%02X' $((0x$r+0x40))
	ocmd_send_req $r $* || return $?
	ocmd_read_ret || return $?
	ocmd_check_err
}

###############################################################################
#                                 FDC MODE                                    #
###############################################################################
#
# fdc-mode transaction format reference
#
# send: C [ ] [P[,P]] CR
#
# C = command letter, ascii letter
# [ ] = optional space between command letter and first parameter
# P = 0, 1, or 2 parameters, integer decimal value in ascii, comma-seperated
# CR = carriage return
#
# recv: 8 bytes as 4 ascii hex pairs representing 3 integer values
#
#  1st pair is a uint_8 status/error code   ex: 0x30 0x30 = "00" = 0x00 = 0 = success
#  2nd pair is a uint_8 result/answer data  ex: 0x32 0x44 = "2C" = 0x2C = 45
#  3rd and 4th pairs are a single big-endian uint_16 length/size or offset/address
#    ex: 0x30 0x30 0x34 ox30 = "0040" = 0x0040 = 64
#
#  The meaning of the data and length fields depends on the command.
#  For example for the search_id command,
#    dat=45 means match found at physical sector number 45
#    len=64 means the disk is formatted with 64-byte logical sector size
#
# Some fdc commands have more send-and-receive after that.
# Receive the first response, if the status is not error, then:
#
# send: data (such as for a sector write or ID write)
# recv: another standard 8-byte response as above
# or
# send: single carriage-return (telling the drive you are ready to receive)
# recv: data (such as from a sector read or ID read)

###############################################################################
# "FDC Mode" support functions

# Read a standard FDC-mode 4-pair result
# essentially the FDC-mode version of ocmd_read_ret()
# $* = timout & busy indication forwarded to tpdd_read()
fcmd_read_ret () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==0)) || ocmd_fdc || return 1
	local -i i ;local x ;fdc_err= fdc_dat= fdc_len=

	# read 8 bytes & reconstitute the hex pairs back to the original bytes
	tpdd_read 8 $* || return $?
	x="${rhex[*]}" ;printf -v x '%b' "\x${x// /\\x}"
	vecho 2 "$z: $x"
	#tpdd_drain

	# decode the 8 bytes as
	fdc_err=0x${x:0:2} # hex pair    uint_8  error/status code
	fdc_dat=0x${x:2:2} # hex pair    uint_8  result/answer data
	fdc_len=0x${x:4:4} # 2 hex pairs uint_16 length or offset

	# look up the status/error message for fdc_err
	x= ;[[ ${fdc_msg[fdc_err]} ]] && x="${fdc_msg[fdc_err]}"
	((fdc_err)) && err_msg+=("${x:-ERROR:${fdc_err}}")

	vecho 2 "$z: err:$fdc_err=\"${fdc_msg[fdc_err]}\" dat:$fdc_dat len:$fdc_len"
}

###############################################################################
# "FDC Mode" drive functions
# wrappers for each "FDC mode" function of the drive firmware

# Select operation mode
# fcmd_mode <0|1>
# 0=fdc 1=operation
fcmd_mode () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode)) && return
	case $1 in 0|1) : ;; *) return ;; esac
	str_to_shex "${fdc_cmd[mode]}$1"
	tpdd_write ${shex[*]} 0D || return $?
	operation_mode=$1
	tpdd_drain
}

# Report not-ready conditions
# bit flags for some not-ready conditions
fcmd_ready () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==0)) || ocmd_fdc || return $?
	str_to_shex "${fdc_cmd[condition]}"
	tpdd_write ${shex[*]} 0D || return $?
	fcmd_read_ret || return $?
	((fdc_err)) && return $fdc_err
	$quiet && { ((fdc_dat&0x20)) && err_msg+=('[WP]') || err_msg+=('    ') ;return 0; } # hack for lcmd_ls()
	((fdc_dat&0x40)) && fcb_fname=() fcb_attr=() fcb_size=() fcb_resv=() fcb_head=() fcb_tail=()
	local -i b ;((fdc_dat)) && { # bit flags
		for b in ${!fdc_cond[@]} ;do ((fdc_dat&b)) && echo "${fdc_cond[b]}" ;done ;:
	} || echo "${fdc_cond[fdc_dat]}"
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
	local c=format x= ;local -i w=$FORMAT1_WAIT_MS
	$WITH_VERIFY || c+=_nv w=$FORMAT1NV_WAIT_MS x=", no verify"
	typeset -i s=${1:-3}
	echo "Formatting Disk, TPDD1 \"FDC\" mode, ${lsl[s]:-\"\"}-Byte Logical Sectors$x"
	confirm || return $?
	str_to_shex ${fdc_cmd[$c]}$s
	tpdd_write ${shex[*]} 0D || return $?
	fcmd_read_ret $w 2 || return $?
	((fdc_err)) && err_msg+=(", Sector:$fdc_dat")
	return $fdc_err
}

# Sector ID section - See the software manual page 11
# There is one ID section per physical sector.
# Ignore the leading 4 leading bytes and 2 trailing crc bytes, since they don't
# exist outside of the drive. A client can neither read nor write them.
#
# The LSC byte is readable, but not individually or arbitrarily writable.
# The only control a client has over the LSC byte is the LSC parameter to
# FDC_format, which writes the specified size code to all physical sectors.
# 
# Other than that, only the 12 byte reserve section is readable/writable by the user.
# The read_id/write_id/search_id functions operate only on that field.
#
# The data can be anything.
#
# On a normal filesystem disk (rather than a raw data disk like the Sardine
# dictionary), the drives built-in filesystem uses this field for one byte:
#   00 = current sector is not used by a file
#   ## = sector number of next sector in current file
#   FF = current sector is the last sector in current file

# Search for sector ID matching $*
# si <up to 12 hex pairs of ID data>
#
# github.com/bkw777/dl2/blob/master/ref/search_id_section.txt
# Drive requires exactly 12 bytes of data. This right-pads with 0x00
# and truncates to 12 bytes as necessary. So you may ex:
# "si 04" and it will search for "04 00 00 00 00 00 00 00 00 00 00 00"
fcmd_search_id () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==0)) || ocmd_fdc || return 1
	str_to_shex "${fdc_cmd[search_id]}"
	tpdd_write ${shex[*]} 0D || return $?
	fcmd_read_ret || { err_msg+=("err:$? dat:${fdc_dat}") ;return $? ; }
	((fdc_err)) && { err_msg+=("err:$fdc_err dat:${fdc_dat}") ;return $fdc_err ; }
	local a=($*) ;while ((${#a[*]}<SECTOR_ID_LEN)) do a+=("00") ;done
	tpdd_write ${a[*]:0:SECTOR_ID_LEN} || return $?
	fcmd_read_ret $SEARCHID_WAIT_MS || { err_msg+=("err:$? dat:${fdc_dat}") ;return $? ; }
	# $fdc_err = success/fail status code
	# $fdc_dat = physical sector number 0-79 if found, 255 if not found
	# $fdc_len = logical sector size of the indicated physical sector
	((fdc_err==60)) && return $fdc_err
	((fdc_err)) && { err_msg+=("err:$fdc_err dat:${fdc_dat} len:${fdc_len}") ;return $fdc_err ; }
	$quiet || echo "ID found at sector $fdc_dat"
}

# Read sector ID section
# ri [P] [P...]
# P : zero or more physical sector numbers 0-79 as plain ascii decimal integer
# default is sector 0 to mimic the drive's own behavior
# "all" shows all sector ID's
fcmd_read_id () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==0)) || ocmd_fdc || return 1
	case "$1" in '') set 0 ;; all) set {0..79} ;; esac
	local -i i
	for i in $* ;do
		str_to_shex "${fdc_cmd[read_id]}$i"
		tpdd_write ${shex[*]} 0D || return $?
		fcmd_read_ret || { err_msg+=("err:$? dat:${fdc_dat}") ;return $? ; }
		((fdc_err)) && { err_msg+=("err:$fdc_err dat:${fdc_dat}") ;return $fdc_err ; }
		#_sleep 0.01
		tpdd_write 0D || return $?
		#while _sleep 0.1 ;do tpdd_check && break ;done # sleep at least once
		tpdd_read $SECTOR_ID_LEN || return $?
		((${#rhex[*]}<SECTOR_ID_LEN)) && { err_msg+=("Got ${#rhex[*]} of $SECTOR_ID_LEN bytes") ; return 1 ; }
		$quiet || printf "I %02u %04u : %s\n" "$i" "$fdc_len" "${rhex[*]}"
	done
}

# Read a logical sector
# A logical sector is a 64 to 1280 bytes long chunk of a physical sector
# fcmd_read_logical physical# logical#
# physical sector number 0-79 as plain ascii decimal integer
# logical sector number 1-20 as plain ascii decimal integer
# Valid values for L depends on the logical size code for the given physical
# sector. If LSC is 0 (64-byte logical sectors), then L may be 1 to 20.
# If LSC is 6 (1280-byte logical sectors), then the only valid L is 1.
fcmd_read_logical () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==0)) || ocmd_fdc || return 1
	local -i ps=$1 ls=${2:-1} || return $? ;local x
	str_to_shex "${fdc_cmd[read_sector]}$ps,$ls"
	tpdd_write ${shex[*]} 0D || return $?
	fcmd_read_ret || { err_msg+=("err:$? dat:${fdc_dat}") ;return $? ; }
	((fdc_err)) && { err_msg+=("err:$fdc_err dat:${fdc_dat}") ;return $fdc_err ; }
	((fdc_dat==ps)) || { err_msg+=("Unexpected Physical Sector \"$ps\" Returned") ;return 1 ; }
	((fdc_len>SECTOR_DATA_LEN)) && { err_msg+=("$z: read_sector() returned length value \"$fdc_len\" which is greater than a physical sector ($SECTOR_DATA_LEN)." "Disk is corrupt or trying to read a TPDD2 disk in a TPDD1 drive.") ;return 1 ; }
	tpdd_write 0D || return $?
	# tpdd_check() will say there is data available immediately, but if you
	# read too soon the data will be corrupt or incomplete or you'll hang the drive.
	# Take 2/3 of expected bytes (64 to 1280), and sleep that many ms.
	# The tpdd_wait() in tpdd_read() is not enough.
	ms_to_s $(((fdc_len/10)*6)) ;_sleep $_s
	tpdd_read $fdc_len || return $?
	((${#rhex[*]}<fdc_len)) && { err_msg+=("Got ${#rhex[*]} of $fdc_len bytes") ; return 1 ; }
	$quiet || printf "L %02u %02u %04u : %s\n" "$ps" "$ls" "$fdc_len" "${rhex[*]}"
}

# read all logical sectors in a physical sector
# pdd1_read_sector sector# (0-79)
pdd1_read_sector () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local -i p=$1 l t || return $? ;local u= h=()

	fcmd_read_logical $p 1 || return $?
	h=(${rhex[*]})
	((t=SECTOR_DATA_LEN/fdc_len))
	for ((l=2;l<=t;l++)) {
		fcmd_read_logical $p $l || return $?
		h+=(${rhex[*]})
	}
	rhex=(${h[*]})
}

# Write a sector ID section
# wi P hex_pairs...
# P : physical sector number 0-79 as plain ascii decimal integer
# hex-pairs... : 0 to 12 hex pairs of sector ID data
# Must always send exactly 12 bytes data,
# so this fills missing bytes with 00 and strips extras.
# so you may ex: "wi 79 cc" and it will write "CC 00 00 00 00 00 00 00 00 00 00 00" to sector 79
fcmd_write_id () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==0)) || ocmd_fdc || return 1
	local -i p=$((10#$1)) ;shift
	local c=write_id ;$WITH_VERIFY || c+=_nv
	str_to_shex "${fdc_cmd[$c]}$p"
	tpdd_write ${shex[*]} 0D || return $?
	fcmd_read_ret || { err_msg+=("err:$? dat:${fdc_dat}") ;return $? ; }
	((fdc_err)) && { err_msg+=("err:$fdc_err dat:${fdc_dat}") ;return $fdc_err ; }
	local a=($*) ;while ((${#a[*]}<SECTOR_ID_LEN)) do a+=("00") ;done
	tpdd_write ${a[*]:0:SECTOR_ID_LEN} || return $?
	fcmd_read_ret || { err_msg+=("err:$? dat:${fdc_dat}") ;return $? ; }
	((fdc_err)) && { err_msg+=("err:$fdc_err dat:${fdc_dat}") ;return $fdc_err ; }
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
	local c=write_sector ;$WITH_VERIFY || c+=_nv
	str_to_shex "${fdc_cmd[$c]}$ps,$ls"
	tpdd_write ${shex[*]} 0D || return $?
	fcmd_read_ret || { err_msg+=("err:$? dat:${fdc_dat}") ;return $? ; }
	((fdc_err)) && { err_msg+=("err:$fdc_err dat:${fdc_dat}") ;return $fdc_err ; }
	tpdd_write $* || return $?
	fcmd_read_ret || { err_msg+=("err:$? dat:${fdc_dat}") ;return $? ; }
	((fdc_err)) && { err_msg+=("err:$fdc_err dat:${fdc_dat}") ;return $fdc_err ; }
	:
}

# read all physical sectors on the disk
# if no filename given, display to screen
# $1 = [filename[.pdd1]]
pdd1_dump_disk () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local f=$1 x= ;local -i s l n

	((${#f})) && {
		[[ ${f##*.} == ${PDD1_IMG_EXT} ]] || f+=".${PDD1_IMG_EXT}"
		echo "Dumping Disk to File: \"$f\""
		[[ -e $f ]] && { confirm 'File Exists' || return $? ; }
		quiet=true
	}

	for ((s=0;s<PDD1_SECTORS;s++)) {

		# ID
		((${#f})) && pbar $((s+1)) $PDD1_SECTORS "L:0/$n"
		fcmd_read_id $s || return $?
		((fdc_len)) || return 1
		((n=SECTOR_DATA_LEN/fdc_len))
		((${#f})) && x+=" ${lsc[fdc_len]} ${rhex[*]}"

		# DATA
		for ((l=1;l<=n;l++)) {
			((${#f})) && pbar $((s+1)) $PDD1_SECTORS "L:$l/$n"
			fcmd_read_logical $s $l || return $?
			((${#f})) && x+=" ${rhex[*]}"
		}

	}

	((${#f})) && {
		printf '%b' "${x//\ /\\x}" >$f
		pbar $s $PDD1_SECTORS
		echo
	}
}

# Read a .pdd1 disk image file and write the contents back to a disk
# pdd1_restore_disk filename
# *.pdd1 disk image file format, 80 records, no delimiters:
# 1    byte  : logical sector size code 00-06
# 12   bytes : ID
# 1280 bytes : DATA
pdd1_restore_disk () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local f=$1 x b ;local -i p s l n lc rl
	((rl=1+SECTOR_ID_LEN+SECTOR_DATA_LEN)) # img file record length
	[[ -e $f ]] || [[ ${f##*.} == ${PDD1_IMG_EXT} ]] || f+=".${PDD1_IMG_EXT}"
	echo "Restoring Disk from File: \"$f\""

	# Read the disk image file file into fhex[]
	echo "Loading \"$f\""
	file_to_fhex "$f" 0 || return $?

	# Get the logical sector size code from the file
	lc=0x${fhex[0]} # logical size code from the 1st record
	ll=${lsl[lc]} # length in bytes for that size code

	# Sanity check the logical size codes in the disk image.
	#
	# A real drive can't create a disk with mixed LSCs (different LSCs
	# on different sectors) except for one specific form.
	#
	# Scan the LSC of every sector and only proceed if one of the following:
	#
	# * Raw data disk: All sectors have the same LSC.
	# or
	# * Filesystem disk: All sectors have either LSC 0 or 1,
	#   but any sector with data has LSC 0.
	#
	# Anything else is something we have no way to reproduce
	# and is probably just a corrupt / invalid image.
	#
	# We can't(*) even truely reproduce the latter, but we can produce
	# something functionally identical if not literally identical.
	#
	# OPR-format (aka filesystem) writes LSC 1 to all untouched sectors.
	# Then later any time a sector is touched by a file it is changed to LSC 0,
	# and never changed back even when deleting the file. Sector 0 of an
	# OPR-format disk always has data, including a fresh format, because the
	# SMT gets a byte of data in sector 0, so sector 0 just always has LSC 0.
	#
	# All sectors with any data always have LSC 0, and so a new duplicate
	# disk formatted with all LSC 0 is functionally the same.
	#
	# (*) We *could*, just the long way, by doing OPR-format, then save &
	# delete files to touch the sectors that need to get changed from 1 to 0.
	#
	${PDD1_RD_CHECK_MIXED_LSC} && for ((s=0;s<PDD1_SECTORS;s++)) {
		((p=rl*s))

		# This matches both the raw data disk case where LSC might be any 0-6,
		# as long as all sectors match each other,
		# and and also matches the LSC 0 sectors on a filesystem disk,
		# because sector 0 of a filesystem disk always has LSC 0.
		((${fhex[p]}==lc)) && continue

		# This matches the rest of the filesystem disk case,
		#   If current sector has LSC 0, then it was already OK'd above.
		#   If current sector has LSC 1, and no data in ID or DATA,
		#   and sector 0 has LSC 0, then that's OK too.
		((lc==0)) && ((0x${fhex[p]}==1)) && {
			x=${fhex[*]:p+1:rl-1} ;x=${x//[ 0]/}
			((${#x})) || continue
		}

		# Anything else is a problem.
		err_msg+=('Mixed Logical Sector Sizes')
		return 1
	}

	# FDC-format the disk with logical size code from sector 0
	fcmd_format $lc || return $?

	# Write the sectors
	((n=SECTOR_DATA_LEN/ll)) # number of logical sectors per physical
	p=0
	echo "Writing Disk"
	for ((s=0;s<PDD1_SECTORS;s++)) {

		# LSC (advance one byte to skip over it)
		((p++))

		# ID
		pbar $((s+1)) $PDD1_SECTORS "ID"
		b=${fhex[*]:p:SECTOR_ID_LEN} ;x=$b ;x=${x//[ 0]/}
		((${#x})) && { fcmd_write_id $s $b || return $? ; }
		((p+=SECTOR_ID_LEN))

		# DATA
		for ((l=1;l<=n;l++)) {
			pbar $((s+1)) $PDD1_SECTORS "LS:$l/$n"
			b=${fhex[*]:p:ll} ;x=$b ;x=${x//[ 0]/}
			((${#x})) && { fcmd_write_logical $s $l $b || return $? ; }
			((p+=ll))
		}
	}
	pbar $s $PDD1_SECTORS
	echo
}

# Send a machine program to the drive
# which reads the 4k rom from 0xF000 to 0xFFFF
# and outputs to the serial port in hex dump format.
# The 6301 machine code here comes from Darren Clark
# https://bitchin100.com/wiki/index.php?title=TPDD_Design_Notes
lcmd_pdd1_dump_rom () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local -i i n= b=${BAUD} c ;local f=$1
	local -a a=(
		S10E8515CEF000C608860DBD854F8621
		S11385200ABD854F3C328100271EBD855A32BD8568
		S11385305A863ABD854FA600BD855A8620BD854F13
		S1138540085AC10027D220EE8658BD854F20FE3739
		S1138550D611C42027FA971333393644444444BD12
		S1138560856532840F810A2B028B078B30BD854FC2
		S104857039CD
		S901FE
	)

	echo
	echo "ROM DUMP for TPDD1 / FB-100"
	echo "https://github.com/BiggRanger/Tandy_PDD"
	echo
	echo "This process requires the drive to be configured to receive S-records."
	echo "Do the following now before proceeding:"
	echo
	echo "1 - Turn the drive power OFF."
	echo "2 - Set the dip switches to:"
	echo "    1    2    3    4"
	((b<19200)) && echo "    ON   ON   ON   ON" || echo "    OFF  ON   ON   ON"
	echo "3 - Turn the drive power ON."
	echo
	echo "If the dip switches were already set from a previous attempt,"
	echo "still cycle the power switch once right now."
	echo "If the low battery light is flashing, cycle the power."
	echo
	ask "Ready to proceed (y/N)? " || return

	[[ $f ]] && {
		echo
		echo "Saving to file: $f"
		[[ -e $f ]] && { confirm 'File Exists' || return $? ; }
		>$f
	}

	((b<9600)) && n=9600;
	((b>19200)) && n=19200;
	((n)) && {
		echo "Switching serial port to $n baud."
		lcmd_com_speed $n
		echo
	}

	# send the S-records without \r or \n
	echo "Sending S-records to the drive cpu..."
	echo
	n=${#a[*]}
	for ((i=0;i<n;i++)) {
		echo "${a[i]}"
		printf '%s' "${a[i]}" >&3
		_sleep 0.030 # really only needed at 19200
	}
	echo

	# The uploaded program generates an ascii hex dump in this format
	#   F000:0F 8E 87 FF 86 FC 97 00\r\n
	#   F008:86 34 97 02 86 FF 97 04\r\n
	#   ...
	#   FFF8:F0 00 F0 00 F0 00 F0 00\r\n

	# Read the formatted ascii hex dump from the drive
	# extract the hex pairs and write the binary to a file
	tpdd_wait || return $?
	n=0
	while read -r -t 1 -u 3 x ;do
		IFS+=$'\r' a=(${x##*:}) IFS="$ifs" # strip leading "####:" and trailing "\r\n"
		i=${#a[*]}
		((i)) || continue # skip empty line
		printf '%s\n' "$x"
		[[ $f ]] || continue
		x="${a[*]}"
		printf '%b' "\x${x// /\\x}" >>$f
		((n+=i))
	done
	echo

	((BAUD==b)) || {
		echo "Restoring serial port to $b baud."
		lcmd_com_speed $b
		echo
	}

	[[ $f ]] && echo -e "Wrote $n bytes to $f\n"

	echo "Return the drive to normal configuration."
	echo "1 - Turn the drive power OFF."
	echo "2 - Set the dip switches to:"
	           echo "    1    2    3    4"
	case $b in
		76800) echo "    ON   ON   OFF  OFF" ;;
		38400) echo "    OFF  OFF  ON   OFF" ;;
		19200) echo "    OFF  OFF  OFF  OFF" ;;
		9600)  echo "    ON   OFF  OFF  OFF" ;;
		4800)  echo "    OFF  ON   OFF  OFF" ;;
		2400)  echo "    ON   OFF  OFF  OFF" ;;
		1200)  echo "    ON   OFF  OFF  ON" ;;
		600)   echo "    OFF  ON   OFF  ON" ;;
		300)   echo "    ON   ON   OFF  ON" ;;
		150)   echo "    OFF  OFF  ON   ON" ;;
		*)     echo "   -unrecognized baud \"$b\""- ;;
	esac

	echo "3 - Turn the drive power ON."
	echo
	did_init=false
	operation_mode=9
}

###############################################################################
# TPDD2

# Get system version report from the drive.
# Some versions of TS-DOS use this to detect TPDD2 vs TPDD1.
# request: 5A 5A 23 00 DC
# return : 14 0F 41 10 01 00 50 05 00 02 00 28 00 E1 00 00 00 2A
pdd2_version () {
	vecho 3 "${FUNCNAME[0]}($@)"
	# This is a TPDD2-only command, but in this case we do NOT want do the
	# usual sanity check, because trying this command is itself one of the
	# ways to figure out if the drive is tpdd1 or tpdd2 in the first place.
	#
	# Clear err_msg because read() err is expected for every TPDD1.
	# Set a deliberately short timeout because TPDD2 responds quickly,
	# and TPDD1 will never respond and always hang for the full timeout.
	ret_dat=()
	ocmd_send_req ${opr_fmt[req_pdd2_version]} && ocmd_read_ret $PDD2_VERSION_WAIT_MS ;err_msg=()

	local -i mc=0x${ret_dat[11]:-00}

	((v)) && {
		local ms=${model_codes[mc]}
		[[ ${ms} ]] || ms="Unknown Model Code \"$mc\""
		printf '\n'
		printf    'System Version\n'
		printf -- '---------------------------------------------------\n'
		printf    'System Version:    %u\n' 0x${ret_dat[0]:-00}${ret_dat[1]:-00}
		printf    'Sides:             %u\n' 0x${ret_dat[2]:-00}
		printf    'Tracks:            %u\n' 0x${ret_dat[3]:-00}${ret_dat[4]:-00}
		printf    'Sector Length:     %u\n' 0x${ret_dat[5]:-00}${ret_dat[6]:-00}
		printf    'Sectors per Track: %u\n' 0x${ret_dat[7]:-00}
		printf    'Directory Entries: %u\n' 0x${ret_dat[8]:-00}${ret_dat[9]:-00}
		printf    'Max Open Files:    %u\n' $((0x${ret_dat[10]:-00}+1))
		printf    'Model:             %s\n' "$ms"
		printf    'reserved 0:        %u\n' 0x${ret_dat[12]:-00}
		printf    'reserved 1:        %u\n' 0x${ret_dat[13]:-00}
		printf    'reserved 2:        %u\n' 0x${ret_dat[14]:-00}
		printf '\n'
	}

	((mc==225)) && {
		vecho 1 'Detected TPDD2'
		set_pdd2
		return 0
	} || {
		vecho 1 'Detected TPDD1'
		set_pdd1
		return 1
	}
}

# Get system info report from the drive.
# request: 5A 5A 33 00 ck
# return: 38 06 80 13 05 00 10 E1 ck
pdd2_sysinfo () {
	vecho 3 "${FUNCNAME[0]}($@)"
	# This is a TPDD2-only command, but in this case we do NOT want do the
	# usual sanity check, because trying this command is itself one of the
	# ways to figure out if the drive is tpdd1 or tpdd2 in the first place.
	#
	# Clear err_msg because read() err is expected for every TPDD1.
	# Set a deliberately short timeout because TPDD2 responds quickly,
	# and TPDD1 will never respond and always hang for the full timeout.
	ret_dat=()
	ocmd_send_req ${opr_fmt[req_pdd2_sysinfo]} && ocmd_read_ret $PDD2_SYSINFO_WAIT_MS ;err_msg=()

	local -i mc=0x${ret_dat[5]:-00}

	((v)) && {
		local -i cc=0x${ret_dat[4]:-00}
		local cs=${cpu_codes[cc]}
		[[ ${cs} ]] || cs="Unknown CPU Code \"$cc\""

		local ms=${model_codes[mc]}
		[[ ${ms} ]] || ms="Unknown Model Code \"$mc\""

		printf '\n'
		printf    'System Information\n'
		printf -- '---------------------------------------------------\n'
		printf    'Sector Cache Start:  %u\n' 0x${ret_dat[0]:-00}${ret_dat[1]:-00}
		printf    'Sector Cache Length: %u\n' 0x${ret_dat[2]:-00}${ret_dat[3]:-00}
		printf    'CPU:                 %s\n' "$cs"
		printf    'Model:               %s\n' "$ms"
		printf '\n'
	}

	((mc==225)) && {
		vecho 1 'Detected TPDD2'
		set_pdd2
		return 0
	} || {
		vecho 1 'Detected TPDD1'
		set_pdd1
		return 1
	}
}

# TPDD2 Get Drive Condition
# request: 5A 5A 0C 00 ##
# return : 15 01 ?? ##
pdd2_condition () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==2)) || { perr "Requires TPDD2" ; return 1; }
	local -i i b
	ocmd_send_req ${opr_fmt[req_pdd2_condition]} || return $?
	ocmd_read_ret || return $?
	i=0x${ret_dat[0]}
	$quiet && { err_msg=() ;((i&0x02)) && err_msg+=('[WP]') || err_msg+=('    ') ;return 0; }
	((1&0x08)) && fcb_fname=() fcb_attr=() fcb_size=() fcb_resv=() fcb_head=() fcb_tail=()
	((i)) && { # bit flags
		for b in ${!pdd2_cond[@]} ;do ((i&b)) && echo "${pdd2_cond[b]}" ;done ;:
	} || echo "${pdd2_cond[i]}"
}

# TPDD2 copy sector data between disk and cache
# pdd2_cache track sector action
# pdd2_cache 0-79 0-1 0-2
# action: 0=load (cache<disk) 1=commit (cache>disk) 2=commit+verify
pdd2_cache () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==2)) || { perr "Requires TPDD2" ; return 1; }
	local x ;local -i t=$1 s=$2 a=$3 e

	# 5-byte request data
	# 00-02 action 0=load 1=commit 2=commit+verify
	# 00    track number msb (always 00)
	# 00-4F track number lsb
	# 00    side (always 00)
	# 00-01 sector
	printf -v x '%02X 00 %02X 00 %02X' $a $t $s

	ocmd_send_req ${opr_fmt[req_pdd2_cache]} $x || return $?
	ocmd_read_ret ${PDD2_CACHE_WAIT_MS} || return $?
	ocmd_check_err ;e=$?
	(($3==0)) && ((e==0x50)) && e= err_msg=() # if not writing, don't treat write-protected disk as error
	return $e
}

# TPDD2 read from memory
# pdd2_mem_read mode address length
#   mode: 0=sector_cache  1=cpu_memory
#   addr: 0-65535
#   len:  1-252
# service manual says len should be 1-125, but can actually go up to 252
# (255 minus 3 bytes for fmt, len, chk), but large reads occasionally fail
# reading 252 fails as much as 1/4 times, reading 160 seems to be safe
pdd2_mem_read () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==2)) || { perr "Requires TPDD2" ; return 1; }
	local x

	# 4-byte request data
	# 00      mode  0=sector_cache 1=cpu_memory
	# 00-04   address MSB (sector_cache 0000-04C0, cpu_mem 0000-FFFF)
	# 00-FF   address LSB
	# 00-FC   length
	printf -v x '%02X %02X %02X %02X' $1 $((($2>>8)&0xFF)) $(($2&0xFF)) $3
	ocmd_send_req ${opr_fmt[req_pdd2_mem_read]} $x || return $?
	ocmd_read_ret || return $?

	# TODO retry failed read once or twice, since a large read
	# can fail sometimes yet work most times.
    
	# TODO mem_write can return either a 0x39 block or a 0x38 block
	# ocmd_check_err doesn't recognize that yet
	#ocmd_check_err || return $? # needs to be taught about ret_pdd2_mem_write

	# returned data:
	# [0]     mode
	# [1]     address MSB
	# [2]     address LSB
	# [3]+    data
	((${#ret_dat[*]}==3+$3)) || { err_msg+=("$z: expected $((3+$3)) bytes, got ${#ret_dat[*]}") ;return 1 ; }
	$quiet || printf 'M:%u O:%05u %s\n' "0x${ret_dat[0]}" "0x${ret_dat[1]}${ret_dat[2]}" "${ret_dat[*]:3}"
}

# TPDD2 write to memory
# pdd2_mem_write mode address data...
#   mode: 0=sector_cache 1=cpu_memory
#   address: mode0 0-1280, mode1 0-65535
#   data: 1-125 hex pairs
pdd2_mem_write () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==2)) || { perr "Requires TPDD2" ; return 1; }
	printf -v x '%02X %02X %02X' $1 $((($2>>8)&0xFF)) $(($2&0xFF)) ;shift 2
	ocmd_send_req ${opr_fmt[req_pdd2_mem_write]} $x $* || return $?
	ocmd_read_ret || return $?
	ocmd_check_err
}

# Reset Drive Status
# We don't really know what these do, other than that they write a
# byte to a few memory addresses. They are copied from an example
# flowchart near the end of the service manual labelled
# "reset drive status" without actually explaining it.
pdd2_reset_drive_status () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==2)) || { perr "Requires TPDD2" ; return 1; }
	# write 0xFF to cpu memory address 0x0084 - why? doont knoow!
	pdd2_mem_write $MEM_CPU 0x0084 FF || return $?
	# write 0x0F to cpu memory address 0x0096 - why? doont knoow!
	pdd2_mem_write $MEM_CPU 0x0096 0F || return $?
	# write 0x0F to cpu memory address 0x0094 - why? doont knoow!
	pdd2_mem_write $MEM_CPU 0x0094 0F || return $?
}

# write the sector cach to disk
pdd2_commit_cache () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==2)) || { perr "Requires TPDD2" ; return 1; }
	# We don't really know what these do, other than that they write a byte
	# to a couple of memory addresses. They are copied from the backup util.
	# They are similar to reset_drive_status but not exactly.
	pdd2_mem_write $MEM_CPU 0x0083 00 || return $?  # 01 00 83 00
	pdd2_mem_write $MEM_CPU 0x0096 00 || return $?  # 01 00 96 00

	# write the cache to disk
	pdd2_cache $1 $2 $CACHE_COMMIT_VERIFY || return $?
}

# pdd2_read_id [T,S|all] [T,S ...]
# T = track  0-79
# S = sector 0-1
# or
# pdd2_read_id [LS] [LS..]
# LS = linear sector 0-159
# no args reads 0,0 , "all" reads all sectors on the disk
pdd2_read_id () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==2)) || { perr "Requires TPDD2" ; return 1; }
	case "$1" in '') set 0,0 ;; all) set {0..79},{0,1} ;; esac
	local a ;local -i t s
	for a in $* ;do
		[[ $a =~ , ]] && t=${a%%,*} s=${a##*,} || t=$((a/2)) s=$((a-(a/2)*2))
		pdd2_cache $t $s $CACHE_LOAD || return $?
		quiet=true pdd2_mem_read $MEM_CPU $PDD2_ID_ADDR $((SECTOR_ID_LEN+1)) || return $?
		$quiet || printf 'T:%02u S:%u : %s - %s\n' $t $s "${ret_dat[*]:3:SECTOR_ID_LEN}" "${ret_dat[*]:3+SECTOR_ID_LEN}"
	done
}

# Read one full 1280-byte sector.
# pdd2_read_sector T S
# T = track 0-79
# S = sector 0-1
pdd2_read_sector () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==2)) || { perr "Requires TPDD2" ; return 1; }
	local -i i t=$1 s=$2 c ;local h=()
	pdd2_cache $t $s $CACHE_LOAD || return $?
	$quiet || echo "Track $t, Sector $s"
	for ((c=0;c<PDD2_CHUNKS_R;c++)) {
		quiet=true pdd2_mem_read $MEM_CACHE $((PDD2_MEM_RD_LEN*c)) $PDD2_MEM_RD_LEN || return $?
		$quiet || printf '%05u : %s\n' "0x${ret_dat[1]}${ret_dat[2]}" "${ret_dat[*]:3}"
		h+=( ${ret_dat[*]:3} )
	}
	rhex=(${h[*]})
}

# TPDD2 dump disk
# pdd2_dump_disk filename[.pdd2]
pdd2_dump_disk () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==2)) || { perr "Requires TPDD2" ; return 1; }
	local f=$1 x ;local -i t s i= c

	((${#f})) && {
		[[ ${f##*.} == ${PDD2_IMG_EXT} ]] || f+=".${PDD2_IMG_EXT}"
		echo "Dumping Disk to File: \"$f\""
		[[ -e $f ]] && { confirm 'File Exists' || return $? ; }
		quiet=true
	}

	for ((t=0;t<PDD2_TRACKS;t++)) { # tracks
		for ((s=0;s<PDD2_SECTORS;s++)) { # sectors
			((${#f})) && pbar $((i++)) $PDD2_SECTORS_D "T:$t S:$s C:-"

			# load sector from media to cache
			pdd2_cache $t $s $CACHE_LOAD || return $?

			# ID + mystery 13th byte
			pdd2_mem_read $MEM_CPU $PDD2_ID_ADDR $((SECTOR_ID_LEN+1)) || return $?
			((${#f})) && x+=" ${ret_dat[*]:3}"

			# DATA
			for ((c=0;c<PDD2_CHUNKS_R;c++)) { # chunks
				((${#f})) && pbar $i $PDD2_SECTORS_D "T:$t S:$s C:$c"
				pdd2_mem_read $MEM_CACHE $((PDD2_MEM_RD_LEN*c)) $PDD2_MEM_RD_LEN || return $?
				((${#f})) && x+=" ${ret_dat[*]:3}"
			}
		}
	}

	((${#f})) && {
		printf '%b' "${x//\ /\\x}" >$f
		pbar $i $PDD2_SECTORS_D
		echo
	}
}

# Read a .pdd2 disk image file and write the contents back to a real disk.
pdd2_restore_disk () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==2)) || { perr "Requires TPDD2" ; return 1; }
	local f=$1 x ;local -i t s i= p= c m=
	[[ -e $f ]] || [[ ${f##*.} == ${PDD2_IMG_EXT} ]] || f+=".${PDD2_IMG_EXT}"
	echo "Restoring Disk from File: \"$f\""

	# Read the disk image file file into fhex[]
	echo "Loading \"$f\""
	file_to_fhex "$f" 0 || return $?

	# Look at file size to determine old or new file format. SECTOR_ID_LEN+1
	# is the 12-byte ID plus a 13th mystery byte that is not in the manual,
	# but exists in ram and can be written to and read back from disk.
	for m in $((SECTOR_ID_LEN+1)) ${OLD_PDD2_ID_LEN} ;do
		((${#fhex[*]}==$((PDD2_SECTORS_D*(m+SECTOR_DATA_LEN))))) && break
		m=0
	done
	case $m in
		${OLD_PDD2_ID_LEN}) vecho 0 "Detected OLD PDD2 image file format" ;;
		$((SECTOR_ID_LEN+1))) : ;; #vecho 0 "Detected NEW PDD2 image file format" ;;
		*) err_msg+=("Unexpected file length for PDD2 disk image") ;return 1 ;;
	esac

	# Format the disk
	ocmd_format || return $?

	# Write the sectors
	echo "Writing Disk"
	i=0 p=0
	for ((t=0;t<PDD2_TRACKS;t++)) { # tracks
		for ((s=0;s<PDD2_SECTORS;s++)) { # sectors
			pbar $((i++)) $PDD2_SECTORS_D "T:$t S:$s C:-"

			# skip this sector if the entire sector matches a fresh format
			((t)) && x='16 00' || x='16 FF'
			[[ ${fhex[*]:p:2} == $x ]] && {
				x=${fhex[*]:p+2:m-2+SECTOR_DATA_LEN} ;x=${x//[ 0]/}
				((${#x})) || { ((p+=m+SECTOR_DATA_LEN)) ;continue ; }
			}

			# write ID to cache
			pdd2_mem_write $MEM_CPU $PDD2_ID_ADDR ${fhex[*]:p:m} || return $?
			((p+=m))

			# write DATA to cache
			for ((c=0;c<PDD2_CHUNKS_W;c++)) { # chunks
				pbar $i $PDD2_SECTORS_D "T:$t S:$s C:$c"
				pdd2_mem_write $MEM_CACHE $((c*PDD2_MEM_WR_LEN)) ${fhex[*]:p:PDD2_MEM_WR_LEN} || return $?
				((p+=PDD2_MEM_WR_LEN))
			}

			# write cache to media
			# commit_cache() writes the cache to disk but does not clear the cache.
			# Every byte of cache must be explicitly over-written before here.
			pdd2_commit_cache $t $s || return $?
		}
	}
	pbar $i $PDD2_SECTORS_D
	echo
}

# lcmd_pdd2_mem_read mode start len [filename]
# local command wrapping the drive firmware mem_read command
# mode: 0=sector_cache 1=cpu_memory
# memory map:
# 0x0000 - 0x001F I/O Port
# 0x0080 - 0x00FF CPU Internal RAM (128 bytes)
# 0x4000 - 0x4002 Gate Array
# 0x8000 - 0x87FF RAM (2k bytes)
# 0xF000 - 0xFFFF CPU Internal ROM (4k bytes)
#
# To dump the rom:
# lcmd_pdd2_mem_read 1 0xF000 0x1000 pdd2_rom.bin
#
lcmd_pdd2_mem_read () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==2)) || { perr "Requires TPDD2" ; return 1; }
	local f=$4 x ;local -i m=$1 s=$2 l=$3 i= j= c=${PDD2_MEM_RD_LEN}

	case $m in
		$MEM_CPU) x="cpu memory" ;;
		$MEM_CACHE) x="sector cache" ;;
		*) echo "invalid mode \"$m\"" ;return 1 ;;
	esac
	printf 'Reading %s, addr:0x%04X  length:0x%04X\n' "$x" $s $l

	((${#f})) && {
		echo "to file: \"$f\""
		[[ -e $f ]] && { confirm 'File Exists' || return $? ; }
		quiet=true
	}

	# Drive firmware mem_read() can only give 1-252 bytes at a time, and is
	# is actually limited further to PDD2_MEM_RD_LEN bytes for reliability.
	# Loop however many PDD2_MEM_RD_LEN it takes to get the specified range.
	x= j=$l
	((${#f})) && pbar 0 $j bytes
	while ((l)) ;do
		((l<c)) && ((c=l))
		pdd2_mem_read $m $s $c || return $?
		((${#f})) && x+=" ${ret_dat[*]:3}"
		((l-=c))
		((s+=c))
		((${#f})) && pbar $((i+=c)) $j bytes
	done
	echo

	((${#f})) && printf '%b' "${x//\ /\\x}" >$f
	:
}

# lcmd_pdd2_mem_read mode addr data...
# local command wrapping the drive firmware mem_write command
# mode: 0=sector_cache 1=cpu_memory
# addr: start address
# data: hex pairs...
lcmd_pdd2_mem_write () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	((operation_mode==2)) || { perr "Requires TPDD2" ; return 1; }
	local x ;local -i m= s= l= i= j= p= c=${PDD2_MEM_WR_LEN} ;local -a a
	m=$1 ;shift
	s=$1 ;shift
	a=($*)
	l=${#a[*]}
	case $m in
		$MEM_CPU) x="cpu memory" ;;
		$MEM_CACHE) x="sector cache" ;;
		*) echo "invalid mode \"$m\"" ;return 1 ;;
	esac

	printf 'Writing %s, addr:0x%04X  length:0x%04X\n' "$x" $s $l

	x= j=$l p=0
	((v)) || pbar 0 $j bytes
	while ((l)) ;do
		((l<128)) && ((c=l))
		pdd2_mem_write $m $s ${a[*]:p:c} || return $?
		((p+=c))
		((s+=c))
		((l-=c))
		((v)) || pbar $p $j bytes
	done
	((v)) || pbar $p $j bytes
	echo

	((${#f})) && printf '%b' "${x//\ /\\x}" >$f
}

# pdd2_dump_rom filename
# dump the tpdd2 drive's cpu internal 4k rom to file
lcmd_pdd2_dump_rom () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	fonzie_smack
	pdd2_version || return $?
	#pdd2_sysinfo || return $?
	#pdd2_condition || return $?
	((operation_mode==2)) || { perr "Requires TPDD2" ; return 1; }
	lcmd_pdd2_mem_read $MEM_CPU $ROM_START $ROM_LEN "$1"
}

#pdd2_exec () {
#	echo "Not yet implimented."
#}

# Read the File Control Blocks
# loads the whole table into arrays for the different parts
read_fcb () {
	vecho 3 "${FUNCNAME[0]}($@)"
	local -i i n ;fcb_fname=() fcb_attr=() fcb_size=() fcb_resv=() fcb_head=() fcb_tail=()
	# read sector 0
	((operation_mode==2)) && {
		quiet=true pdd2_read_sector 0 $bank || return $?
	} || {
		quiet=true pdd1_read_sector 0 || return $?
	}

	# legend
	$quiet || {
		echo "_________________________FCB table_________________________"
		echo " # : filename                 | a |  size |       | hd | tl"
		echo "------------------------------+---+-------+-------+----+---"
	}

	# split out the 40 FCBs
	for ((n=0;n<PDD_FCBS;n++)) {
		fcb_fname[n]="${rhex[*]:i:PDD_FNAME_LEN}" ;((i+=PDD_FNAME_LEN)) ;printf -v fcb_fname[n] '%b' "\x${fcb_fname[n]// /\\x}"
		fcb_attr[n]="${rhex[*]:i:FCB_FATTR_LEN}" ;((i+=FCB_FATTR_LEN)) ;printf -v fcb_attr[n] '%b' "\x${fcb_attr[n]}"
		fcb_size[n]="${rhex[*]:i:FCB_FSIZE_LEN}" ;((i+=FCB_FSIZE_LEN)) ;fcb_size[n]=$((0x${fcb_size[n]// /}))
		fcb_resv[n]="${rhex[*]:i:FCB_FRESV_LEN}" ;((i+=FCB_FRESV_LEN))
		fcb_head[n]="${rhex[*]:i:FCB_FHEAD_LEN}" ;((i+=FCB_FHEAD_LEN)) ;fcb_head[n]=$((0x${fcb_head[n]}))
		fcb_tail[n]="${rhex[*]:i:FCB_FTAIL_LEN}" ;((i+=FCB_FTAIL_LEN)) ;fcb_tail[n]=$((0x${fcb_tail[n]}))
		printf -v d_fname '%-24.24b' "${fcb_fname[n]}"
		printf -v d_attr '%1.1s' "${fcb_attr[n]}"
		((EXPOSE_BINARY)) && {
			g_x="$d_fname" ;expose_bytes ;d_fname="$g_x"
			g_x="$d_attr" ;expose_bytes ;d_attr="$g_x"
		}

		$quiet || printf "%2u : %s | %s | %5u | %s | %2u | %2u\n" $n "$d_fname" "$d_attr" "${fcb_size[n]}" "${fcb_resv[n]}" "${fcb_head[n]}" "${fcb_tail[n]}"
	}
}

# Read the Space Managment Table
# SMT is 20+1 bytes immediately following the FCB table.
#
# The first 20 bytes are all bit flags, 1 = sector is used.
#         BIT    Meaning on TPDD1       Meaning on TPDD2
# byte 01 bit 8: physical sector 00  /  track 00 sector 0
# byte 01 bit 7: reserved            /  track 00 sector 1
# byte 01 bit 6: physical sector 01  /  track 01 sector 0
# byte 01 bit 5: reserved            /  track 01 sector 1
# ...
# byte 20 bit 1: physical sector 79  /  track 79 sector 0
# byte 20 bit 0: reserved            /  track 79 sector 1
#
# byte 21 = total used sectors counter
#
# The used-sectors counter doesn't seem to always match what the bit flags add up to.
#
# For TPDD2 we read from sector 0 if we are currently in bank 0, and sector 1
# if we are currently in bank 1, just for academic correctness to follow the
# FCB table. But the drive seems to maintain identical copies in both sectors.
# We could probably just always read the sector 0 copy.
read_smt () {
	vecho 3 "${FUNCNAME[0]}($@)"
	local x=() s=() ci co f ;local -i y i= l= w
	# read the 21 bytes
	((operation_mode==2)) && {
		echo "____________________________Space Management Table_____________________________"
		pdd2_cache 0 $bank $CACHE_LOAD || return $?
		pdd2_mem_read $MEM_CACHE $SMT_OFFSET $SMT_LEN >/dev/null || return $?
		x=(${ret_dat[*]:3})
	} || {
		echo "__________________Space Management Table___________________"
		pdd1_read_sector 0 >/dev/null || return $?
		x=(${rhex[*]:SMT_OFFSET:SMT_LEN})
	}
	vecho 1 "SMT${bd}: ${x[*]}"
	# decode the bit-flags
	echo "Bytes 1-20: bit-flags of used sectors:"
	i=0 f="0x80 0x20 0x08 0x02" w=2
	((operation_mode==2)) && f="0x80 0x40 0x20 0x10 0x08 0x04 0x02 0x01" w=3
	for ((y=0;y<SMT_LEN-1;y++)) {
		for b in $f ;do
			ci= co= ;((0x${x[y]}&b)) && ci=$tinverse co=$tclear
			printf '%b%*.*u%b' "$ci" $w $w $((i++)) "$co"
			((++l<20)) && printf ' ' || { printf '\n' ;l=0 ; }
		done
	}
	# byte 21 is a simple number
	printf 'Byte 21: sectors used: %d\n' "0x${x[y]}"
}

###############################################################################
# Server Functions
# These functions are for talking to a client not a drive

# write a single byte $1 to the com port
# followed by $2 ms sleep
slowbyte () {
	printf '%b' "\x$1" >&3
	_sleep $2
}

# write file $1 to com port with per-character sleep
# followed by BASIC_EOF character
srv_send_loader () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local -i i l;local s REPLY x="${XONOFF:-false}"
	ms_to_s $LOADER_PER_CHAR_MS ;s=${_s}
	file_to_fhex $1 0

	XONOFF=true ;set_stty

	echo "Installing $1"
	echo 'Prepare the portable to receive:'
	echo 'TANDY, Kyotronic, Olivetti:  RUN "COM:98N1ENN"'
	echo '                       NEC:  RUN "COM:9N81XN"'
	read -p 'Press [Enter] when ready...'

	l=${#fhex[*]}
	for ((i=0;i<l;i++)) ;do
		slowbyte ${fhex[i]} $s
		((v)) && {
			((i && 0x${fhex[i-1]}==0x$BASIC_EOL && 0x${fhex[i]}!=0x0A)) && echo
			printf '%b' "\x${fhex[i]}"
		} || pbar $((i+1)) $l 'bytes'
	done

	# Add trailing ^M and/or ^Z if the file didn't already.
	case ${fhex[i]} in
		$BASIC_EOF) : ;;
		$BASIC_EOL) slowbyte $BASIC_EOF $s ;;
		*) slowbyte $BASIC_EOL ;slowbyte $BASIC_EOF $s ;;
	esac

	XONOFF=$x ;set_stty ;echo
}

###############################################################################
# Local Commands
# high level functions implemented here in the client
# (vs wrappers for drive firmware functions)

set_pdd1 () {
	operation_mode=1 bd= PDD_MAX_FLEN=$PDD1_MAX_FLEN
}

set_pdd2 () {
	operation_mode=2 bd="[$bank]" PDD_MAX_FLEN=$PDD2_MAX_FLEN
}

# fonzie_smack()
# send M1\r
#
# Take a drive in an unknown state (because we just started up and have no way
# to know what state the drive was already in before we started running), and
# have the drive be in a known state at the end, without locking up the drive
# along the way by sending data it wasn't expecting. IE bump it to make it work
#
# The only assumption we make, because we have to, is that the drive is not
# already in the middle of some operation, but is waiting to process either
# FDC or OPR commands. If the drive were in the middle of some long-running
# operation like format-disk, or multi-stage operation like read_file,
# there is no safe way to detect that and avoid locking up the drive firmware.
#
# If: Drive was in FDC-mode.
# Then: "M1<CR>" is a valid FDC-mode command to switch from FDC to OPR-mode.
# End: Drive should now be in OPR-mode, because we just switched to it.
#
# If: Drive was in OPR-mode (including PDD2).
# Then: Drive should be reading and consuming but otherwise ignoring
#       anything that isn't 0x5A, and none of these bytes are 0x5A.
# End: Drive should now be in OPR-mode, because it already was.
#
fonzie_smack () {
	vecho 2 "${FUNCNAME[0]}($@)"
	tpdd_drain
	tpdd_write 4D 31 0D
	_sleep 0.003  # cribbed from TS-DOS
	tpdd_drain
	#((operation_mode)) || operation_mode=1
	#ocmd_ready || ocmd_ready
}

set_fcb_filesizes () {
	case "$1" in
		false|off|no|0) FCB_FSIZE=false ;;
		true|on|yes|1) FCB_FSIZE=true ;;
		#'') $FCB_FSIZE && FCB_FSIZE=false || FCB_FSIZE=true ;;
	esac
	echo "Use FCB table for true file sizes: $FCB_FSIZE"
	${FCB_FSIZE} && {
		echo "ls/dir reads the FCB table to get true file sizes."
		echo "This slows down directory listings but the file sizes are correct."
	} || {
		echo "ls/dir displays the file sizes given by the drive's \"directory entry\" command."
		echo "This is faster but the file sizes are not exact."
	}
}

set_mslog () {
	[[ $EPOCHREALTIME ]] || {
		$quiet || echo "Millisecond timestamps requires bash 5"
		return;
	}
	case "$1" in
		false|off|no|0) MSLOG=false ;;
		true|on|yes|1) MSLOG=true ;;
		#'') $MSLOG && MSLOG=false || MSLOG=true ;;
	esac
	mslog 2>&- >&- # hide the first call shows epoch instead of elapsed
	$quiet || echo "Print millisecond timestamps: $MSLOG"
}

set_verify () {
	case "$1" in
		false|off|no|0) WITH_VERIFY=false ;;
		true|on|yes|1) WITH_VERIFY=true ;;
		#'') $WITH_VERIFY && WITH_VERIFY=false || WITH_VERIFY=true ;;
	esac
	echo "fdc_format, write_logical, write_id  WITH_VERIFY=$WITH_VERIFY"
}

set_yes () {
	case "$1" in
		false|off|no|0) YES=false ;;
		true|on|yes|1) YES=true ;;
		#'') $YES && YES=false || YES=true ;;
	esac
	echo "Assume \"yes\" instead of confirming actions: $YES"
}

set_expose () {
	local -i e=$EXPOSE_BINARY
	case "$1" in
		false|off|no) e=0 ;;
		true|on|yes) e=1 ;;
		0|1|2) e=$1 ;;
		#'') ((e)) && e=0 || e=1 ;;
	esac
	EXPOSE_BINARY=$e
	echo -n 'Expose non-printable bytes in filenames: '
	((EXPOSE_BINARY)) && echo 'Enabled' || echo 'Disabled'
}

get_condition () {
	((operation_mode==2)) && { pdd2_condition ;return $? ; }
	fcmd_ready
}

bank () {
	((operation_mode==2)) || { perr "Requires TPDD2" ; return 1; }
	case $1 in 0|1) bank=$1 ;; esac
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
			[[ ${a[$FAH]} ]] || a[$FAH]="$ATTR" m+=("$FAH '$ATTR'")
		done
		select x in "${m[@]}" other ;do
		x="${x%% *}"
		case "$x" in
			other) x= ;read -p "Enter a single byte or a hex pair: " x ;;
			*) [[ ${a[$x]} ]] && x="${a[$x]}" || x= ;;
		esac
			set_attr "$x" && break
		done
	}
	((FNL==n && FEL==e)) || COMPAT="none" FNL="$n" FEL="$e"
}

# list disk directory
lcmd_ls () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local -i m=${dirent_cmd[get_first]}

	((operation_mode==2)) && {
		echo "-----  Directory Listing   [$bank]  -----"
	} || {
		echo '--------  Directory Listing  --------'
	}

	while ocmd_dirent '' "$1" $m ;do
		un_tpdd_file_name "$file_name"
		printf -v d_fname '%-24.24b' "$file_name"
		printf -v d_attr '%1.1s' "$file_attr"

		((EXPOSE_BINARY)) && {
			g_x="$d_fname" ;expose_bytes ;d_fname="$g_x"
			g_x="$d_attr" ;expose_bytes ;d_attr="$g_x"
		}

		printf '%s | %s | %6u\n' "$d_fname" "$d_attr" "$file_len"
		((m==${dirent_cmd[get_first]})) && m=${dirent_cmd[get_next]}
	done

	echo '-------------------------------------'
	((${#err_msg[*]})) && return
	_sleep 0.01 ;quiet=true get_condition || return $?
	((operation_mode==0)) && { _sleep 0.01 ; quiet=true fcmd_mode 1 ; }
	printf "%-32.32s %4.4s\n" "$((free_sectors*SECTOR_DATA_LEN)) bytes free" "${err_msg[-1]}" ;unset err_msg[-1]
}

# load a file (copy a file from tpdd to local file or memory)
# lcmd_load src-filename [dest-filename [src-attr]]
# If $2=='' or absent, use the source tpdd filename as the dest local filename.
# If $3 absent, use default $ATTR for src attr.
# Extra mode used internally by "mv" on tpdd1: if $#==4 then load into fhex[]
# instead of writing a file.
lcmd_load () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local x s="$1" d="${2:-$1}" a="$3" r=false ;local -i p= l= i ;fhex=()
	((${#}<3)) && a="$ATTR"
	((${#}>3)) && r=true
	$r && d= || {
		((${#d})) || {
			echo "save src [dest [attr]]"
			echo "src  - tpdd filename"
			echo "dest - local filename - absent or '' = same as src"
			echo "attr - attribute - absent='$ATTR'  ''=0x00  ' '=0x20"
			return 1
		}
	}
	echo -n "Loading TPDD$bd:$s ($a)"
	vecho 1 ""

	ocmd_dirent "$s" "$a" ${dirent_cmd[set_name]} || return $?	# set the source filename
	((${#file_name})) || { err_msg+=('No Such File') ;return 1 ; }
	l=$file_len
	((${#d})) && {
		echo " to $d"
		[[ -e $d ]] && { confirm 'File Exists' || return $? ; }
		>"$d"
	} || {
		echo
	}

	pbar 0 $l 'bytes'
	ocmd_open ${open_mode[read]} || return $?	# open the source file for reading
	while ocmd_read ;do					# repeat ocmd_read() until it fails
		((${#d})) && {
			x="${ret_dat[*]}" ;printf '%b' "\x${x// /\\x}" >> "$d" ;: # add to file
		} || {
			fhex+=(${ret_dat[*]})		# add to fhex[]
		}
		((p+=${#ret_dat[*]}))

		# If not using FCB, then the file size reported by from dirent() from
		# real drives (not emulators) is often smaller than reality.
		# So if p grows past l, don't exit the loop, just update l so that we
		# don't end with a final display like "100% (23552/23460 bytes)"
		# Also simplifies the final sanity check.
		$FCB_FSIZE || { ((p>l)) && l=$p ; }

		pbar $p $l 'bytes'
	done

	ocmd_close || return $?				# close the source file
	((p==l)) || { err_msg+=("Error: Expected $l bytes, got $p") ; return 1 ; }
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
		[[ -r $s ]] || { err_msg+=("\"$s\" not found") ;return 1 ; }
		file_to_fhex "$s" || return 4
	}
	l=${#fhex[*]}
	echo "Saving TPDD$bd:$d ($a)"
	ocmd_dirent "$d" "$a" ${dirent_cmd[set_name]} || return $?
	((${#file_name})) && { confirm 'File Exists' || return $? ; }
	ocmd_open ${open_mode[write_new]} || return $?
	for ((p=0;p<l;p+=FILE_RW_LEN)) {
		pbar $p $l 'bytes'
		ocmd_write ${fhex[*]:p:FILE_RW_LEN} || return $?
	}
	pbar $l $l 'bytes'
	echo
	ocmd_close || return $?
}

# delete a file
# lcmd_rm filename [attr]
lcmd_rm () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	vecho 3 "#=$# @=\"$@\""
	local a
	case $# in # $2='' is distinct from $2 absent
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
	((operation_mode==2)) && { # TPDD2 has a rename function
		echo "Moving TPDD$bd: $sn ($sa) -> $dn ($da)"
		ocmd_dirent "$sn" "$sa" ${dirent_cmd[set_name]} || return $?
		pdd2_rename "$dn" "$da" ;return $?
	} # TPDD1 requires load>rm>save, or edit the FCB
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

###############################################################################
# manual/raw debug commands

lcmd_com_show () {
	local -i e=
	lcmd_com_test ;e=$?
	((v)) && {
		stty ${stty_f} "${PORT}" -a ; :
	} || {
		printf "speed: " ;stty ${stty_f} "${PORT}" speed
	}
	return $e
}

lcmd_com_test () {
	local -i e=
	test_com ;e=$?
	((e)) && echo "${PORT} is closed" || echo "${PORT} is open"
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

lcmd_com_speed () {
	(($#)) && { BAUD=$1 ;set_stty ; }
	lcmd_com_show
}

###############################################################################
# experimental junk

# What pdd1_boot() and pdd2_boot() attempt to do is mimick a 100 or 200
# doing the official bootstrap with a real drive and real util disk.
# The bootstrap procedure is a multi-stage process of the drive sending
# bits of BASIC code to the client, the client executes the BASIC code,
# which invokes more stuff from the drive, etc. It's a few back & forth
# transactions, not just one transaction to download and install a .CO
#
# So these attempt to mimic the initial manual user kick-off steps and
# mimic running each bit of collected BASIC code and send back whatever
# a 100 or 200 would have.
#
# These are incomplete. They begin the process and get a little way but
# the later parts aren't worked out yet.

# Emulate a client performing the TPDD1 boot sequence
# pdd1_boot [100|200]
# 100 - pretend to be a model 100
# 200 - pretend to be a model 200
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
	#   Model 100: 167 -> M2=0
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
# The real TPDD2 bootstrap doesn't merely read a file from the disk,
# it loads BASIC code to the client which detects the client model
# and then uses mem_write() to load machine code into the drives memory,
# and then exec() to execute that machine code on the drive, and that
# machine code is what finally sends back the actual FLOPPY.CO
# We will not be able to really emulate that.

# pdd2_boot [100|200]
pdd2_boot () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local REPLY M mdl=${1:-100}

	echo -en "------ TDPP2 (26-3814) bootstrap ------\n" \
		"Turn the drive power OFF.\n" \
		"Take a TPDD2 (26-3814) Utility Disk,\n" \
		"  verify that the write-protect hole is OPEN,\n" \
		"  insert the disk.\n" \
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
	#   Model 100: 167 -> M=3
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

chk_cmd_err () {
	((${#err_msg[*]})) && {
		printf '\n%s:\n' "${_c}"
		for x in "${err_msg[@]}" ;do printf '%s\n' "$x" ;done
		fonzie_smack
		tpdd_drain
	} >&2
}

do_cmd () {
	local z=${FUNCNAME[0]} ;vecho 3 "$z($@)"
	local -i _i _e _det=256 _v ;local _a=() _c x
	IFS=\; _a=($@) IFS="$ifs" quiet=false
	for ((_i=0;_i<${#_a[@]};_i++)) {
		eval set ${_a[_i]}
		_c=$1 ;shift
		_e=${_det} err_msg=()
		case ${_c} in

	#
	# commands that may run before _init()
	#

			#h
			#h COMMAND | SYNONYM(S) PARAMETERS
			#h     DESCRIPTION

			#c 1 # this comment is used by help()

			q|quit|exit|bye) exit ;;
			#h Order Pizza

			\?|h|help) help $* ;_e=$? ;; # [command]
			#h Display built-in help.
			#h If command is supplied, shows only the help for that command, if found.
			#h If verbose = 0, hides the hacky, low-level, and less-common commands.
			#h If verbose > 0, shows all commands.

			v|verbose|debug) ((${#1})) && v=$1 ;echo "Verbose level: $v" ;_e=0 ;; # [n]
			#h Set verbosity level, display current setting.

			y|yes|batch) set_yes $* ;_e=0 ;; # [true|false]
			#h Set non-interactive mode, display current setting.
			#h Assume "y" for all confirmation prompts. Use for scripting.

			compat) ask_compat "$@" ;_e=$? ;; # [floppy|wp2|raw]
			#h Set filename & attr to match the type of machine you are trading disks with.
			#h
			#h   floppy: 6.2 space-padded filenames    with attr 'F'
			#h           TRS-80 Model 100 & clones
			#h
			#h   wp2   : 8.2 space-padded filenames    with attr 'F'
			#h           TANDY WP-2
			#h
			#h   raw   : 24 byte unformatted filenames with attr ' '
			#h           Cambridge Z88, CP/M, others?
			#h
			#h Presents a menu if not given.

			floppy|wp2|raw) ask_compat "${_c}" ;_e=$? ;;
			#h Short for "compat ___"
			#h ex: "wp2" = "compat wp2"

			baud|speed) lcmd_com_speed $* ;_e=$? ;; # [baud]
			#h Set the serial port to the specified baud rate, display current setting.
			#h TPDD1 has dip switches for:
			#h 150 300 600 1200 2400 4800 9600 19200 38400 76800
			#h TPDD2 is 19200 only
			#h 76800 probably won't be usable because we rely on the stty utility to configure the serial port hardware, and that only supports a limited set of standard rates on linux on common platforms.
			#h It may work on some platforms like linux on sparc.
			#  c code to set 76800 on linux http://cholla.mmto.org/esp8266/weird_baud/
			#  It would take some experimenting to see if it would be possible to use that here.
			#  Can we use stty to set the other parameters without losing a custom baud rate previously set up by baud.c ?

			150|300|600|1200|2400|4800|9600|19200|38400|76800) lcmd_com_speed ${_c} ;_e=$? ;;
			#h Short for "baud ___"
			#h ex: "9600" = "baud 9600"

			bootstrap|send_loader) srv_send_loader "$@" ;_e=$? ;; # filaname
			#h Send an ascii BASIC file over the serial port slowly enough for BASIC to read.
			#h The connected device must be a computer like a Model 100, not a TPDD drive.

			ffs|ffsize|fcb_fsize) set_fcb_filesizes $1 ;_e=0 ;; # [true|false]
			#h Set FCB_FSIZE mode, display current setting.
			#h A real TPDD drive's directory listing function returns inaccurate file sizes.
			#h This setting causes "ls" and "load" to read the FCB table from sector 0 ourselves to get the true file sizes.
			#h This is an extra step and slows down directory listings, but the displayed file sizes are correct.
			#h
			#h *This will not work with TPDD Emulators!*
			#h This uses FDC mode to read sector 0 as a raw sector, and most emulators only know how to load & save files.
			#h But emulators also give correct file sizes, so this is not needed with any TPDD emulators anyway.

			ms|mslog) set_mslog $1 ;_e=0 ;; # [true|false]
			#h Set MSLOG mode, display current setting.
			#h Print "ms: ########" at various points, showing the number
			#h of milliseconds elapsed since the previous timestamp.
			#h Requires bash 5

			bank) bank $1 ;_e=$? ;; # [0|1]
			#h (TPDD2) Switch to bank 0 or 1 on a TPDD2, display current setting.

			ll) lcmd_ll $* ;_e=$? ;;
			#h Local Directory List, no filesizes.
			#h Faster/cheaper than lls.

			#llm) lcmd_llm $* ;_e=$? ;;
			lls) lcmd_lls $* ;_e=$? ;;
			#h Local Directory List, with filesizes.

			#c 2

			smack) fonzie_smack ;_e=$? ;;
			#h (TPDD1) Blind-send a sequence including the the FDC-mode command to switch a TPDD1 drive to Operation mode, & drain the tty buffer to ignoring any errors or other responses.
			#h This only has any effect on a TPDD1 drive, but is sent to all drives as part of the initial startup to ensure that the as-yet-unknown drive, if it is a TPDD1, is put into Operation mode.

			eb|expose|expose_binary) set_expose $1 ;_e=0 ;; # [0-2]
			#h Set EXPOSE_BINARY mode, display current setting.
			#h Expose non-printable binary bytes in filenames and attr.
			#h
			#h 0 = off
			#h
			#h 1 = display 0x00 to 0x1F as inverse-video "@" to "_"
			#h     display 0x7F to 0xFF as inverse-video "."
			#h     ex: 0x01 = "^A", displayed as inverse-video "A"
			#h     This mode allows to expose all bytes without altering the display formatting because each byte still only occupies a single character space.
			#h
			#h 2 = All non-printing bytes displayed as inverse-video hex pair.
			#h     ex: 0xB5 displayed as inverse-video "B5"
			#h     This mode shows the actual value of all bytes, but messes up the display formatting because each non-printing byte requires 2 character spaces.
			#h
			#h An example is the the TPDD2 Util disk, which has an 0x01 byte as the first byte of the first filename.

			attr) ask_attr "$@" ;_e=$? ;; # [b|hh]
			#h Set the default attribute byte.
			#h b = any single byte  ex: F
			#h hh = hex pair representing a byte value  ex: 46
			#h Presents a menu if not given.

			pdd1) fonzie_smack ;set_pdd1 ;_e=$? ;;
			#h Assume the attached drive is a TPDD1

			pdd2) set_pdd2 ;_e=$? ;;
			#h Assume the attached drive is a TPDD2

			rtscts|hardware_flow) RTSCTS=${1:-true} ;set_stty ;lcmd_com_show ;_e=$? ;; # [true|false]
			#h Enable hardware flow control.
			#h Display current setting.

			xonoff|xonxoff|software_flow) XONOFF=${1:-false} ;set_stty ;lcmd_com_show ;_e=$? ;; # [true|false]
			#h Enable software flow control.
			#h Display current setting.
			#h This is only potentially useful for send_loader().
			#h The TPDD protocol is full of binary data that is not encoded in any way.

			verify|with_verify) set_verify $* ;_e=0 ;; # [true|false]
			#h Set WITH_VERIFY, display current setting.
			#h Use the "no-verify" versions of FDC-format, Write Sector, and Write ID
			#h ex: commands like "dump_disk" which uses all of those commands internally, will use the "no-verify" versions for all operations along the way.
			#h There are verify/no-verify versions of some TPDD2 commands also, but currently this only affects TPDD1. All TPDD2 commands always use the with-verify version.
			# TODO update all uses of pdd2_cache() commit

			com_test) lcmd_com_test ;_e=$? ;;
			#h Check if the serial port is open

			com_show) lcmd_com_show ;_e=$? ;;
			#h Display the serial port parameters
			#h higher verbose settings show more info

			com_open) lcmd_com_open ;_e=$? ;;
			#h Open the serial port

			com_close) lcmd_com_close ;_e=$? ;;
			#h Close the serial port

			com_read) (($#)) && x=tpdd_read || x=tpdd_read_unknown ;$x $* ;_e=$? ;; # [n]
			#h Read n (or all available) bytes from serial port

			com_write) (($#)) && tpdd_write $* ;_e=$? ;; # data
			#h Write data to serial port
			#h data: space-seperated hex pairs

			read_fdc_ret) fcmd_read_ret $* ;_e=$? ;; # [timeout_ms] [busy_indicator]
			#h (TPDD1) Read an FDC-mode return message (after sending some FDC-mode command)
			#h timeout_ms: max time in ms to wait for data from the drive
			#h             default 5000
			#h busy_indicator:
			#h  1 = display a spinner while waiting
			#h  2 = display a percent-done progress bar while waiting

			read_opr_ret) ocmd_read_ret $* ;_e=$? ;; # [timeout_ms] [busy_indicator]
			#h Read an OPR-mode return message (after sending some OPR-mode command)
			#h timeout_ms: max time in ms to wait for data from the drive
			#h             default 5000
			#h busy_indicator:
			#h  1 = display a spinner while waiting
			#h  2 = display a percent-done progress bar while waiting

			send_opr_req) ocmd_send_req $* ;_e=$? ;; # fmt data
			#h Send an OPR-mode command
			#h fmt: single hex pair for an TPDD1 Operation-mode or TPDD2 "request format"
			#h data: space-seperated hex pairs for the payload data
			#h The "ZZ" preamble, length, and checksum bytes are calculated and added automatically

			check_opr_err) ocmd_check_err ;_e=$? ;;
			#h Check ret_dat[] for an OPR-mode error code
			#h ret_dat[] must be filled by a previous read_opr_ret

			drain) tpdd_drain ;_e=$? ;;
			#h Read and discard all available bytes from the serial port

			checksum) calc_cksum $* ;_e=$? ;; # data
			#h Calculate the checksum for the given data, using the same method that the TPDD uses.
			#h data: Up to 128 space-seperated hex pairs.
			#h returns: Bitwise negation of least significant byte of sum of all bytes, returned as a hex pair.
			#h TPDD checksums include the format, length, and data fields of OPR-mode commands and responses.

			sleep) _sleep $* ;_e=$? ;; # n
			#h Sleep for n seconds. n may have up to 3 decimals, so 0.001 is the smallest value.

			version|detect_model) ((v)) && _v=$v || _v=1 ;v=$_v pdd2_version ;_e=$? ;;
			#h (TPDD2) Return drive version data
			#h This is a TPDD2-only command, but is intentionally sent to all drives as a way to automatically detect whether a TPDD1 or TPDD2 is connected.

			sysinfo) ((v)) && _v=$v || _v=1 ;v=$_v pdd2_sysinfo ;_e=$? ;;
			#h (TPDD2) Return drive system info data
			#h just like version() but different info

			#c 0

			'') _e=0 ;;
		esac
		((_e!=_det)) && { # detect if we ran any of the above
			#((${#err_msg[*]})) && printf '\n%s: %s\n' "${_c}" "${err_msg[*]}" >&2
			chk_cmd_err
			continue
		}

	#
	# commands that may not run before _init()
	#

		$did_init || _init
		_e=0

		case ${_c} in

			#c 2

	# TPDD1 switch between operation-mode and fdc-mode

			fdc) ocmd_fdc $* ;_e=$? ;; # [force]
			#h (TPDD1) Switch a TPDD1 drive from OPR-mode to FDC-mode
			#h force = send command even if we think we're already in fdc mode

			opr) fcmd_mode 1 ;_e=$? ;;
			#h (TPDD1) Switch a TPDD1 drive from FDC-mode to OPR-mode

	# TPDD1 & TPDD2 file access
	# Most of these are low-level, not used directly by a user.
	# Higher-level commands like ls, load, & save are built out of these.

			_dirent) ocmd_dirent "$@" ;_e=$? ;; # filename attr action
			#h Wrapper for the drive firmware "Directory Entry" command
			#h filename: 1-24 bytes plain ascii, quoted if spaces
			#h attr: 1 byte plain ascii
			#h action: TPDD1: 0=set_name  1=get_first  2=get_next
			#h action: TPDD2: same as TPDD1 plus 3=get_prev  4=close
			#h
			#h set_name sets the filename which subsequent open/read/write/close/delete will operate on.
			#h get_first, get_next, get_prev are used to build directory listings.

			_open) ocmd_open $* ;_e=$? ;; # access_mode
			#h Wrapper for the drive firmware "File Open" command
			#h access_mode:
			#h   01 = write_new
			#h   02 = write_append
			#h   03 = read
			#h
			#h Operates on filename previously set by _dirent(set_name)

			_close) ocmd_close ;_e=$? ;;
			#h Wrapper for the drive firmware "File Close" command
			#h
			#h Operates on filename previously set by _dirent(set_name)

			_read) ocmd_read ;_e=$? ;;
			#h Wrapper for the drive firmware "File Read" command
			#h
			#h Operates on filename previously set by _dirent(set_name)

			_write) ocmd_write $* ;_e=$? ;; # data
			#h Wrapper for the drive firmware "File Write" command
			#h data: 1-128 space-seperated hex pairs
			#h
			#h Operates on filename previously set by _dirent(set_name)

			_delete) ocmd_delete ;_e=$? ;;
			#h Wrapper for the drive firmware "File Delete" command
			#h
			#h Operates on filename previously set by _dirent(set_name)

			#c 1

			format|mkfs) ocmd_format ;_e=$? ;;
			#h Format disk with filesystem

			ready|status) ocmd_ready $* ;_e=$? ;((_e)) && printf "Not " ;echo "Ready" ;; # [1]
			#h Report basic drive ready / not ready
			#h 1 = send req code 0x47 instead of 0x07 - undocumented tpdd2-only option that PakDOS uses

			#c 2

	# TPDD1 sector access - aka "FDC mode" functions.

			fdc_set_mode) fcmd_mode $* ;_e=$? ;; # operation_mode
			#h (TPDD1) Switch drive from FDC-mode to ___-mode
			#h operation_mode: 0=FDC (no-op)  1=OPR (switch to OPR mode)

			cond|condition) get_condition ;_e=$? ;;
			#h (TPDD1) Get drive readiness condition flags
			#h Slightly more info than the "ready" command

			ff|fdc_format) fcmd_format $* ;_e=$? ;; # [lsc]
			#h (TPDD1) Format disk without filesystem
			#h lsc: logical sector size code 0-6
			#h
			#h A TPDD1 disk is organized into 80 physical sectors numbered 0-79.
			#h Each physical sector is divided into a number of logical sectors.
			#h Each physical sector has a logical size code, which says how large the logical sectors are for that physical sector.
			#h
			#h When formatting a disk for raw sector data access (no filesystem), you specify a logical size code, and that is applied to all physical sectors.
			#h
			#h The valid logical size codes are 0 to 6:
			#h 0 = 64 bytes  (20 logical sectors)
			#h 1 = 80        (16)
			#h 2 = 128       (10)
			#h 3 = 256       (5)
			#h 4 = 512       (2, wastes 256 bytes per physical sector)
			#h 5 = 1024      (1, wastes 256 bytes per physical sector)
			#h 6 = 1280      (1)

			ffnv|fdc_format_nv) WITH_VERIFY=false fcmd_format $* ;_e=$? ;; # [lsc]
			#h (TPDD1) Same as fdc_format, without verify.

			rl|read_logical) fcmd_read_logical $* ;_e=$? ;; # p l
			#h (TPDD1) Read a single logical sector
			#h p: physical sector, 0-79
			#h l: logical sector, 1-20
			#h Valid values for l depends on the LSC of the physical sector.
			#h If LSC is 0, l may be 1-20
			#h If LSC is 6, the only valid l is 1

			si|search_id) fcmd_search_id $* ;_e=$? ;; # data
			#h (TPDD1) Search for physical sector with ID section that matches.
			#h data: up to 12 hex pairs
			#h data is null-padded and/or truncated to exactly 12 bytes
			#h returns: physical sector number of fist match, if any
			#h There is no way to search for multiple matches.
			#h The drive always returns the first match, and there is no command or option to set a different starting point etc)

			wi|write_id) fcmd_write_id $* ;_e=$? ;; # p data
			#h (TPDD1) Write ID
			#h p: physical sector number, 0-79
			#h data: up to 12 hex pairs
			#h Writes data to the ID section of a physical sector
			#h data is null-padded and/or truncated to exactly 12 bytes

			winv|write_id_nv) WITH_VERIFY=false fcmd_write_id $* ;_e=$? ;; # p data
			#h (TPDD1) Same as write_id, without verify

			wl|write_logical) fcmd_write_logical $* ;_e=$? ;; # p l data
			#h (TPDD1) Write Sector - Write a single logical sector within a physical sector.
			#h p: physical sector, 0-79
			#h l: logical sector, 1-20
			#h data: 64-1280 space-sepersated hex pairs
			#h
			#h l and data must match whatever the logical sector size code is for the physical sector.
			#h
			#h Examples,
			#h If the specified physical sector has logical size code 0,
			#h then l may be 1-20, and data must be 64 hex pairs.
			#h
			#h If the specified physical sector has logical size code 6,
			#h then l must be 1, and data must be 1280 hex pairs.

			wlnv|write_logical_nv) WITH_VERIFY=false fcmd_write_logical $* ;_e=$? ;; # p l data
			#h (TPDD1) Same as write_logical, without verify

	# TPDD2 sector access

			cache) pdd2_cache $* ;_e=$? ;; # track sector action
			#h (TPDD2) Load cache from media or Commit cache to media.
			#h track: 0-79
			#h sector: 0-1
			#h action: 0=load (disk to cache) 1=commit (cache to disk) 2=commit+verify

	# TPDD1 & TPDD2 local/client sector access

			mem_read) lcmd_pdd2_mem_read $* ;_e=$? ;; # mode address length [filename]
			#h (TPDD2) Read from drive memory
			#h mode: 0=sector_cache 1=cpu_memory
			#h addr: in mode 0: 0-1279  in mode 1: 0-65535
			#h len: in mode 0: 1-1280  in mode 1: 1-65534
			#h Output to filename if given.
			#h
			#h memory map (same for both TPDD1 and TPDD2):
			#h 0x0000 - 0x001F CPU I/O Port
			#h 0x0080 - 0x00FF CPU Internal RAM (128 bytes)
			#h 0x4000 - 0x4002 Gate Array
			#h 0x8000 - 0x87FF RAM (2k bytes)
			#h 0xF000 - 0xFFFF CPU Internal ROM (4k bytes)

			mem_write) lcmd_pdd2_mem_write $* ;_e=$? ;; # mode address data...
			#h (TPDD2) Write to drive memory
			#h mode: 0=sector_cache 1=cpu_memory
			#h addr: in mode 0: 0-1279  in mode 1: 0-65535
			#h data: hex pairs...

			rh|read_header) ((operation_mode==2)) && { pdd2_read_id "$@" ;_e=$? ; } || { fcmd_read_id "$@" ;_e=$? ; } ;; # sector(s)
			#h Rread & display metadata for one or more sectors.
			#h sector(s):
			#h TPDD1: physical_sector (0-79), or space-seperated list, or "all"
			#h   returns: the LSC and 12-byte ID section for the physical sector
			#h TPDD2: track,sector (0-79,0-1), or linear_sector (0-159), or list, or "all"
			#h   returns: the 12-byte ID section for the track,sector

			rs|read_sector) ((operation_mode==2)) && { pdd2_read_sector "$@" ;_e=$? ; } || { pdd1_read_sector "$@" ;_e=$? ; } ;; # TPDD1_physical_sector or TPDD2_track TPDD2_sector
			#h Read & display sector main data
			#h TPDD1_physical_sector: 0-79
			#h TPDD2_track: 0-79
			#h TPDD2_sector: 0-1

			fcb|read_fcb) read_fcb ;_e=$? ;;
			#h Display the contents of the File Control Block table

			smt|read_smt) read_smt ;_e=$? ;;
			#h Display the contents of the Space Management Table

			pdd2_reset) pdd2_reset_drive_status ;_e=$? ;;
			#h (TPDD2) Reset Drive Status
			#h The TPDD2 service manual page 102 has this, but doesn't explain it.
			#h Writes 3 bytes to 3 memory addresses.

			#rom_dump|dump_rom) pdd2_version ;((operation_mode==2)) && { lcmd_pdd2_dump_rom "$@" ;_e=$? ; } || { lcmd_pdd1_dump_rom "$@" ;_e=$? ; } ;; # [filename]
			rom_dump|dump_rom) lcmd_pdd2_dump_rom "$@" || lcmd_pdd1_dump_rom "$@" ;_e=$? ;; # [filename]
			#h Read 4k bytes at 0xF000
			#h output to filename if given
			#h
			#h On TPDD2 this is just a convenience shortcut for
			#h "mem_dump 1 0xF000 0x1000 [filename]"
			#h
			#h On TPDD1 this requires configuring the drive to a special
			#h mode using the dip switches on the bottom, and then sending
			#h S-records of machine code to the drive.

			#c 1

			dd|dump_disk) ((operation_mode==2)) && { pdd2_dump_disk "$@" ;_e=$? ; } || { pdd1_dump_disk "$@" ;_e=$? ; } ;; # dest_img_filename
			#h Clone a physical disk to a disk image file

			rd|restore_disk) ((operation_mode==2)) && { pdd2_restore_disk "$@" ;_e=$? ; } || { pdd1_restore_disk "$@" ;_e=$? ; } ;; # src_img_filename
			#h Clone a disk image file to a physical disk

	# TPDD1 & TPDD2 local/client file access
	# These are used by the user directly

			ls|dir|list) lcmd_ls "$@" ;_e=$? ;;
			#h List disk directory

			rm|del|delete) lcmd_rm "$@" ;_e=$? ;; # filename [attr]
			#h Delete filename [attr] from disk

			load) (($#<4)) && lcmd_load "$@" ;_e=$? ;; # src_filename [dest_filename] [attr]
			#h Copy a file from disk to local

			save) lcmd_save "$@" ;_e=$? ;; # src_filename [dest_filename] [attr]
			#h Copy a file from local to disk

			mv|ren|rename) lcmd_mv "$@" ;_e=$? ;; # src_filename dest_filename [attr]
			#h Rename a file on-disk

			cp|copy) lcmd_cp "$@" ;_e=$? ;; # src_filename dest_filename [attr]
			#h Copy a file from on-disk to on-disk

			#c 2

	# other
			pdd1_boot) pdd1_boot "$@" ;_e=$? ;; # [100|200]
			#h Mimic a model 100 or 200 bootstrapping from a TPDD1

			pdd2_boot) pdd2_boot "$@" ;_e=$? ;; # [100|200]
			#h Mimic a model 100 or 200 bootstrapping from a TPDD2

			#c 0

			*) err_msg+=("Unrecognized command") ;_e=1 ;;

		esac
		chk_cmd_err
	}
	return ${_e}
}

#h
#h Most commands that take true|false arguments also take yes,no,y,n,1,0,on,off.
#h
#h A few commands that take numeric values for a level or threshold, like verbose and expose, also take true,false,yes,no,y,n,on,off in place of 1 & 0.

###############################################################################
# Main
typeset -a err_msg=() shex=() fhex=() rhex=() ret_dat=() fcb_fname=() fcb_attr=() fcb_size=() fcb_resv=() fcb_head=() fcb_tail=()
typeset -i operation_mode=9 _y= bank= read_err= fdc_err= fdc_dat= fdc_len= _om=99 v=${VERBOSE:-0} FNL lastms= # don't init $FEL
cksum=00 ret_err= ret_fmt= ret_len= ret_sum= tpdd_file_name= file_name= file_attr= d_fname= d_attr= ret_list='|' _s= bd= did_init=false quiet=false g_x= PDD_MAX_FLEN=$PDD1_MAX_FLEN
readonly LANG=C ifs="$IFS"
quiet=true set_mslog
ms_to_s $TTY_READ_TIMEOUT_MS ;read_timeout=${_s}
for x in ${!opr_fmt[*]} ;do [[ $x =~ ^ret_.* ]] && ret_list+="${opr_fmt[$x]}|" ;done
for x in ${!lsl[*]} ;do lsc[${lsl[x]}]=$x ;done ;readonly lsc ;unset x
parse_compat
[[ $0 =~ .*pdd1(\.sh)?$ ]] && set_pdd1
[[ $0 =~ .*pdd2(\.sh)?$ ]] && set_pdd2

# for _sleep()
readonly sleep_fifo="/tmp/.${0//\//_}.${LOGNAME}.sleep.fifo"
[[ -p $sleep_fifo ]] || mkfifo -m 666 "$sleep_fifo" || abrt "Error creating \"$sleep_fifo\""
exec 4<>$sleep_fifo

# tpdd serial port
for PORT in $1 /dev/$1 ;do [[ -c $PORT ]] && break || PORT= ;done
[[ $PORT ]] && shift || get_tpdd_port
vecho 1 "Using port \"$PORT\""
open_com || { e=$? ;printf '%s\n' "${err_msg[*]}" >&2 ;exit $e ; }

# non-interactive mode
(($#)) && { do_cmd "$@" ;exit $? ; }

# interactive mode
while read -p"PDD(${mode[operation_mode]}$bd:$FNL${FEL:+.$FEL},$ATTR)> " __c ;do do_cmd "${__c}" ;done
