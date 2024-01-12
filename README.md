# pdd.sh

A [TPDD client](http://tandy.wiki/TPDD_client) implemented in pure\* bash.

It's pure bash except for the following:  
* ```stty``` is needed once at startup to configure the serial port.  
* ```mkfifo``` is used once at startup for ```_sleep()``` without ```/usr/bin/sleep```.  

That's it. There are no other external commands or dependencies, not even any child forks of more bash processes (no backticks, perens, or pipes), and no temp files or here-documents (here-docs create temp files behind the scenes in bash).  
I think the while-loop in help() may create a child bash.

There are a lot of commands and options. This is a swiss army knife for the TPDD.  
It can be used to inspect, copy, restore, repair, or craft TPDD disks in ways that normal client software like TS-DOS or PDD.EXE doesn't provide or allow.

## Particularly Unique Features  
Things this util can do that even the commercial TPDD utils can't do  
 - TPDD2 sector data and sector metadata read & write  
 - Ability to clone "problem" disks, including:  
   - TPDD1 Utility Disk  
   - TPDD2 Utility Disk  
   - Disk-Power Distribution Disk  
   - Sardine Dictionary Disk
 - Ability to create disks from downloadable disk image files, without special hardware other than the drive itself  
 - Work with TPDD disks from/for other platforms like WP-2, CP/M, Z88, Atari Portfolio, etc

## Supported OS's
Any linux, macos/osx, bsd, any cpu architecture.  

Windows... [possibly with effort, but realistically, no](https://github.com/microsoft/WSL/issues/4322).  
Cygwin and MSYS also fail with `stty: /dev/ttyS4: Permission denied`.  
[dl2](http://github.com/bkw777/dl2) does work in both cygwin and msys, so the problem is probably fixable, but I just don't know how yet.

OSX: Requires a newer bash from macports or brew. Does not work with the stock bash that ships with osx/macos (still as of 2023).

## Installation
It's just a bash script with no other dependencies, so installation is nothing more than copying, naming, and setting permissions.  
But there is a "make install" for convenience.  
```
git clone git@github.com:bkw777/pdd.sh.git
cd pdd.sh
sudo make install
```

## Usage
First gather the [hardware](hardware.md)

`pdd [tty_device] [command [args...]] [;commands...]`

**tty_device** will be auto-detected in most cases.  
Failing that, you'll get a list to select from.  
Or you may specify one as the first argument on the command line.  

With no arguments, it will run in interactive command mode.  
You get a `PDD(mode[bank]:names,attr)>` prompt where you can enter commands.  

"help" lists commands and parameters.  
Only the more common commands are shown by default.  
To see all commands, set verbose 1.

The intercative mode prompt indicates various aspects of the current operating state:  
`PDD(mode[bank]:names,attr)>`  
<ul>
  <b>mode</b>: The basic operating mode. Affected by <b>pdd1</b>, <b>pdd2</b>, and <b>detect_model</b>.<br>
    <ul>
    opr = TPDD1 in "Operation-mode" (the normal filesystem/file-access mode of TPDD1)<br>
    fdc = TPDD1 in "FDC-mode" (a seperate command set that TPDD1 has for sector access)<br>
    pdd2 = TPDD2<br>
  </ul>
  <b>[bank]</b>: The currently selected bank, if any. Affected by <b>bank</b>.<br>
    <ul>
    In TPDD1 mode, this field is not included<br>
    In TPDD2 mode, the current bank is shown as [0] or [1]<br>
  </ul>
  <b>names</b>: The format of filenames used to save or load files from the drive. Affected by <b>compat</b> and <b>names</b>.<br>
  <b>attr</b>: The "attribute" byte used to save or load files from the drive. Affected by <b>compat</b> and <b>attr</b>.<br>
</ul>

This pile of commands is not well organized. Sorry.

**TPDD1/TPDD2 File Access**  
| command | arguments | description |
| --- | --- | --- |
| ready&#160;\|&#160;status | | Report the drive & disk ready/not-ready status |
| cnd&#160;\|&#160;condition | | Report combination of bit flags for different not-ready conditions |
| bank | \[0-1\] | (TPDD2 only) Switch to bank 0 or 1. Display current bank.<br>affects list/load/save/delete/copy/rename/read_smt/read_fcb |
| ls&#160;\|&#160;dir&#160;\|&#160;list | | Directory listing |
| rm&#160;\|&#160;del&#160;\|&#160;delete | filename | Delete a file |
| cp&#160;\|&#160;copy | src_filename&#160;dest_filename | Copy a file (on-disk to on-disk) |
| mv&#160;\|&#160;ren | src_filename&#160;dest_filename | Rename a file |
| load | disk_filename&#160;\[local_filename\] | Read a file from the disk |
| save | local_filename&#160;\[disk_filename\] | Write a file to the disk |
| format&#160;\|&#160;mkfs | | Format the disk with filesystem. This format (not FDC format below) is required to create a normal disk that can save & load files. |

**TPDD1-only Sector Access**  
| command | arguments | Description |
| --- | --- | --- |
| ff&#160;\|&#160;fdc_format | \[0-6\] | Format disk with <size_code> sized logical sectors and no "operation-mode" filesystem.<br>size codes: 0=64 1=80 2=128 3=256 4=512 5=1024 6=1280 bytes per logical sector (default 3). This format does not create a filesystem disk. It just allows reading/writing sectors. |
| si&#160;\|&#160;search_id | 0-12_hex_pairs... | Search all Sector IDs for an exact match. |
| wi&#160;\|&#160;write_id | \[0-79\] 12_hex_pairs... | Write the 12-byte Sector ID data. |
| rl&#160;\|&#160;read_logical | \[0-79\]&#160;\[1-20\] | Read one logical sector at address: physical(0-79) logical(1-20). Default physical 0 logical 1 |
| wl&#160;\|&#160;write_logical | \<0-79\>&#160;\<1-20\>&#160;hex_pairs... | Write one logical sector at address: physical(0-79) logical(1-20). |

**TPDD2-only Sector Access**  
| command | arguments | Description |
| --- | --- | --- |
| cache_load | \<track#&#160;0-79\>&#160;\<sector#&#160;0-1\>&#160;\<mode&#160;0\|2\> | Copy a sector of data between the drive's sector cache (ram) & the disk (media).<br>mode 0 = load from disk to cache<br>mode 2 = commit cache to disk |
| cache_read | \<mode&#160;0-1\>&#160;\<offset&#160;0-1279\>&#160;\<length&#160;0-252\> | Read \<length\> bytes at \<offset\> from the drive's sector cache.<br>mode 0 = main data, 1 = metadata |
| cache_write | \<mode&#160;0-1\>&#160;\<offset&#160;0-1279\>&#160;\<data&#160;0-127&#160;hex&#160;pairs...\> | Write \<data...\> at \<offset\> to the drive's sector cache.<br>mode: 0 = main data, 1 = metadata |

**TPDD1/TPDD2 Sector Access**  
| command | arguments | Description |
| --- | --- | --- |
| rh&#160;\|&#160;read_header | \[0-79\]&#160;\|&#160;\[0-79,0-1\]&#160;\|&#160;all | Read the TPDD1 Sector ID Data or TPDD2 metadata field<br>default physical sector 0<br>"all" reads the header from every sector.<br>For TPDD2 the argument may be either "track,sector" (0-79,0-1) or a single linear sector number 0-159. |
| rs&#160;\|&#160;read_sector | \[0-79\] or \[0-79 0-1\] | Read one full 1280-byte sector. For TPDD1 this is one "physical sector", meaning all logical sectors. For TPDD2 there are no logical sectors and this is just a "sector".<br>For TPDD1 the argument is a single physical sector number 0-79<br>For TPDD2 the arguments are track number 0-79 and sector number 0-1 |
| dd&#160;\|&#160;dump_disk | \[filename\] | Read an entire disk, and write to filename or display on screen |
| rd&#160;\|&#160;restore_disk | \<filename\> | Restore an entire disk from filename |
| fcb&#160;\|&#160;read_fcb | | Display the File Control Block list - the underlying data that dirent() uses for the directory list |
| smt&#160;\|&#160;read_smt | | Display the Space Management Table |

**Other**  
| command | arguments | Description |
| --- | --- | --- |
| ?&#160;\|&#160;h&#160;\|&#160;help | \[command\] | show help |
| pdd1 | | Select TPDD1 mode |
| pdd2 | | Select TPDD2 mode |
| version&#160;\|&#160;detect_model | | TPDD2 "Get System Version" command.<br>Also used internaly to detect whether TPDD1 vs TPDD2 is connected.<br>TS-DOS also uses this to detect TPDD2. |
| sysinfo | | TPDD2 "Get System Information" command. |
| opr&#160;\|&#160;fdc | | Switch to Operation or FDC mode (TPDD1 only) |
| compat | \[floppy\|wp2\|raw\] | Select the compatibility mode for on-disk filenames format and attribute byte. With no args presents a menu.<br><br>**floppy** : space-padded 6.2 filenames with attr 'F'<br>(default) For working with TRS-80 Model 100, NEC PC-8201a, Olivetti M10, or Kyotronic KC-85.<br>(The dos that came with the TPDD1 was called "Floppy", and all other dos's that came later on that platform had to be compatible with that.)<br><br>**wp2** : space-padded 8.2 filenames with attr 'F'<br>For working with a TANDY WP-2.<br><br>**raw** : 24 byte filenames with attr ' ' (space/0x20)<br>For working with anything else, such as CP/M or Cambridge Z88 or Atari Portfolio (MS-DOS), etc. |
| floppy&#160;\|&#160;wp2\|&#160;raw | | Shortcut for **compat floppy** , **compat wp2** , **compat raw**  |
| attr | \[*b*\|*hh*\] | Just the attribute part of **compat**. Takes a single byte, either directly or as a hex pair. With no args presents a menu. |
| eb&#160;\|&#160;expose&#160;\|&#160;expose_binary | 0\|1\|2 | Expose non-printable binary bytes in filenames. Default 1. (see the tpdd2 util disk for an example)<br>0 = off<br>1 = Bytes 00-1F displayed as "@" to "_" in reverse video<br>(the same as their respective ctrl keys, but in reverse video instead of ^carot notation),<br>Bytes 7F-FF displayed as "." in reverse-video<br>This mode exposes all non-printing bytes without altering the display formatting, because every byte is displayed as a single character cell, but the bytes over 126 are not individually identified as to what specific value they are.<br>2 = all non-printing bytes displayed as inverse video 00 to 1F and 7F to FF<br>This mode exposes all bytes and shows their actual value, but requires 2 character spaces per byte, which messes up the display formatting. |
| ffs&#160;\|&#160;ffsize&#160;\|&#160;fcb_fsize | true\|false | Show true file sizes by making ocmd_dirent() read the FCB table instead of using the inaccurate file sizes that the drive firmware Directory Entry command returns.<br>Default off. Affects **ls** and **load**<br>Works on real drives but does not work on most drive emulators, because reading the FCB table is a raw sector access operation that most tpdd servers don't implement. |
| baud&#160;\|&#160;speed | \[9600\|19200\] | Serial port speed. Default is 19200.<br>Drives with dip-switches can actually be set for any of 150 300 600 1200 2400 4800 9600 19200 38400 76800<br>and you can actually set any of those speeds if you set the drive dip switches to match.<br>Some Brother/KnitKing drives are hardwired to 9600 with a solder bridge in place of the dip-switches. |
| com_test | | check if port open |
| com_show | | show port status |
| com_open | | open the port |
| com_close | | close the port |
| com_read | \[#\] | read bytes from port - read # bytes if given, or until end of data<br>this is really just a wrapper for an internal low level function so you can do manual hacking.<br>The received bytes just get stored as hex pairs in rhex\[\]<br>You'll need to set verbose 2 or 3 to see them. |
| com_write | hex_pairs... | write bytes to port - for each hex pair, write the corresponding byte to the port |
| read_fdc_ret | | read an fdc-mode return msg from the port and parse it |
| read_opr_ret | | read an opr-mode return msg from the port and parse it |
| send_opr_req | fmt data... | build a valid operation-mode request block and send it to the tpdd<br>fmt = single hex pair for the request format (the command)<br>data... = 0 to 128 hex pairs for the payload data<br>The ZZ preamble, LEN field, and trailing checksum are all calculated and added automatically |
| check_opr_err | | check ret_dat\[\] for an opr-mode error code  |
| drain | | flush the port receive buffer |
| checksum | \<hex pairs...\> | calculate the checksum for the bytes represented by the given hex pairs |
| v&#160;\|&#160;verbose&#160;\|&#160;debug | \[#\] | Verbose/Debug level. Default 0. 1 or greater = more verbose.<br>Verbose levels above 0 also exposes more commands in help. |
| bootstrap&#160;\|&#160;send_loader | \<filename\> | Send a BASIC program to a "Model T".<br>Usually used to install a [TPDD client](thttps://github.com/bkw777/dlplus/tree/master/clients), but can be used to send any ascii text to the client machine. |
| pdd1_boot | \[100\|200\] | Emulate a Model 100 or 200 performing the TPDD1 bootstrap procedure.<br>WIP: the collected BASIC is good, the collected binary is not |
| pdd2_boot | \[100\|200\] | Emulate a Model 100 or 200 performing the TPDD2 bootstrap procedure.<br>WIP: the collected BASIC is good, the collected binary is not |
| ll | | List the files in the current local working directory (not on the disk). Like "ls" but doesn't run /bin/ls. |
| lls | | **ll** with filesizes added. |
| q&#160;\|&#160;quit&#160;\|&#160;bye&#160;\|&#160;exit | | Order Pizza |

There are even more commands that are mostly low level hacky suff.  
Set verbose 1 and then run help to see everything.

Additionally, some behavior may be modified by setting environment variables.
| variable | value | effect |
| --- | --- | --- |
| BAUD | 9600\|19200 | Same as **baud** command above |
| RTSCTS | true\|false | same as **rtscts** command above |
| VERBOSE | # | same as **verbose** command above |
| COMPAT | \[floppy\|wp2\|raw\] | same as **compat** command above |
| EXPOSE_BINARY | 0\|1\|2 | same as **expose** command above |
| FCB_FSIZE | true\|false | same as **ffsize** command above |
| FONZIE_SMACK | true\|false | (default true) TPDD1 only. Do (or don't do) an fdc-to-opr command to try to joggle the drive from an unknown/out-of-sync state to a known/in-sync state during \_init() |
| WITH_VERIFY | true\|false | (default true) TPDD1 only. Use the with-verify or the without-verify versions of fdc_format, write_logical, & write_id. |
| YES | true\|false | (default false) Assume "yes" for all confirmation prompts, for scripting. |

Finally, the name that the script is called by is another way to select between TPDD1 and TPDD2 compatibility.  
`make install` installs the script as `/usr/local/bin/pdd`, and also installs 2 symlinks named `pdd1` and `pdd2`.  
This isn't usually needed, since the drive model is automatically detected in most cases.
In most cases you can just run "pdd" regardless which type of drive is connected.

Commands may be issued either interactively at the `PDD(...)>` prompt,
or non-interactively on the command line.

Example, to list the directory, the command is `ls`.  

Interactive:  
```
bkw@fw:~$ pdd
PDD(opr:6.2,F)> ls
--------  Directory Listing  --------
Floppy_SYS               | F |  11475
SETRAM.BA                | F |    208
-------------------------------------
88320 bytes free                 [WP]
PDD(opr:6.2,F)> q
bkw@fw:~$ 
```

Non-Interactive:  
```
bkw@fw:~$ pdd ls
--------  Directory Listing  --------
Floppy_SYS               | F |  11475
SETRAM.BA                | F |    208
-------------------------------------
88320 bytes free                 [WP]
bkw@fw:~$ 
```

Multiple commands may be given at once, seperated by `;` to form a pre-loaded sequence.  
(directoy listing ; enable FCB file lengths ; directory listing)  
```
bkw@fw:~$ pdd
PDD(opr:6.2,F)> ls ;ffs 1;ls
--------  Directory Listing  --------
Floppy_SYS               | F |  11475
SETRAM.BA                | F |    208
-------------------------------------
88320 bytes free                 [WP]
Use FCBs for true file sizes: true
--------  Directory Listing  --------
Floppy_SYS               | F |  11520
SETRAM.BA                | F |    208
-------------------------------------
88320 bytes free                 [WP]
PDD(opr:6.2,F)> q
bkw@fw:~$ 
```

If using `;` on the command line, they need to be escaped or quoted.
`$ pdd "ls ;ffs 1;ls"`

## Eamples for some individual commands

### Load a file from the disk
`load DOSNEC.CO`

give the file a better destination filename locally  
`load DOSNEC.CO ts-dos_4.1_nec.co`

### Save a file to the disk  
`save nec_ts-dos_4.1.co`

That would automatically truncate the destination name to "nec_ts.co"   
But you probably need that to be named "DOSNEC.CO" on the disk in order for Ultimate ROM II to recognize it.  
`save ts-dos_4.1_nec.co DOSNEC.CO`

### Specify an arbitrary attribute byte
"Floppy" and all other TPDD client software for TRS-80 Model 100 and clones (TS-DOS, TEENY, etc) all hard-code the value 'F' for attribute for all files every time in all cases. Meaning they always write "F" when writing a file and always ask for "F" when reading a file, essentially NO-OPing the field, and don't expose the field to the user in any way. You don't see it in directory listings on a 100, and you can't supply some other value to write or search.

But the field is there, and the drive doesn't care what's in it except that your commands must match the disk the same as for the filename, and other platforms may use the field in other ways.

pdd.sh uses 'F' by default also for convenience, but in our case it's only a default, and there are a few different ways to change or override that.  
One way is to supply a 3rd argument to the `save` command.  
This example could be for a Cambridge Z88, give a quote-space-quote for the 3rd arg to explicitly specify a space character for the attribute byte:  
`save Romcombiner.zip Romcombiner.zip ' '`  

Or change the current default `ATTR` value by using the `attr` command.

### Rename a file on a WP-2 disk
Notice also that the filename format indicator in the prompt changed from 6.2 to 8.2 after the `wp2` command.  
```
PDD(pdd2:6.2(F)> wp2
PDD(pdd2:8.2(F)> mv CAMEL.CO WP2FORTH.CO
```

### Drive/Disk Condition
```
$ pdd condition
Disk Changed
Disk Write-Protected
```

### Verbose/debug mode
`$ VERBOSE=1 pdd ...`  
or  
`PDD(opr:6.2(F)> v 1`

### More verbose/debug mode
`$ VERBOSE=2 pdd ...`  
or  
`PDD(opr:6.2(F)> v 2`

### Dump an entire disk to a disk image file
`dd mydisk`

Reads the disk in the drive and creates `midisk.pdd1` or `mydisk.pdd2` depending on what kind of drive is connected.

The disk images are the same format as used by [dl2](https://github.com/bkw777/dl2)

### Restore an entire disk from a disk image file
`rd mydisk.pdd1`  
or  
`rd mydisk.pdd2`

There are disk images for the original TPDD1 and TPDD2 utility disks in the disk_images folder, and [this repo](https://github.com/bkw777/disk_labels) has nice labels for them that you can print.  
The Sardine dictionary disk is also in there.

### Directory Listings

* The drive firmwares directory listing function returns file sizes that are often smaller than reality by several bytes. The correct filesizes are available on the disk in the FCB table. The `fcb_flens` setting, not enabled by default, makes the "dirent()" function read the FCB to get filesizes. This makes `ls` and `load` take an extra second or two to get the FCB data, but displays the correct exact filesizes. This can be turned on/off with the `ffs` command. This only works on real drives. This can't be used with TPDD emulators because this requires using sector-access commands to read sector 0 from the disk. Emulators don't have any actual sector 0 and don't support the sector-access commands, but TPDD emulators also don't report the wrong file sizes in their dirent() responses, and so you don't need any better value in that case anyway. (dlplus is a TPDD emulator and does support raw sector access to disk image files, but this doesn't apply to ordinary files shared from a directory)

* Filenames can have non-printing characters in them. The `expose` option, enabled by default, exposes those bytes in filenames (and in the attr field). When a byte in a filename has an ascii value of 0-32, it's displayed as the assosciated ctrl code, but in inverse video instead of carot notation so that the character only takes up one space. Bytes with ascii values above 126 are all displayed as just inverse ".". ex: null is ^@, and is displayed as inverse video "@". The TPDD2 Utility Disk has a 0x01 byte at the beginning of the `FLOPY2.SYS` filename. Normally that is invisible, (except for the fact that it makes the filename field look one character too short). The `expose` option exposes that hidden byte in the name. This can be toggled with the `expose` command.  

* The write-protect status of the disk is indicated in the bottom-right corner of the listing with a `[WP]`if the disk is write-protected.

## Non-Standard DIP Switch Settings
Here is an example to use the FDC-mode 38400 baud DIP switch setting on a TPDD1 or Purple Computing drive.  
The dip switches not only change the baud rate but also make the drive default to FDC-mode instead of Operation-mode at power-on.  
pdd.sh switches the drive to Operation-mode automatically regardless what mode the drive starts out in, so the only thing we have to do differently is tell it the baud rate is not the default 19200.  
* Turn the drive power OFF  
* Set the DIP switches on the bottom of the drive to `1:OFF 2:OFF 3:ON 4:OFF` ([reference](https://archive.org/details/tandy-service-manual-26-3808-s-software-manual-for-portable-disk-drive/page/14/mode/1up))  
* Turn the drive power ON  
* Run: `$ BAUD=38400 pdd`

Now use the drive as normal.  
It's not really any faster. The point was just to support all dip switch settings since they exist. And that means getting \_init() working well enough that the app works regardless if the drive is a tpdd1 starting in Operation-mode, a tpdd1 starting in FDC-mode, or a tpdd2. First fonzie_smack() makes sure that we are either a tpdd2, or a tpdd1 in Oeration mode. Then pdd2_version() detects if the drive is a tpdd1 or tpdd2. At that point we have the drive in a known state and can send commands to it without locking it up.

## Other Functions
**Send a BASIC loader program to a "Model T"**  
This function is not used with a TPDD drive but with a "Model T" computer like a TRS-80 Model 100, usually to install a TPDD client like TS-DOS, TEENY, or DSKMGR.  
```pdd bootstrap TS-DOS.100```  
You can find a collection of TPDD client loaders at https://github.com/bkw777/dlplus/tree/master/clients

# References
http://tandy.wiki/TPDD  
https://archive.org/details/TandyPortableDiskDriveSoftwareManual26-3808s/ ([Local copy](https://docs.google.com/viewer?url=https://github.com/bkw777/pdd.sh/raw/main/Tandy_Portable_Disk_Drive_Software_Manual_26-3808S.pdf))  
https://archive.org/details/tpdd-2-service-manual  
https://github.com/bkw777/dlplus/blob/master/ref/search_id_section.txt  
http://www.bitchin100.com/wiki/index.php?title=Base_Protocol  
http://www.bitchin100.com/wiki/index.php?title=Desklink/TS-DOS_Directory_Access  
http://www.bitchin100.com/wiki/index.php?title=TPDD-2_Sector_Access_Protocol  
https://www.ordersomewherechaos.com/rosso/fetish/m102/web100/docs/pdd2-sector-0.html  
https://www.ordersomewherechaos.com/rosso/fetish/m102/web100/docs/pdd-sector-access.html  
https://trs80stuff.net/tpdd/tpdd2_boot_disk_backup_log_hex.txt  
https://github.com/bkw777/dlplus  
