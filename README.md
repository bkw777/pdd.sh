# pdd.sh

A [TPDD client](http://tandy.wiki/TPDD_client) implemented in pure\* bash.

It's pure bash except for the following:  
* "stty" is needed once at startup to configure the serial port.  
* "mkfifo" is used once at startup for _sleep() without /usr/bin/sleep .  

That's it. There are no other external commands or dependencies, not even any child forks (no backticks or pipes).

## Installation
```sudo make install```

## Usage
```pdd [tty_device] [command [args...]] [;commands...]```

With no arguments, it will run in interactive command mode.  
You get a ```TPDD($mode)>``` prompt where you can enter commands.  
"help" is still not one of them ;) Sorry.

**tty_device** will be auto-detected in most cases.  
Failing that, you'll get a list to select from.  
Or you may specify one as the first argument on the command line.  

There are two groups of commands, "operation mode" and "FDC mode".  

**"operation mode" commands**  
| command | arguments | description |
| --- | --- | --- |
| status | | Report the drive/disk status |
| ls&#160;\|&#160;list&#160;\|&#160;dir | | Directory listing |
| rm&#160;\|&#160;del | filename | Delete a file |
| cp&#160;\|&#160;copy | src_filename&#160;dest_filename | Copy a file (on-disk to on-disk) |
| mv&#160;\|&#160;ren | src_filename&#160;dest_filename | Rename a file |
| load | src_filename(disk)&#160;\[dest_filename(local)\] | Read a file from the disk |
| save | src_filename(local)&#160;\[dest_filename(disk)\] | Write a file to the disk |
| format | | Format the disk with "operation-mode" filesystem format |

**"FDC mode" commands**
| command | arguments | Description |
| --- | --- | -- |
| D&#160;\|&#160;condition | | Report the drive/disk status |
| F&#160;\|&#160;ff&#160;\|&#160;fdc_format | \[0-6\] | Format disk with <size_code> sized logical sectors and no "operation-mode" filesystem.<br>size codes: 0=64 1=80 2=128 3=256 4=512 5=1024 6=1280 bytes per logical sector. (default 1280 if not specified) |
| R&#160;\|&#160;rl&#160;\|&#160;read_logical | \[0-79\]&#160;\[1-20\]&#160;\[local_filename\] | Read one logical sector at address: physical(0-79) logical(1-20). Save to local_filename if given, else display on screen.<br>default physical 0 logical 1 |
| A&#160;\|&#160;ri&#160;\|&#160;read_id | \[0-79\]&#160;\[local_filename\] | Read Sector ID Data<br>default physical sector 0 |
| B&#160;\|&#160;wi&#160;\|&#160;write_id | \[0-79\] \<ignored\> 13_hex_pairs... | Write the 13-byte Sector ID data. |
| W&#160;\|&#160;wl&#160;\|&#160;write_logical | \<physical\>&#160;\<logical\>&#160;\<size\>&#160;hex_pairs... | Write one logical sector to disk |
| rp&#160;\|&#160;read_physical | \[0-79\] \[filename\] | Read all logical sectors in a physical sector<br>default physical sector 0<br>write to filename else display on screen |
| dd&#160;\|&#160;dump_disk | \[filename\] | Read all logical sectors in all physical sectors<br>write to filename else display on screen |
| h2d&#160;\|&#160;restore_disk | filename | Restore a disk from filename |

**general/other commands**  
| command | arguments | Description |
| --- | --- | -- |
| q&#160;\|&#160;quit&#160;\|&#160;bye&#160;\|&#160;exit | | Order Pizza |
| debug | \[0-3\] | Debug/verbose level - Toggle on/off each time it's called, or set the specified debug level if given<br>0 - debug mode off<br>1 - debug mode on<br>3 - debug mode on, plus every call to either tpdd_read() or tpdd_write() creates a log file with a copy of the data |

There are also a bunch of low level raw/debugging commands not shown here. See do_cmd() in the script.

Multiple commands may be given at once, seperated by ';' to form a pre-loaded sequence.  

