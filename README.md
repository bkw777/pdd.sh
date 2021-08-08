# TPDD_bash

A [TPDD client](http://tandy.wiki/TPDD_client) implemented in (almost) pure bash.

It's pure bash except for the following:
* "stty" is needed once at startup to configure the serial port.  
* "mkfifo" is used once at startup for _sleep() without /usr/bin/sleep .  
That's it. There are no other external commands or dependencies, not even any child forks (no backticks or pipes).

##Functions that are at least partially implemented

###Low level "operation mode" commands  
These are essentially wrappers for the functions of the drive firmware, which are mostly not used directly by a user, but used by other commands.
* fdc - switch to FDC mode
* status - report the status of the drive (disk ejected, hardware fault, etc)
* dirent - set a filename, or get the first filename, or get the next filename
* format - format a disk
* open - open the currently set filename for write(new), write(append), or read
* close - close the currently open file
* read - read a block of data from the currently open file
* ocmd_delete - delete the currently set filename
* write - write a block of data to the currently open file (not written yet)

###High level "operation mode" commands  
These are compound functions that use combinations of the other functions to do something actually useful.  
* ls - dirent loop to list all files on the disk
* rm - delete a file
* load - copy a file from disk to local filesystem
* save - copy a file from the local filesystem to the disk (not not written yet)
* q - quit

###"FDC mode" commands  
* mode - select "operation mode" or "FDC mode"
* condition - report status of the drive & disk - this is a little different from the "operation mode" status command

###Other commands
There are several low level manual debugging commands too, which are mostly just wrappers for the low level drive functions and even lower level serial communication functions.  
com_read, com_write, etc...

## Usage
(after connecting a TPDD drive)

```tpddclient [tty_device] [command [args...]]```

In most cases it will automatically discover the tty for the serial port, assuming there is only one serial device and it's a usb-serial adapter.  
If there are multiple usb-serial adapters connected, it will prompt you to select one.  
If you need to override the automatic guess, just supply a tty device as the first argument on the command line.

"command" is any of the commands above. Actually look at do_cmd() in the script. That shows all the active commands and all their aliases.

If you don't supply any command on the commandline, the script runs in interactive mode where you enter the same commands at a "TPDD($mode)>" prompt.

Multiple commands may be given at once, seperated by ';', either on the commandline to send an entire sequence and exit, or given manually at the interactive mode prompt.
Exampe, delete a file and get a listing immediately after:
In interactive mode: ```TPDD(opr)>rm DOSNEC.CO ;ls```
In non-interactive mode: ```./tpddclient rm DOSNEC.CO \;ls``` or ```./tpddclient "rm DOSNEC.CO ;ls"```

There is no help yet. For now just look at do_cmd() in the code and go from there.

## Examples

* FDC mode drive condition  
Start tpddclient with no args.  
Type "fdc" at the prompt and hit enter.  
That switches you to "FDC" mode where you can enter FDC mode commands.  
Type "D" and hit enter (short alias for "condition").  
You should get a message that correctly reflects whether you have a disk inserted or not, and whether that disk is currently write-protected or not.

* List files  
Insert a disk and run ```./tpddclient ls```  
It shoud scan the disk, list the files and file sizes, and then exit back to the shell.

* Copy a file from the disk  
```tpddclient load DOSNEC.CO```
...rename along the way...  
```tpddclient load DOSNEC.CO ts-dos_4.1_nec.co```

To see all the gory details, do ```DEBUG=1 ./tpddclient ...```  
DEBUG=3 will additionally create a log file containing every read from or write to the serial port.  

# Status
All the "operation mode" commands work except lcmd_save() isn't working yet.  
Most of it is working. file_to_hex() reads a local file into hex pairs  
including nulls, without externals or subshells. lcmd_save() loops through  
the load of hex pairs and issues ocmd_write()'s in 128 byte chunks.  
Even save() works, but only for files of 128 bytes or less.

notes for myself:  
Maybe it means you have to close the file from write_new and reopen as write_append, and close &  
re-open before each 128-byte block?

No FDC commands have been written yet except "condition" (report drive status) and "mode" (switch to fdc or operation mode).

# References
http://tandy.wiki/TPDD  
https://archive.org/details/TandyPortableDiskDriveSoftwareManual26-3808s/  
https://www.ordersomewherechaos.com/rosso/fetish/m102/web100/docs/pdd2-sector-0.html  
https://www.ordersomewherechaos.com/rosso/fetish/m102/web100/docs/pdd-sector-access.html
