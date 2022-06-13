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
Any linux, macos/osx, bsd, any architecture.  

Other unix like SCO, Solaris, etc should work with only minor adjustment (tty device names, stty commandline arguments).

Windows is a [problem](https://github.com/microsoft/WSL/issues/4322) but [may work with effort](https://github.com/dorssel/usbipd-win/wiki/WSL-support).   <!-- (other references: [com2tcp workaround](https://matevarga.github.io/esp32/m5stack/esp-idf/wsl2/2020/05/31/flashing-esp32-under-wsl2.html), [WSL1](https://docs.microsoft.com/en-us/windows/wsl/compare-versions#exceptions-for-using-wsl-1-rather-than-wsl-2), people have also reported that usb-serial ports are usable from WSL2 as long as you simply access the com port from any Windows app first, like putty, just open the port once using any app and then close the app before trying to use it from WSL2. All untested by me.) -->

## Installation
It's just a bash script with no other dependencies, so installation is nothing more than copying, naming, and setting permissions. But there is a "make install" to do it.  
```
git clone git@github.com:bkw777/pdd.sh.git
cd pdd.sh
sudo make install
```

## Usage
First assemble the [hardware](hardware.md)

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
| status | | Report the drive/disk status (basic) |
| D&#160;\|&#160;condition | | Report the drive/disk status (more informative) |
| b&#160;\|&#160;bank | \<0-1\> | (TPDD2 only) Select bank 0 or 1<br>affects list/load/save/del/copy/ren/read_smt |
| ls&#160;\|&#160;list&#160;\|&#160;dir | | Directory listing |
| rm&#160;\|&#160;del | filename | Delete a file |
| cp&#160;\|&#160;copy | src_filename&#160;dest_filename | Copy a file (on-disk to on-disk) |
| mv&#160;\|&#160;ren | src_filename&#160;dest_filename | Rename a file |
| load | disk_filename&#160;\[local_filename\] | Read a file from the disk |
| save | local_filename&#160;\[disk_filename\] | Write a file to the disk |
| format | | Format the disk with "operation-mode" filesystem format |

**TPDD1 Sector Access**  
| command | arguments | Description |
| --- | --- | --- |
| F&#160;\|&#160;ff&#160;\|&#160;fdc_format | \[0-6\] | Format disk with <size_code> sized logical sectors and no "operation-mode" filesystem.<br>size codes: 0=64 1=80 2=128 3=256 4=512 5=1024 6=1280 bytes per logical sector. (default 1280 if not specified) |
| R&#160;\|&#160;rl&#160;\|&#160;read_logical | \[0-79\]&#160;\[1-20\]&#160;\[filename\] | Read one logical sector at address: physical(0-79) logical(1-20). Save to filename if given, else display on screen.<br>default physical 0 logical 1 |
| A&#160;\|&#160;ri&#160;\|&#160;read_id | \[0-79\]&#160;\[filename\] | Read Sector ID Data<br>default physical sector 0 |
| B&#160;\|&#160;wi&#160;\|&#160;write_id | \[0-79\] \<ignored\> 12_hex_pairs... | Write the 12-byte Sector ID data. |
| W&#160;\|&#160;wl&#160;\|&#160;write_logical | \<0-79\>&#160;\<1-20\>&#160;hex_pairs... | Write one logical sector at address: physical(0-79) logical(1-20). |
| rp&#160;\|&#160;read_physical | \[0-79\] \[filename\] | Read all logical sectors in a physical sector<br>default physical sector 0<br>write to filename else display on screen |

**TPDD2 Sector Access**  
| command | arguments | Description |
| --- | --- | --- |
| sector_cache | \<track#&#160;0-79\>&#160;\<sector#&#160;0-1\>&#160;\<mode&#160;0\|2\> | Copy a sector of data between the drive's sector cache & the disk.<br>mode 0 = load from disk to cache<br>mode 2 = flush cache to disk |
| read_cache | \<mode&#160;0\|1\>&#160;\<offset&#160;0-252\>&#160;\<length&#160;0-252\> | Read \<length\> bytes at \<offset\> from the drive's sector cache.<br>mode 0 = normal sector data<br>mode 1 = metadata |
| write_cache | \<mode&#160;0\|1\>&#160;\<offset&#160;0-252\>&#160;\<data...\> | Write \<data...\> at \<offset\> to the drive's sector cache.<br>mode 0 = normal sector data<br>mode 1 = metadata |

**General/Other**  
| command | arguments | Description |
| --- | --- | --- |
| detect_model | | Detects TPDD1 vs TPDD2 connected using the same mystery command as TS-DOS. Sets TPDD1 vs TPDD2 mode based on detection. |
| compat | \[floppy\|wp2\|raw\] | Select the compatibility mode for on-disk filenames format and attribute byte. With no args presents a menu.<br><br>**floppy** : space-padded 6.2 filenames with attr 'F'<br>(default) For working with TRS-80 Model 100, NEC PC-8201a, Olivetti M10, or Kyotronic KC-85.<br>(The dos that came with the TPDD1 was called "Floppy", and all other dos's that came later on that platform had to be compatible with that.)<br><br>**wp2** : space-padded 8.2 filenames with attr 'F'<br>For working with a TANDY WP-2.<br><br>**raw** : 24 byte filenames with attr ' ' (space/0x20)<br>For working with anything else, such as CP/M or Cambridge Z88 or Atari Portfolio (MS-DOS), etc. |
| floppy\|wp2\|raw | | Shortcut for **compat floppy** , **compat wp2** , **compat raw**  |
| names | \[floppy\|wp2\|raw\] | Just the filenames part of **compat**. With no args presents a menu. |
| attr | \[*b*\|*hh*\] | Just the attribute part of **compat**. Takes a single byte, either directly or as a hex pair. With no args presents a menu. |
| 1&#160;\|&#160;pdd1 | | Select TPDD1 mode |
| 2&#160;\|&#160;pdd2 | | Select TPDD2 mode |
| dd&#160;\|&#160;dump_disk | \[filename\] | Read an entire disk, and write to filename or display on screen |
| rd&#160;\|&#160;restore_disk | \<filename\> | Restore an entire disk from filename |
| read_smt | | Read the Space Management Table<br>(for TPDD2, reads the SMT of the currently selected bank) |
| send_loader | \<filename\> | Send a BASIC program to a "Model T".<br>Usually used to install a [TPDD client](thttps://github.com/bkw777/dlplus/tree/master/clients), but can be used to send any ascii text to the client machine. |
| q&#160;\|&#160;quit&#160;\|&#160;bye&#160;\|&#160;exit | | Order Pizza |
| baud&#160;\|&#160;speed | \[9600\|19200\] | Serial port speed. Default is 19200.<br>TPDD1 & TPDD2 run at 19200.<br>FB-100/FDD-19/Purple Computing run at 9600 |
| debug | \[#\] | Debug/Verbose level - Toggle between 0 & 1, or set specified level<br>0 = debug mode off<br>1 = debug mode on<br>\>1 = more verbose |
| pdd1_boot | \[100\|200\] | Emulate a Model 100 or 200 performing the TPDD1 bootstrap procedure.<br>WIP: the collected BASIC is good, the collected binary is not |
| pdd2_boot | \[100\|200\] | Emulate a Model 100 or 200 performing the TPDD2 bootstrap procedure.<br>WIP: the collected BASIC is good, the collected binary is not |

Multiple commands may be given at once, seperated by '**;**' to form a pre-loaded sequence.  

There are also a bunch of low level raw/debugging commands not shown here. See do_cmd() in the script.

Additionally, some behavior may be modified by setting environment variables.
| variable | value | effect |
| --- | --- | --- |
| BAUD | 9600\|19200 | Same as **baud** command above |
| DEBUG | # | same as **debug** command above |
| COMPAT | \[floppy\|wp2\|raw\] | same as **compat** command above |
| TPDD_MODEL | 1\|2 | (default is 1) Assume the attached TPDD drive is a TPDD1 or TPDD2 by default |
| MODEL_DETECTION | true\|false | (default is true) Use the "TS-DOS mystery command" to automatically detect if the attached TPDD drive is a TPDD1 or TPDD2 |

Finally, the name that the script is called by is another way to select between TPDD1 and TPDD2 compatibility. This doesn't really matter since the drive model is automatically detected before any commands that are affected by it. In most cases you can just run "pdd" regardless which type of drive is connected.
```make install``` installs the script as ```/usr/local/bin/pdd```, and also installs 2 symlinks named ```pdd1``` and ```pdd2```.  
Running ```pdd1 some_command``` is equivalent to running ```pdd "1;some_command"```  
Running ```pdd2 some_command``` is equivalent to running ```pdd "2;some_command"```  

## Examples
The same commands can be given either on the command line, or at the interactive prompt.  
Example, to list the directory, where the command is: ```ls```, can be used either of these ways:  
```pdd ls``` or ```TPDD(opr)> ls```

**Load a file from the disk**  
```pdd load DOSNEC.CO```

**Load a file from the disk and save to a different local name**  
```pdd load DOSNEC.CO ts-dos_4.1_nec.co```

**Save a file to the disk**  
```pdd save ts-dos_4.1_nec.co DOSNEC.CO```

**Save a file to the disk with an empty (space, 0x20) attribute flag**  
```pdd save ts-dos_4.1_nec.co DOSNEC.CO ' '```

**Rename a file on a WP-2 disk**  
Notice that the filename format indicator in the prompt changes from 6.2 to 8.2 with the "wp2" command.  
```
PDD(pdd2:6.2(F)> wp2
PDD(pdd2:8.2(F)> mv CAMEL.CO WP2FORTH.CO
```

**Command Lists with ";"**  
Delete File, List Directory
In interactive mode:  
```PDD(opr:6.2(F)> rm DOSNEC.CO ;ls```  
In non-interactive mode, quote the list because of the ";"  
```pdd "rm DOSNEC.CO ;ls"```  
Switch to bank 1 of a TPDD2 disk, Save a file, list directory  
```pdd "bank 1 ;save ts-dos_4.1_nec.co DOSNEC.CO ;ls"```

**Drive/Disk Condition**  
```
$ pdd condition
Disk Inserted, Writable
```

**Verbose/debug mode**  
```DEBUG=1 pdd ...``` or ```PDD(opr:6.2(F)> debug 1```

**More verbose/debug mode**  
```DEBUG=2 pdd ...``` or ```PDD(opr:6.2(F)> debug 2```

**Find out a TPDD1 disk's logical sector size**  
Most disks are formatted with 20 64-byte logical sectors per physical sector, since that's what the operation-mode format function in the firmware does, but there are exceptions. The TPDD1 Utility Disk seems like a normal disk, but it's actually formatted with 1 1280-byte logical sector per physical sector. You need to know this to use some FDC-Mode commands.  
The logical sector size that a disk is formatted with can be seen by running the read_physical, read_logical, or read_id commands on any sector.  
The quickest is to run either ```ri``` or ```rl``` with no arguments:  
```pdd ri``` or ```pdd rl```

**Read the Sector ID Data for all 80 physical sectors (TPDD1)**  
(using bash shell expansion to do something the program doesn't provide itself)  
```pdd ri\ {0..79}\;```

**Dump an entire TPDD disk to a hex dump file**  
The dump/image file format is different for TPDD2 vs TPDD1 (and FB-100/FDD19/Puple-Computing)  
Suggestion: use \*.p1h for image filanames for TPDD1 disks in hex dump format  
and \*.p2h for image filanames for TPDD2 disks in hex dump format  
(There is no binary format currently so all dumps are hex dumps)  
```pdd dd mydisk.p1h```

**Restore an entire TPDD1 disk from a tpdd1 hex dump file**  
**(Re-create the TPDD1 Utility Disk)**  
```pdd rd TPDD1_26-3808_Utility_Disk.p1h```  
[(here is a nice label for it)](https://github.com/bkw777/disk_labels)

**Restore an entire TPDD2 disk from a tpdd2 hex dump file**  
**(Re-create the TPDD2 Utility Disk)**  
```pdd rd TPDD2_26-3814_Utility_Disk.p2h```  
[(here is a nice label for it)](https://github.com/bkw777/disk_labels)

**Explicitly use TPDD1 mode**  
Disables the TPDD1 vs TPDD2 drive detection command normally sent at start-up  
```pdd1 ls```

**Explicitly use TPDD2 mode**  
Disables the TPDD1 vs TPDD2 drive detection command normally sent at start-up  
```pdd2 ls```

## Other Functions
**Send a BASIC loader program to a "Model T"**  
This function is not used with a TPDD drive but with a "Model T" computer like a TRS-80 Model 100, usually to install a TPDD client like TS-DOS, TEENY, or DSKMGR.  
```pdd send_loader TS-DOS.100```  
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
