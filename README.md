# TPDD_bash

A [TPDD client](http://tandy.wiki/TPDD_client) implemented in (almost) pure bash.

It's pure bash except for the following:  
* "stty" is needed once at startup to configure the serial port.  
* "mkfifo" is used once at startup for _sleep() without /usr/bin/sleep .  

That's it. There are no other external commands or dependencies, not even any child forks (no backticks or pipes).

## Usage
```pdd [tty_device] [command [args...]]```

With no arguments, it will run in interactive command mode.  
You get a ```TPDD($mode)>``` prompt where you can enter commands.  
"help" is still not one of them ;) Sorry.

**tty_device** will be auto detected in most cases.  
Failing that, you'll be shown a list of possible choices to select from.  
Or you may specify one as the first argument on the command line.  

There are two groups of commands, "operation mode" and "FDC mode".  

**"operation mode" commands**  
| command | arguments | description |
| --- | --- | --- |
| status | | Report the drive/disk status |
| ls&#160;\|&#160;list&#160;\|&#160;dir | | Directory listing |
| rm&#160;\|&#160;del | disk_filename | Delete a file |
| cp&#160;\|&#160;copy | disk_src_filename&#160;disk_dest_filename | Copy a file on-disk to another file on-disk |
| mv&#160;\|&#160;ren | disk_src_filename&#160;disk_dest_filename | Rename a file on-disk |
| load | disk_src_filename&#160;\[local_dest_filename\] | Copy a file from the disk |
| save | local_src_filename&#160;\[disk_dest_filename\] | Copy a file to the disk |
| format | | Format the disk - 64-byte sector size |
| fdc | | Switch to FDC mode |

**"FDC mode" commands**
| command | arguments | Description |
| --- | --- | -- |
| M&#160;\|&#160;mode | 0\|1 | Select operation(0) or fdc(1) mode |
| D&#160;\|&#160;condition | | Report the drive/disk status |
| F&#160;\|&#160;ff&#160;\|&#160;fdc_format | \[0-6\] | Format disk, sector size 64 80 128 256 512 1024 1280. (default 256 if not specified) |
| R&#160;\|&#160;rs&#160;\|&#160;read_sector | \<0-79\>&#160;\<1-20\>&#160;[local_filename] | Read one logical sector at address: physical(0-79) logical(1-20). Save to locale_filename if given, else display on screen. |
| A&#160;\|&#160;ri&#160;\|&#160;read_id | | not yet implemented |
| S&#160;\|&#160;si&#160;\|&#160;search_id | | not yet implemented |
| B&#160;\|&#160;wi&#160;\|&#160;write_id | | not yet implemented |
| W&#160;\|&#160;ws&#160;\|&#160;write_sector | | not yet implemented |

**general/other commands**  
| command | arguments | Description |
| --- | --- | -- |
| q \| quit \| bye \| exit | | Order Pizza |
| debug | ''\|0-3 | Debug/verbose level - Set the specified debug level, or toggle between 0 & 1 of no level given |

There are also a bunch of low level raw/debugging commands not shown here. See do_cmd() in the script.

Multiple commands may be given at once, seperated by ';' to form a pre-loaded sequence.  

Additionally some behavior may be modified by setting environment variables.
| variable | value | effect |
| --- | --- | --- |
| DEBUG | 1 | prints a lot of internal progress and details while working
| | 3 | additionally copies all serial port traffic to log files |
| FLOPPY_COMPAT | true | (default) automatically pad & un-pad filenames between the natural form and the space-padded 6.2 form needed to be compatible with "Floppy" & "Flopy2". |
| | false | disable that padding/un-padding. Allows you to see the actual on-disk file name like <pre>"A     .BA               "</pre> and allows you to use the entire 24-byte filename field however you want |

You generally don't need to explicitly use the operation/fdc mode switch commands, as all mode-specific commands include a check to switch to the necessary mode on the fly.

No built-in help yet.

## Examples
In all cases, the same commands can be given either at the command line, or at the interactive prompt.  
Example, to list the directory, where the command is: ```ls```, can be used either of these ways:  
```$ ./pdd ls``` or ```TPDD(opr)> ls```

**Copy a file from the disk**  
```load DOSNEC.CO```  

**Copy a file from the disk and save to a different local name**  
```load DOSNEC.CO ts-dos_4.1_nec.co```

**Stacked Commands: Delete File, then Directory List**  
In interactive mode:  
```TPDD(opr)> rm DOSNEC.CO ;ls```  
In non-interactive mode, quote the list because of the ";"  
```$ ./pdd "rm DOSNEC.CO ;ls"```  
...or you could use backslash to escape it:  
```$ ./pdd rm DOSNEC.CO \;ls```

**FDC-mode drive condition**  
Interactive:  
```
$ ./pdd
TPDD(opr)> fdc
TPDD(fdc)> condition
Disk Inserted, Writable
TPDD(fdc)>
```
Non-interactive:  
```
$ ./pdd D
Disk Inserted, Writable
$ 
```
Verbose/debug mode:  
```$ DEBUG=1 ./pdd ...``` or ```TPDD(opr)> debug 1```  

Log raw serial port traffic:  
Every call to tpdd_read() or tpdd_write() also creates a local file with a copy of whatever was actually read from or written to the serial port.  
```$ DEBUG=3 ./pdd ...``` or ```TPDD(opr> debug 3```

# General Info

## Formatting
Disks are arranged in 40 physical tracks, with 2 physical sectors per track, and 1 to 20 logical sectors per physical sector depending of the logical sector size.  

Disks may be formatted with one of 7 possible logical sector sizes.  
64, 80, 128, 256, 512, 1024, or 1280 bytes per logical sector.

A physical sector is 1280 bytes, and the largest possible logical sector is 1280 bytes.

There are 2 different format-disk commands, an operation-mode version and an FDC-mode version.

The operation-mode format command, ```format```, always creates 64-byte logical sectors, and doesn't have any option to specify any other sector size.

The FDC-mode format command, ```ff``` or ```fdc_format```, creates 256-byte sectors by default, and accepts an option to specify the logical sector size.  
| command | sector size in bytes |
| --- | --- |
| ```ff``` | 256 |
| ```ff 0``` | 64 |
| ```ff 1``` | 80 |
| ```ff 2``` | 128 |
| ```ff 3``` | 256 |
| ```ff 4``` | 512 |
| ```ff 5``` | 1024 |
| ```ff 6``` | 1280 |

The TPDD1 utility disk is formatted with 1280-byte logical sectors, and so are copies made with it's backup program.  
To format a disk the same way as the TPDD1 utility disk, you would format with the fdc_format command with size code 6: ```ff 6```

Disks formatted with the operation-mode 64-byte format are still readable/writable by "Floppy" and all other TPDD clients.

Odd datum: The original distribution disk for Disk Power KC-85 by Hugo Ferreyra has 64-byte logical sectors. It was probably created with the operation-mode format command.

The format of a given disk can be seen by issuing the read_sector command to read any valid logical sector. Physical 1 logical 1 should always work. The first 2 lines of output will show the sector size.  
```TPDD(fdc)> rs 1 1```

# Status
All the "operation mode" commands work.  
Starting on the "FDC mode" commands  

# References
http://tandy.wiki/TPDD  
https://archive.org/details/TandyPortableDiskDriveSoftwareManual26-3808s/  
https://www.ordersomewherechaos.com/rosso/fetish/m102/web100/docs/pdd2-sector-0.html  
https://www.ordersomewherechaos.com/rosso/fetish/m102/web100/docs/pdd-sector-access.html
