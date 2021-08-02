# TPDD_bash

A [TPDD client](http://tandy.wiki/TPDD_client) implemented in (almost) pure bash.

It's pure bash except for the following:
* "stty" is needed once at startup to configure the serial port.
* "mkfifo" is used once at startup for _sleep() without /usr/bin/sleep .  
That's it. There are no other external commands or dependencies, not even any child forks (no backticks or pipes).

Low level "operation mode" commands (functions of the drive firmware, some not used directly by a user but used by other commands)
* fdc - switch to FDC mode
* status - report the status of the drive (disk ejected, hardware fault, etc)
* dirent - set a filename, or get the first filename, or get the next filename
* format - format a disk
* open - open the currently set filename for write(new), write(append), or read
* close - close the currently open file
* read - read a block of data from the currently open file
* ocmd_delete - delete the currently set filename
* write - write a block of data to the currently open file (not written yet)

High level "operation mode" commands. (compound functions that use combinations of the other functions to do something actually useful)
* ls - dirent loop to list all files on the disk
* rm - delete a file
* load - copy a file from disk to local filesystem
* save - copy a file from the local filesystem to the disk (not not written yet)
* q - quit

"FDC mode" commands:
* mode - select "operation mode" or "FDC mode"
* condition - report status of the drive & disk - this is a little different from the "operation mode" status command

There are several low level manual debugging commands too, which are mostly just wrappers for the low level drive functions and even lower level serial communication functions.  
com_read, com_write, etc...

# Usage
(after connecting a TPDD drive)

tpddclient [tty_device] [command [args...]]

In most cases it will automatically discover the tty device, assuming there is only one serial device and it's a usb-serial adapter.  
If there are multiple usb-serial adapters connected, it will prompt you to select one.  
If you need to override the automatic guess, just supply a tty device as the first argument on the command line.

"command" is any of the commands above. Actually look at do_cmd() in the script. That shows all the active commands and all their aliases.

If you don't supply any command on the commandline, the script runs in interactive mode where you enter the same commands at a "TPDD($mode)>" prompt.

Multiple commands may be given at once, seperated by ';', either on the commandline to send an entire sequence and exit, or given manually at the interactive mode prompt.
Exampe, delete a file and get a listing immediately after:
./tpddclient rm DOSNEC.CO \;ls

There is no help yet. Just look at do_cmd() in the code and go from there.

# Examples

* Start tpddclient with no args.  
Type "fdc" at the prompt and hit enter.  
That swites you to "FDC" mode where you can enter FDC mode commands.  
Type "D" and hit enter (short alias for "condition").  
You should get a message that correctly reflects whether you have a disk inserted or not, and whether that disk is currently write-protected or not.

* Insert a disk and run "./tpddclient ls"
It shoud scan the disk, list the files and file sizes, and then exit back to the shell.

To see all the gory details, do "export DEBUG=true" before running tpddclient.

# Status
All the "operation mode" commands work except write/save hasn't been written yet.

No FDC commands have been written except "condition".

# References
http://tandy.wiki/TPDD  
https://archive.org/details/TandyPortableDiskDriveSoftwareManual26-3808s/  
https://www.ordersomewherechaos.com/rosso/fetish/m102/web100/docs/pdd2-sector-0.html  
https://www.ordersomewherechaos.com/rosso/fetish/m102/web100/docs/pdd-sector-access.html
