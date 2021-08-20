## Formatting
Disks are arranged in 40 physical tracks, with 2 physical sectors per track, and 1 to 20 logical sectors per physical sector depending of the logical sector size.  

Disks may be formatted with one of 7 possible logical sector sizes.  
64, 80, 128, 256, 512, 1024, or 1280 bytes per logical sector, plus a special format for "operation-mode".

A physical sector is 1280 bytes, and the largest possible logical sector is 1280 bytes.

There are 2 different format-disk commands, operation-mode and FDC-mode.

### operation-mode
The operation-mode format is somehow special and different from FDC-mode format.  
```format``` usually(*) creates 64-byte logical sectors, but if you use the FDC-mode format command ```ff 0``` to format with 64-byte logical sectors, and then try save a file, ```ls``` will show the file's contents were written into the directory sector. Probably you have to write the FCB stuff in sector 0 to make it a viable filesystem.

(*) Sometimes it creates a strange format where physical sector 0 has 64-byte logical sectors, and the rest of the disk has 80-byte logical sectors. I can't reproduce this at-will, it's just happens sometimes.

### FDC-mode
The FDC-mode format command, ```ff``` or ```fdc_format```, creates a uniform format with the specified logical sector size applied the same on all physical sectors.

The drive firmware uses size 3 (256 bytes) by default if not specified, but we apply our own default of 6 (1280 bytes) instead in the script.  
| command | sector size in bytes |
| --- | --- |
| ```ff``` | 1280 |
| ```ff 0``` | 64 |
| ```ff 1``` | 80 |
| ```ff 2``` | 128 |
| ```ff 3``` | 256 |
| ```ff 4``` | 512 |
| ```ff 5``` | 1024 |
| ```ff 6``` | 1280 |

### Disks seen in the wild
The TPDD1 Utility Disk that comes with the drive (and all copies made with it's own included backup program) is actually formatted with 1280-byte logical sectors, yet still works with normal operation-mode filesystem commands.  
*Perhaps* the way this works is, since 1280-bytes is the entire physical sector, maybe it's possible to treat the logical sector as raw space and construct the correct formatting within that space yourself?  
This is why this util defaults to 1280-byte logical sectors when not specified instead of letting the drive firmware's default of 256 take effect. Either 64-byte or 1280-byte are useful but 256 would only be useful for some custom low level use of the drive as raw space.  

The Disk Power KC-85 distribution disk appears to be a normal disk formatted with the operation-mode format, 64-byte logical sectors.

### Examining a disk
The format of a given sector can be seen from the read_logical or read_id commands.  
This is a disk with that strange 64-80 format described above.  
```
$ ./pdd "rl ;rl 0 13 ;rl 1 1 ;rl 1 13 ;rl 79 1"
Physical  0 | Logical  1 | Length   64
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical  0 | Logical 13 | Length   64
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical  1 | Logical  1 | Length   80
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical  1 | Logical 13 | Length   80
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical 79 | Logical  1 | Length   80
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
$
```

Same disk...  
```
$ ./pdd "ri ;ri 1 ;ri 2 ;ri 25 ;ri 79"
Physical Sector  0 | Length 64 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector  1 | Length 80 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector  2 | Length 80 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 25 | Length 80 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 79 | Length 80 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
$ 
```

## Sector ID Section
read_id takes a physical sector number as the only argument, 0-79,  
and returns 13 bytes.
For "operation-mode" filesystem formatted disks, only the first byte is used.  
Page 11 of [the sofware manual](Tandy\ Portable\ Disk\ Drive\ Software\ Manual\ 26-3808S.pdf) explains how to interpret that byte.  
00 = this sector is not used by a file  
FF = this sector is the last sector in this file  
## = pointer to the next sector in this file  

Sector 0 always has 00
