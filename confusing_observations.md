## Formatting
Disks are arranged in 40 physical tracks, with 2 physical sectors per track, and 1 to 20 logical sectors per physical sector depending of the logical sector size.  

Disks may be formatted with one of 7 possible logical sector sizes.  
64, 80, 128, 256, 512, 1024, or 1280 bytes per logical sector, plus a special format for "operation-mode".

A physical sector is 1280 bytes, and the largest possible logical sector is 1280 bytes.

There are 2 different format-disk commands, an operation-mode version and an FDC-mode version.

### operation-mode
The operation-mode format is somehow special and different from FDC-mode format.
```format``` (usually*) creates 64-byte logical sectors, but if you use the FDC-mode format command ```ff 0``` to format with 64-byte logical sectors, and then try save a file, ```ls``` will show the file's contents were written into the directory sector.

9*) I have also seen it create a strange format where physical sector 0 has 64-byte logical sectors, and the remaining physical sectors 1-79 all have 80-byte logical sectors. I can't reproduce this at-will, it's just happened at least once.

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
The TPDD1 utility disk is actually formatted with 1280-byte logical sectors, yet still works with normal operation-mode filesystem commands.  
*Perhaps* the way this works is, since 1280-bytes is the entire physical sector, maybe it's possible to treat the logical sector as raw space and construct the correct formatting within that space yourself?  
This is why this util defaults to 1280-byte logical sectors when not specified instead of letting the drive firmware's default of 256 take effect.  

The Disk Power KC-85 distribution disk appears to be a normal disk formatted with the operation-mode format, 64-byte logical sectors.

### Examining a disk
The format of a given sector can be seen from the read_sector or read_id commands.  
This is a disk with that strange format described above.  
```
$ ./pdd "rs ;rs 0 13 ;rs 1 1 ;rs 1 13 ;rs 79 1"
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
bkw@negre:~/src/pdd.sh$
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
This data is a mystery so far. The manual descibes a 19-byte block with these fields on the disk:  
| length in bytes | data |
| --- | --- |
| 2 | Sector Length |
| 2 | Sector Number |
| 1 | Logical Sector Length Code |
| 12 | ID Reserve |
| 2 | ID CRC |

But the read_id command only returns 13 bytes, and so far that data doesn't appear to map to any combination of those fields.  
It's always 13 bytes, and always the last 12 bytes are 0, only the first byte ever changes.  
That obviously looks like the logical sector size code and the 12 byte reserved field. It's the only combination that adds up to 13, and it even appears to be in that order, since the first byte sometimes changes and the remaining 12 are always all 0's.  
However, that byte doesn't match the size code except when it's 0, because the normal disk format happens to be 64-byte sectors and that happens to be size code 0. The rule breaks all other times.  
The first byte is so far always one of 3 things:  
* 0
* 255
* The physical sector number+1 (or, the physical sector number if counting from 1 instead of 0)

Physical sector 0 always has 0

A freshly formatted disk, has 0 on every physical sector.

After saving some files, some sectors have 255, some have the maybe-sector-number, only for the irst few sectors up to the used space.

For 64-byte logical sectors, no other value but 0 is the size code. 255 is not a valid size code at all.

The drive reports a logical sector size correctly as part of this same command's response, regardless what this byte shows, which means the drive firmware is actually reading the size code byte itself from somewhere, and it contains the expected value, not this value.

So whatever this byte is, it's not the logical sector size code.  

