# TPDD_bash

A [TPDD client](http://tandy.wiki/TPDD_client) implemented in (almost) pure bash.

Currently the basic skeleton is up and working to send requests to and read responses from the drive, and a few commands work.

The only commands that are implemented yet are:

"operation mode" commands:
* fdc - switch to FDC mode
* status - report the status of the drive & disk
* dirent - directry entry or reference - this command is used both to specify a filename for a subsequent action like open/close/read/write/delete, and to get a listing of filenames.
* ls - not a command in the drive, but a client-implemented command that does dirent several times to get the directory listing.
* format - format a disk

"FDC mode" commands:
* mode - select "operation mode" or "FDC mode"
* condition - report status of the drive & disk

It's pure bash except for the following:
* "stty" is needed once at startup to configure the serial port.
* "mkfifo" is used once at startup for _sleep() without /usr/bin/sleep .
That's it. There are no other external commands or dependencies, not even any child forks (no backticks or pipes).

# References
http://tandy.wiki/TPDD
https://archive.org/details/TandyPortableDiskDriveSoftwareManual26-3808s/
https://www.ordersomewherechaos.com/rosso/fetish/m102/web100/docs/pdd2-sector-0.html
https://www.ordersomewherechaos.com/rosso/fetish/m102/web100/docs/pdd-sector-access.html
