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

**TPDD1 "FDC mode" commands**  
| command | arguments | Description |
| --- | --- | --- |
| D&#160;\|&#160;condition | | Report the drive/disk status |
| F&#160;\|&#160;ff&#160;\|&#160;fdc_format | \[0-6\] | Format disk with <size_code> sized logical sectors and no "operation-mode" filesystem.<br>size codes: 0=64 1=80 2=128 3=256 4=512 5=1024 6=1280 bytes per logical sector. (default 1280 if not specified) |
| R&#160;\|&#160;rl&#160;\|&#160;read_logical | \[0-79\]&#160;\[1-20\]&#160;\[local_filename\] | Read one logical sector at address: physical(0-79) logical(1-20). Save to local_filename if given, else display on screen.<br>default physical 0 logical 1 |
| A&#160;\|&#160;ri&#160;\|&#160;read_id | \[0-79\]&#160;\[local_filename\] | Read Sector ID Data<br>default physical sector 0 |
| B&#160;\|&#160;wi&#160;\|&#160;write_id | \[0-79\] \<ignored\> 13_hex_pairs... | Write the 13-byte Sector ID data. |
| W&#160;\|&#160;wl&#160;\|&#160;write_logical | \<physical\>&#160;\<logical\>&#160;\<size\>&#160;hex_pairs... | Write one logical sector to disk |
| rp&#160;\|&#160;read_physical | \[0-79\] \[filename\] | Read all logical sectors in a physical sector<br>default physical sector 0<br>write to filename else display on screen |

**TPDD2 commands**  
| command | arguments | Description |
| --- | --- | --- |
| bank | \<0-1\> | Select bank# - affects ls/load/save/rm |
| load_sector | \<track#&#160;0-79\>&#160;\<sector#&#160;0-1\> | Load a physical sector into the drive's sector cache |
| read_fragment | \<length&#160;0-252\>&#160;\<offset&#160;0-252\> | Read \<length\> bytes at \<length\> x \<offset\> from the sector cache.<br>The only *useful* values are divisions of 1280. This means: multiples of 2, up to 128. ```dump_disk``` in pdd2-mode uses 128. |

**general/other commands**  
| command | arguments | Description |
| --- | --- | --- |
| 1&#160;\|&#160;pdd1 | | Select TPDD1 mode |
| 2&#160;\|&#160;pdd2 | | Select TPDD2 mode |
| dd&#160;\|&#160;dump_disk | \[filename\] | Read all logical sectors in all physical sectors<br>write to filename else display on screen |
| h2d&#160;\|&#160;restore_disk | filename | Restore a disk from filename<br>TPDD1 only at this time |
| send_loader | filename | Send a BASIC program to a "Model T".<br>Use to install a TPDD client.<br>See https://github.com/bkw777/dlplus/tree/master/clients |
| q&#160;\|&#160;quit&#160;\|&#160;bye&#160;\|&#160;exit | | Order Pizza |
| debug | \[#\] | Debug/Verbose level - Toggle between 0 & 1, or set specified level<br>0 = debug mode off<br>1 = debug mode on<br>\>1 = more verbose<br>9 = every tpdd_read() or tpdd_write() creates a log file with a copy of the data |

There are also a bunch of low level raw/debugging commands not shown here. See do_cmd() in the script.

Multiple commands may be given at once, seperated by ';' to form a pre-loaded sequence.  

Additionally, some behavior may be modified by setting environment variables.
| variable | value | effect |
| --- | --- | --- |
| DEBUG | # | same as debug command above |
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

**Read a fragment of a sector from a TPDD2 drive**  
Read the first 64-bytes of sector 0 track 2:  
```pdd2 'load_sector 2 0 ;read_fragment 64 0'```  
Read the last 64-bytes of sector 0 track 2:  
```pdd2 'load_sector 2 0 ;read_fragment 64 19'```  

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