Additionally some behavior may be modified by setting environment variables.
| variable | value | effect |
| --- | --- | --- |
| DEBUG | # | same as debug command above |
| FLOPPY_COMPAT | true\|false | (default is true) automatically pad & un-pad filenames between the natural form and the space-padded 6.2 form needed to be compatible with "Floppy" & "Flopy2". Disabling allows you to see the actual on-disk file names like <pre>**"A     .BA               "**</pre> and allows you to use the entire 24-byte filename field however you want |

## Examples
The same commands can be given either on the command line, or at the interactive prompt.  
Example, to list the directory, where the command is: ```ls```, can be used either of these ways:  
```pdd ls``` or ```TPDD(opr)> ls```

**Copy a file from the disk**  
```pdd load DOSNEC.CO```

**Copy a file from the disk and save to a different local name**  
```pdd load DOSNEC.CO ts-dos_4.1_nec.co```

**Copy a file to the disk**  
```pdd save ts-dos_4.1_nec.co DOSNEC.CO```

**Stacked Commands: Delete File, then Directory List**  
In interactive mode:  
```TPDD(opr)> rm DOSNEC.CO ;ls```  
In non-interactive mode, quote the list because of the ";"  
```pdd "rm DOSNEC.CO ;ls"```  

**FDC-mode drive condition**  
Interactive:  
```
$ pdd
TPDD(opr)> fdc
TPDD(fdc)> condition
Disk Inserted, Writable
TPDD(fdc)> q
$
```
Non-interactive:  
```
$ pdd D
Disk Inserted, Writable
$ 
```

**Verbose/debug mode**  
```DEBUG=1 pdd ...``` or ```TPDD(opr)> debug 1```

Log raw serial port traffic:  
Make every call to tpdd_read() or tpdd_write() also create a local file with a copy of whatever was actually read from or written to the serial port.  
```DEBUG=3 pdd ...``` or ```TPDD(opr)> debug 3```

**Find out a disk's logical sector size**  
Most disks are formatted with 20 64-byte logical sectors per physical sector, since that's what the operation-mode format function in the firmware does, but there are exceptions. The TPDD1 Utility Disk seems like a normal disk, but it's actually formatted with 1 1280-byte logical sector per physical sector. You need to know this to use some FDC-Mode commands.  
The logical sector size that a disk is formatted with can be seen by running the read_physical, read_logical, or read_id commands on any sector.  
The quickest is to run either ```ri``` or ```rl``` with no arguments:  
```pdd ri``` or ```pdd rl```

**Read the Sector ID Data for all 80 physical sectors**  
(using bash shell expansion to do something the program doesn't provide itself)  
```pdd ri\ {0..79}\;```

**Hex dump a physical sector to file**
```pdd rp 3 mydisk_p3.hex```

**Dump entire disk to screen**  
```pdd dd```

**Dump entire disk to file mydisk.hex**  
```pdd dump_disk mydisk.hex```

**Restore entire disk from mydisk.hex**  
```pdd restore_disk mydisk.hex```

# Status
All the "operation mode" commands work. Usable for all normal file access functions: load, save, delete, copy, move, & list files, format disk.

Most of the FDC-mode functions work as well (sector access). Full disk dump & restore is working.  
This means it is now possible to create a TPDD1 Utility Disk or DiskPower KC-85 distribution disk from a download without exotic hardware like Kryoflux. Just the TPDD drive itself and serial connection.

Only the TPDD1 sector access is supported yet, not TPDD2. No TPDD2 bank 1: for normal file access either.

# References
http://tandy.wiki/TPDD  
https://archive.org/details/TandyPortableDiskDriveSoftwareManual26-3808s/ ([Local copy](https://docs.google.com/viewer?url=https://github.com/bkw777/pdd.sh/raw/main/Tandy_Portable_Disk_Drive_Software_Manual_26-3808S.pdf))  
http://www.bitchin100.com/wiki/index.php?title=Base_Protocol  
http://www.bitchin100.com/wiki/index.php?title=Desklink/TS-DOS_Directory_Access  
http://www.bitchin100.com/wiki/index.php?title=TPDD-2_Sector_Access_Protocol  
https://www.ordersomewherechaos.com/rosso/fetish/m102/web100/docs/pdd2-sector-0.html  
https://www.ordersomewherechaos.com/rosso/fetish/m102/web100/docs/pdd-sector-access.html
