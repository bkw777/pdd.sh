# TPDD_bash

A [TPDD client](http://tandy.wiki/TPDD_client) implemented in (almost) pure bash.

It's pure bash except for the following:  
* "stty" is needed once at startup to configure the serial port.  
* "mkfifo" is used once at startup for _sleep() without /usr/bin/sleep .  

That's it. There are no other external commands or dependencies, not even any child forks (no backticks or pipes).

## Usage
```tpddclient [tty_device] [command [args...]]```

With no arguments, it will run in interactive command mode.  
You get a ```TPDD($mode)>``` prompt where you can enter commands.  
"help" is still not one of them ;) Sorry.

**tty_device** will be auto detected in most cases.  
Failing that, you'll be shown a list of possible choices to select from.  
Or you may specify one as the first argument on the command line.  

There are two groups of commands, "operation mode" and "FDC mode".  

**"operation mode" commands**  
| command| |
| --- | --- |
| status | Report the drive/disk status |
| ls \| list \| dir | Directory listing |
| rm \| del | Delete a file |
| cp \| copy | Copy a file |
| mv \| ren | Rename a file |
| load | Copy a file from the disk |
| save | Copy a file to the disk |
| format | Format the disk |
| q \| quit \| bye \| exit | Order Pizza |
| fdc | Switch to FDC mode |

**"FDC mode" commands**
| command | |
| --- | --- |
| condition | Report the drive/disk status |
| mode | Select operation or fdc mode |

(There are several more FDC mode commands in the drive firmware but most are not implemented yet.)

There are also a bunch of low level raw/debugging commands that I'm not going to take the time to document here. Look at do_cmd() in the script.

load, save and delete take a filename as an argument.  
```TPDD(opr)>rm GAME.BA```

load and save may also optionally be given a 2nd argument for a destination filename.  
```TPDD(opr)>save TheBestGameInTheWorld.bas GAME.BA```

Multiple commands may be given at once, seperated by ';' to form a pre-loaded sequence.  
Example, delete a file and then list all files:  
In interactive mode: ```TPDD(opr)>rm DOSNEC.CO ;ls```  
In non-interactive mode: ```$ ./tpddclient "rm DOSNEC.CO ;ls"```  

Additionally some behavior may be modified by setting environment variables.
| variable | value | effect |
| --- | --- | --- |
| DEBUG | 1 | prints a lot of internal progress and details while working
| | 3 | additionally copies all serial port traffic to log files |
| FLOPPY_COMPAT | true | (default) automatically pad & un-pad filenames between the natural form and the space-padded 6.2 form needed to be compatible with "Floppy" & "Flopy2". |
| | false | disable that padding/un-padding. Allows you to see the actual on-disk file name like <pre>"A     .BA               "</pre> and allows you to use the entire 24-byte filename field however you want |

No built-in help yet.

## Examples

**FDC mode drive condition**  
1. Run ```$ ./tpddclient``` with no args.  
2. Type "fdc" at the prompt and hit enter.  
 That switches you to "FDC" mode where you can enter FDC mode commands.  
3. Type "D" and hit enter (short alias for "condition").  
 You should get a message that correctly reflects whether you have a disk inserted or not, and whether that disk is currently write-protected or not.

**List files**  
1. Insert a disk and run ```$ ./tpddclient ls```  
 It should scan the disk, list the files and file sizes, and then exit back to the shell.

**Copy a file from the disk**  
```$ ./tpddclient load DOSNEC.CO```  
...rename along the way...  
```$ ./tpddclient load DOSNEC.CO ts-dos_4.1_nec.co```

To see all the gory blow-by-blow, do ```$ DEBUG=1 ./tpddclient ...```  
```$ DEBUG=3 ./tpddclient ...``` will additionally create log files containing every read from and write to the serial port.  
Each individual call to tpdd_read() or tpdd_write() creates a file with a copy of whatever was actually read from or written to the serial port.

# Status
All the "operation mode" commands work!  
All...most none of the "FDC mode" commands exist!  

# References
http://tandy.wiki/TPDD  
https://archive.org/details/TandyPortableDiskDriveSoftwareManual26-3808s/  
https://www.ordersomewherechaos.com/rosso/fetish/m102/web100/docs/pdd2-sector-0.html  
https://www.ordersomewherechaos.com/rosso/fetish/m102/web100/docs/pdd-sector-access.html
