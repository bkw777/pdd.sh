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
| ls \| list \| dir | | Directory listing |
| rm \| del | | Delete a file |
| cp \| copy | source dest | Copy a TPDD file to another TPDD file |
| mv \| ren | | Rename a file |
| load | disk_src_filename \[local_dest_filename\] | Copy a file from the disk |
| save | local_src_filename \[disk_dest_filename\] | Copy a file to the disk |
| format | | Format the disk - 64-byte sector size |
| fdc | | Switch to FDC mode |

**"FDC mode" commands**
| command | arguments | Description |
| --- | --- | -- |
| M \| mode | 0\|1 | Select operation(0) or fdc(1) mode |
| D \| condition | | Report the drive/disk status |
| F\| ff \| fdc_format | ''\|0-6 | Format disk, sector size 64 80 128 (256) 512 1024 1280 |
| R \| rs \| read_sector | 0-79 1-20 [local_filename] | Read one logical sector at address: physical(0-79) logical(1-20). Save to locale_filename if given, else display on screen. |
| A \| ri \| read_id | | not yet implemented |
| S \| si \| search_id | | not yet implemented |
| B \| wi \| write_id | | not yet implemented |
| W \| ws \| write_sector | | not yet implemented |

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

No built-in help yet.

## Examples

**List files**  
```$ ./pdd ls```

**Copy a file from the disk**  
```$ ./pdd load DOSNEC.CO```  

**Copy a file from the disk and save to a different local name**  
```$ ./pdd load DOSNEC.CO ts-dos_4.1_nec.co```

**Stacked Commands: Delete File, then Directory List**  
In interactive mode:  
```TPDD(opr)>rm DOSNEC.CO ;ls```  
In non-interactive mode:..
```$ ./pdd "rm DOSNEC.CO ;ls"```  

**FDC mode drive condition**  
Interactive:  
```
$ ./pdd
TPDD(opr)> fdc
TPDD(fdc)> condition
Disk Inserted, Writable
TPDD(fdc)>
```
Non-interactive, stacked commands, short commands, explicit quit added to override the fdc command's "don't-exit" behavior:  
```
$ ./pdd "fdc;D;q"
Disk Inserted, Writable
$ 
```

To see all the gory blow-by-blow, do ```$ DEBUG=1 ./pdd ...``` or ```TPDD(opr)> debug 1```  

```$ DEBUG=3 ./pdd ...``` or ```TPDD(opr> debug 3``` -> each individual call to tpdd_read() or tpdd_write() creates a file with a copy of whatever was actually read from or written to the serial port.

# General Info

## operation vs fdc mode
The drives power-on default operating mode is controlled by the dip switches on the bottom of the drive. Except for special situations like the TPDD1 bootstrap procedure, the switches are usaually set so that the drive boots up in "operation mode".

This script also always issues the ```mode 1``` command on start-up before processing any other commands, so even aside from the power-on default, we always start off in a known state, in "operation mode".

You can start off in FDC mode by putting the fdc command on the command line. In that case the script will stay in interactive mode even though a command was given on the command line.  
```./pdd fdc```

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
