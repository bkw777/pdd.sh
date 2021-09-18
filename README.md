# pdd.sh

A [TPDD client](http://tandy.wiki/TPDD_client) implemented in pure\* bash.

It's pure bash except for the following:  
* "stty" is needed once at startup to configure the serial port.  
* "mkfifo" is used once at startup for \_sleep() without /usr/bin/sleep .  

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

**TPDD1/TPDD2 File Access**  
| command | arguments | description |
| --- | --- | --- |
| status | | Report the drive/disk status (basic) |
| D&#160;\|&#160;condition | | Report the drive/disk status (more informative) |
| b&#160;\|&#160;bank | \<0-1\> | (TPDD2 only) Select bank 0 or 1 - affects list/load/save/del/copy/ren |
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
| W&#160;\|&#160;wl&#160;\|&#160;write_logical | \<physical\>&#160;\<logical\>&#160;\<size\>&#160;hex_pairs... | Write one logical sector to disk |
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
| 1&#160;\|&#160;pdd1 | | Select TPDD1 mode |
| 2&#160;\|&#160;pdd2 | | Select TPDD2 mode |
| dd&#160;\|&#160;dump_disk | \[filename\] | Read an entire disk & write to filename or display on screen |
| rd&#160;\|&#160;restore_disk | \<filename\> | Restore a disk from filename |
| read_smt | \[0\|1\] | Read the Space Management Table (from bank# if specified) |
| send_loader | \<filename\> | Send a BASIC program to a "Model T".<br>Use to install a TPDD client.<br>See https://github.com/bkw777/dlplus/tree/master/clients |
| q&#160;\|&#160;quit&#160;\|&#160;bye&#160;\|&#160;exit | | Order Pizza |
| baud&#160;\|&#160;speed | \[9600\|19200\] | Serial port speed. Default is 19200.<br>TPDD1 & TPDD2 run at 19200.<br>FB-100/FDD-19/Purple Computing run at 9600 |
| debug | \[#\] | Debug/Verbose level - Toggle between 0 & 1, or set specified level<br>0 = debug mode off<br>1 = debug mode on<br>\>1 = more verbose<br>9 = every tpdd_read() or tpdd_write() creates a log file with a copy of the data |
| pdd1_boot | \[100\|200\] | Emulate a Model 100 or 200 performing the TPDD1 bootstrap procedure.<br>WIP: the collected BASIC is good, the collected binary is not |
| pdd2_boot | \[100\|200\] | Emulate a Model 100 or 200 performing the TPDD2 bootstrap procedure.<br>WIP: the collected BASIC is good, the collected binary is not |

There are also a bunch of low level raw/debugging commands not shown here. See do_cmd() in the script.

Multiple commands may be given at once, seperated by ';' to form a pre-loaded sequence.  

Additionally, some behavior may be modified by setting environment variables.
| variable | value | effect |
| --- | --- | --- |
| BAUD | 9600\|19200 | Same as **baud** command above |
| DEBUG | # | same as **debug** command above |
| FLOPPY_COMPAT | true\|false | (default is true) Automatically pad & un-pad filenames between the natural form and the space-padded 6.2 form needed to be compatible with "Floppy" & "Flopy2". Disabling allows you to see the actual on-disk file names like <pre>**"A     .BA               "**</pre> and allows you to use the entire 24-byte filename field however you want |
| TPDD_MODEL | 1\|2 | (default is 1) Assume the attached TPDD drive is a TPDD1 or TPDD2 by default |

Finally, the name that the script is called by is another way to select between TPDD1 and TPDD2 compatibility.  
```make install``` installs the script as ```/usr/local/bin/pdd```, and also installs 2 symlinks named ```pdd1``` and ```pdd2```.  
Running ```pdd1 some_command``` is equivalent to running ```pdd "1;some_command"```  
Running ```pdd2 some_command``` is equivalent to running ```pdd "2;some_command"```  

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

**Command Lists with ";"**  
Delete File, List Directory
In interactive mode:  
```TPDD(opr)> rm DOSNEC.CO ;ls```  
In non-interactive mode, quote the list because of the ";"  
```pdd "rm DOSNEC.CO ;ls"```  
Copy a file to bank 1 of a TPDD2 disk, list bank 1 directory  
```pdd2 "bank 1 ;save ts-dos_4.1_nec.co DOSNEC.CO ;ls"```

**Drive/Disk Condition**  
```
$ pdd1 condition
Disk Inserted, Writable

```

**Verbose/debug mode**  
```DEBUG=1 pdd ...``` or ```TPDD(opr)> debug 1```

Log raw serial port traffic:  
Make every call to tpdd_read() or tpdd_write() also create a local file with a copy of whatever was actually read from or written to the serial port.  
```DEBUG=9 pdd ...``` or ```TPDD(opr)> debug 9```

**Find out a TPDD1 disk's logical sector size**  
Most disks are formatted with 20 64-byte logical sectors per physical sector, since that's what the operation-mode format function in the firmware does, but there are exceptions. The TPDD1 Utility Disk seems like a normal disk, but it's actually formatted with 1 1280-byte logical sector per physical sector. You need to know this to use some FDC-Mode commands.  
The logical sector size that a disk is formatted with can be seen by running the read_physical, read_logical, or read_id commands on any sector.  
The quickest is to run either ```ri``` or ```rl``` with no arguments:  
```pdd1 ri``` or ```pdd1 rl```

**Read the Sector ID Data for all 80 physical sectors (TPDD1)**  
(using bash shell expansion to do something the program doesn't provide itself)  
```pdd1 ri\ {0..79}\;```

**Dump an entire TPDD1 disk to file mydisk.p1h**  
Suggestion: use \*.p1h for filename for TPDD1 disks in hex dump format  
```pdd1 dump_disk mydisk.p1h```

**Dump an entire TPDD2 disk to file mydisk.p2h**  
Suggestion: use \*.p2h for filename for TPDD2 disks in hex dump format  
```pdd2 dump_disk mydisk.p2h```

**Restore an entire TPDD1 disk from mydisk.p1h**  
**(Re-create the TPDD1 Utility Disk)**  
```pdd1 restore_disk TPDD1_26-3808_Utility_Disk.p1h```

**Restore an entire TPDD2 disk from mydisk.p2h**  
**(Re-create the TPDD2 Utility Disk)**  
```pdd2 restore_disk TPDD2_26-3814_Utility_Disk.p2h```

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
