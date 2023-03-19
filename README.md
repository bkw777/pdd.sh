# pdd.sh

A [TPDD client](http://tandy.wiki/TPDD_client) implemented in pure\* bash.

It's pure bash except for the following:  
* ```stty``` is needed once at startup to configure the serial port.  
* ```mkfifo``` is used once at startup for ```_sleep()``` without ```/usr/bin/sleep```.  

That's it. There are no other external commands or dependencies, not even any child forks (no backticks or pipes).

There are a lot of commands and options. This is a swiss army knife for the TPDD.  
It can be used to inspect, copy, restore, repair, or craft TPDD disks in ways that normal client software like TS-DOS or PDD.EXE doesn't provide or allow.

## Particularly Unique Features  
Things this util can do that not even the commercial TPDD utils can do  
 - TPDD2 sector data and sector metadata read & write
 - Ability to clone "problem" disks, including:  
   - TPDD1 Utility Disk
   - TPDD2 Utility Disk
   - Disk-Power Distribution Disk
 - Ability to create disks from downloadable disk image files  
   - ...and do so without special hardware other than the drive itself (no kryoflux or the like needed, nor a MS-DOS machine old enough to have the right kind of floppy controller, nor a hard-to-find 720K 3.5" drive)  
 - Work with disks/files formatted for other clients than the KC-85 platform clones

## Supported OS's
Any linux, macos/osx, bsd, any cpu architecture.  

Windows... [with effort, but realistically, no](https://github.com/microsoft/WSL/issues/4322).  
Cygwin and MSYS also fail with ```stty: /dev/ttyS4: Permission denied```.  
http://github.com/bkw777/dlplus works in both cygwin and msys, so the problem is probably fixable, but I just don't know how yet.

OSX: Requires bash from macports or brew. Doesn't work with the stock bash that ships with osx.

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

```pdd [tty_device] [command [args...]] [;commands...]```

**tty_device** will be auto-detected in most cases.  
Failing that, you'll get a list to select from.  
Or you may specify one as the first argument on the command line.  

With no arguments, it will run in interactive command mode.  
You get a ```PDD(mode[bank]:names,attr)>``` prompt where you can enter commands.  
"help" is still not one of them, Sorry.

The intercative mode prompt indicates various aspects of the current operating state:  
```PDD(mode[bank]:names,attr)>```  
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

**TPDD1/TPDD2 File Access**  
| command | arguments | description |
| --- | --- | --- |
| ready&#160;\|&#160;status | | Report the drive & disk ready/not-ready status  |
| D&#160;\|&#160;condition&#160;\|&#160;cond | | Report combination of bit flags for different not-ready conditions |
| b&#160;\|&#160;bank | \<0-1\> | (TPDD2 only) Select bank 0 or 1<br>affects list/load/save/del/copy/ren/read_smt/read_fcb |
| ls&#160;\|&#160;list&#160;\|&#160;dir | | Directory listing |
| rm&#160;\|&#160;del | filename | Delete a file |
| cp&#160;\|&#160;copy | src_filename&#160;dest_filename | Copy a file (on-disk to on-disk) |
| mv&#160;\|&#160;ren | src_filename&#160;dest_filename | Rename a file |
| load | disk_filename&#160;\[local_filename\] | Read a file from the disk |
| save | local_filename&#160;\[disk_filename\] | Write a file to the disk |
| format&#160;\|&#160;mkfs | | Format the disk with filesystem. This format (not FDC format below) is required to create a normal disk that can save & load files. |

**TPDD1-only Sector Access**  
| command | arguments | Description |
| --- | --- | --- |
| F&#160;\|&#160;ff&#160;\|&#160;fdc_format | \[0-6\] | Format disk with <size_code> sized logical sectors and no "operation-mode" filesystem.<br>size codes: 0=64 1=80 2=128 3=256 4=512 5=1024 6=1280 bytes per logical sector (default 3). This format does not create a filesystem disk. It just allows reading/writing sectors. |
| B&#160;\|&#160;wi&#160;\|&#160;write_id | \[0-79\] 12_hex_pairs... | Write the 12-byte Sector ID data. |
| R&#160;\|&#160;rl&#160;\|&#160;read_logical | \[0-79\]&#160;\[1-20\] | Read one logical sector at address: physical(0-79) logical(1-20). Default physical 0 logical 1 |
| W&#160;\|&#160;wl&#160;\|&#160;write_logical | \<0-79\>&#160;\<1-20\>&#160;hex_pairs... | Write one logical sector at address: physical(0-79) logical(1-20). |

**TPDD2-only Sector Access**  
| command | arguments | Description |
| --- | --- | --- |
| cache_load | \<track#&#160;0-79\>&#160;\<sector#&#160;0-1\>&#160;\<mode&#160;0\|2\> | Copy a sector of data between the drive's sector cache & the disk.<br>mode 0 = load from disk to cache<br>mode 2 = unload cache to disk |
| cache_read | \<mode&#160;0-1\>&#160;\<offset&#160;0-1279\>&#160;\<length&#160;0-252\> | Read \<length\> bytes at \<offset\> from the drive's sector cache.<br>mode 0 = main data, 1 = metadata |
| cache_write | \<mode&#160;0-1\>&#160;\<offset&#160;0-1279\>&#160;\<data&#160;0-127&#160;hex&#160;pairs...\> | Write \<data...\> at \<offset\> to the drive's sector cache.<br>mode: 0 = main data, 1 = metadata |

**TPDD1/TPDD2 Sector Access**  
| command | arguments | Description |
| --- | --- | --- |
| A&#160;\|&#160;ri&#160;\|&#160;read_id | \[0-79\]&#160;\|&#160;\[0-79,0-1\]&#160;\|&#160;all | Read the TPDD1 Sector ID Data or TPDD2 metadata field<br>default physical sector 0<br>"all" reads the ID/metadata field from every sector.<br>For TPDD2 the argument may be either track,sector (0-79,0-1) or a single linear sector number 0-159. |
| rs&#160;\|&#160;read_sector | \[0-79\] or \[0-79 0-1\] | Read one full 1280-byte sector. For TPDD1 this is one "physical sector". For TPDD2 there are no logical sectors and this is just a "sector".<br>For TPDD1 the argument is a single sector number 0-79<br>For TPDD2 the arguments are track number 0-79 and sector number 0-1 |
| dd&#160;\|&#160;dump_disk | \[filename\] | Read an entire disk, and write to filename or display on screen |
| rd&#160;\|&#160;restore_disk | \<filename\> | Restore an entire disk from filename |
| read_fcb&#160;\|&#160;fcb | | Display the File Control Block list - the underlying data that dirent() uses for the directory list |
| read_smt&#160;\|&#160;smt | | Display the Space Management Table |

**Other**  
| command | arguments | Description |
| --- | --- | --- |
| 1&#160;\|&#160;pdd1 | | Select TPDD1 mode |
| 2&#160;\|&#160;pdd2 | | Select TPDD2 mode |
| model&#160;\|&#160;detect&#160;\|&#160;detect_model | | Detects TPDD1 vs TPDD2 connected using the same mystery command as TS-DOS. Sets TPDD1 vs TPDD2 mode based on detection. |
| opr&#160;\|&#160;fdc | | Switch to Operation or FDC mode (TPDD1 only) |
| compat | \[floppy\|wp2\|raw\] | Select the compatibility mode for on-disk filenames format and attribute byte. With no args presents a menu.<br><br>**floppy** : space-padded 6.2 filenames with attr 'F'<br>(default) For working with TRS-80 Model 100, NEC PC-8201a, Olivetti M10, or Kyotronic KC-85.<br>(The dos that came with the TPDD1 was called "Floppy", and all other dos's that came later on that platform had to be compatible with that.)<br><br>**wp2** : space-padded 8.2 filenames with attr 'F'<br>For working with a TANDY WP-2.<br><br>**raw** : 24 byte filenames with attr ' ' (space/0x20)<br>For working with anything else, such as CP/M or Cambridge Z88 or Atari Portfolio (MS-DOS), etc. |
| floppy\|wp2\|raw | | Shortcut for **compat floppy** , **compat wp2** , **compat raw**  |
| names | \[floppy\|wp2\|raw\] | Just the filenames part of **compat**. With no args presents a menu. |
| attr | \[*b*\|*hh*\] | Just the attribute part of **compat**. Takes a single byte, either directly or as a hex pair. With no args presents a menu. |
| ffs&#160;\|&#160;fcb_filesizes | true\|false\|on\|off | Show accurate file sizes by making ocmd_dirent() always read the FCBs instead of taking the inaccurate file size that the drive firmware dirent() provides.<br>Default off. Affects **ls** and **load**<br>Works on real drives but does not work on most drive emulators, because reading the FCB is a sector access operation that most tpdd servers don't implement. |
| send_loader&#160;\|&#160;bootstrap | \<filename\> | Send a BASIC program to a "Model T".<br>Usually used to install a [TPDD client](thttps://github.com/bkw777/dlplus/tree/master/clients), but can be used to send any ascii text to the client machine. |
| baud&#160;\|&#160;speed | \[9600\|19200\] | Serial port speed. Default is 19200.<br>TPDD1 & TPDD2 run at 19200.<br>FB-100/FDD-19/Purple Computing run at 9600 |
| debug&#160;\|&#160;v | \[#\] | Debug/Verbose level - With no arguments toggles on/off (0/1), or set specified level<br>0 = verbose off<br>1 = verbose level 1<br>2+ = more verbose |
| pdd1_boot | \[100\|200\] | Emulate a Model 100 or 200 performing the TPDD1 bootstrap procedure.<br>WIP: the collected BASIC is good, the collected binary is not |
| pdd2_boot | \[100\|200\] | Emulate a Model 100 or 200 performing the TPDD2 bootstrap procedure.<br>WIP: the collected BASIC is good, the collected binary is not |
| expose | | Expose non-printable bytes in filenames. Default on. (see the tpdd2 util disk) |
| q&#160;\|&#160;quit&#160;\|&#160;bye&#160;\|&#160;exit | | Order Pizza |

There are also a bunch of low level raw/debugging commands not shown here. See do_cmd() in the script.

Additionally, some behavior may be modified by setting environment variables.
| variable | value | effect |
| --- | --- | --- |
| BAUD | 9600\|19200 | Same as **baud** command above |
| RTSCTS | true\|false | same as **rtscts** command above |
| DEBUG | # | same as **debug** command above |
| COMPAT | \[floppy\|wp2\|raw\] | same as **compat** command above |
| TPDD_MODEL | 1\|2 | (default 1) Assume the attached TPDD drive is a TPDD1 or TPDD2 by default |
| EXPOSE | 0\|1\|2 | same as **expose** command above |
| USE_FCB | true\|false | same as **ffs** command above |
| MODEL_DETECTION | true\|false | (default true) Use the "TS-DOS mystery command" to automatically detect if the attached TPDD drive is a TPDD1 or TPDD2 | 
| FONZIE_SMACK | true\|false | (default true) During \_init(), do (or don't) do the fdc-opr-fdc-opr flip-flop to try to joggle the drive from an unknown/out-of-sync state to a known/in-sync state. |

Finally, the name that the script is called by is another way to select between TPDD1 and TPDD2 compatibility. This doesn't really matter since the drive model is automatically detected before any commands that are affected by it. In most cases you can just run "pdd" regardless which type of drive is connected.
```make install``` installs the script as ```/usr/local/bin/pdd```, and also installs 2 symlinks named ```pdd1``` and ```pdd2```.  
Running ```pdd1 some_command``` is equivalent to running ```pdd "1;some_command"```  
Running ```pdd2 some_command``` is equivalent to running ```pdd "2;some_command"```  

## Examples
The same commands can be given either on the command line, or at the interactive prompt.  
Example, to list the directory, where the command is: ```ls```, can be used either of these ways:  
```$ pdd ls``` or ```PDD(pdd2:6.2(F)> ls```

Multiple commands may be given at once, seperated by '**;**' to form a pre-loaded sequence.  

**Load a file from the disk**  
```load DOSNEC.CO```

**Load a file from the disk and save to a different local name**  
```load DOSNEC.CO ts-dos_4.1_nec.co```

**Save a file to the disk**  
```save ts-dos_4.1_nec.co DOSNEC.CO```

**Save a file to the disk with an empty (space, 0x20) attribute flag**  
```save ts-dos_4.1_nec.co DOSNEC.CO ' '```

**Rename a file on a WP-2 disk**  
Notice that the filename format indicator in the prompt changes from 6.2 to 8.2 with the "wp2" command.  
```
PDD(pdd2:6.2(F)> wp2
PDD(pdd2:8.2(F)> mv CAMEL.CO WP2FORTH.CO
```

**Command Lists with ";"**  
Delete File, then List Directory
In interactive mode:  
```PDD(opr:6.2(F)> rm DOSNEC.CO ;ls```  
In non-interactive mode, quote the list because of the ";"  
```$ pdd "rm DOSNEC.CO ;ls"```  
Switch to bank 1 of a TPDD2 disk, Save a file, list directory  
```$ pdd "bank 1 ;save ts-dos_4.1_nec.co DOSNEC.CO ;ls"```

**Drive/Disk Condition**  
```
$ pdd condition
Disk Changed
Disk Write-Protected
```

**Verbose/debug mode**  
```$ DEBUG=1 pdd ...``` or ```PDD(opr:6.2(F)> v 1```

**More verbose/debug mode**  
```$ DEBUG=2 pdd ...``` or ```PDD(opr:6.2(F)> v 2```

**Dump an entire TPDD disk to a disk image file**  
The file format is different for TPDD2 vs TPDD1  
TPDD1 images files have a .pdd1 extension, TPDD2 image files have .pdd2
If you don't specify the extension, the drive model is detected and the
right one added.
```dd mydisk```
Creates `midisk.pdd1` or `mydisk.pdd2`

**Restore an entire disk from a disk image file**  
pdd.sh now reads and writes a binary disk image file format, and it's the same
format as what dlplus uses. You can use pdd.sh to dump a real disk to a file,
and then use that file with dlplus. Or you can re-create a real disk from
a downloadable file.

**TPDD1 Utility Disk**  
```rd disk_images/TPDD1_26-3808_Utility_Disk.pdd1```  
[(here is a nice label for it)](https://github.com/bkw777/disk_labels)  

**TPDD2 Utility Disk**  
```rd disk_images/TPDD2_26-3814_Utility_Disk.pdd2```  
[(here is a nice label for it)](https://github.com/bkw777/disk_labels)

Also included is a disk image of the American English dictionary disk for Sardine.  
```rd disk_images/Sardine_American_English.pdd1```

**Directory Listing**  
* The drive firmware's directory listing function returns file sizes that are often off by several bytes. The correct filesizes are available on the disk in the FCB. There is a setting, enabled by default, that makes the pdd.sh's dirent() function read the FCB to get filesizes. This makes directory listings and open-file-for-read take an extra second every time, but the displays the correct exact filesizes. This can be turned on/off with the **ffs** command.  
* Filenames can have non-printing characters in them. There is an option, enabled by default, to expose things like that in filenames (and the attr bytes). When a byte in a filename has an ascii value less than 32, it's displayed as the ctrl code that produces that byte, in inverse video. Bytes with ascii values above 126 are all displayed as just inverse "+". ex: null is ^@ or Ctrl+@, and is displayed as inverse video "@". The TPDD2 Utility Disk has a 0x01 byte at the beginning of the `FLOPY2.SYS` filename. Normally that is invisible, except it makes the filename field look one character too short. The expose option exposes that hidden byte in the name. This can be toggled with the **expose** command.   
* The write-protect status of the disk is indicated in the bottom-right corner of the listing with a [WP] if the disk is write-protected.

## Other Functions
**Send a BASIC loader program to a "Model T"**  
This function is not used with a TPDD drive but with a "Model T" computer like a TRS-80 Model 100, usually to install a TPDD client like TS-DOS, TEENY, or DSKMGR.  
```pdd bootstrap TS-DOS.100```  
You can find a collection of TPDD client loaders at https://github.com/bkw777/dlplus/tree/master/clients

# References
http://tandy.wiki/TPDD  
https://archive.org/details/TandyPortableDiskDriveSoftwareManual26-3808s/ ([Local copy](https://docs.google.com/viewer?url=https://github.com/bkw777/pdd.sh/raw/main/Tandy_Portable_Disk_Drive_Software_Manual_26-3808S.pdf))  
http://www.bitchin100.com/wiki/index.php?title=Base_Protocol  
http://www.bitchin100.com/wiki/index.php?title=Desklink/TS-DOS_Directory_Access  
http://www.bitchin100.com/wiki/index.php?title=TPDD-2_Sector_Access_Protocol  
https://www.ordersomewherechaos.com/rosso/fetish/m102/web100/docs/pdd2-sector-0.html  
https://www.ordersomewherechaos.com/rosso/fetish/m102/web100/docs/pdd-sector-access.html  
https://trs80stuff.net/tpdd/tpdd2_boot_disk_backup_log_hex.txt  
https://github.com/bkw777/dlplus  
