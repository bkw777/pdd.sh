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

### Bash globbing expansion tricks to read all sectors at once
...until the program provides this itself

Read the Sector ID Data for all 80 physical sectors at once:  
```
$ ./pdd ri 0 \;ri\ {1..79}
Physical Sector  0 | Length 64 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector  1 | Length 64 | ID_Data ff 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector  2 | Length 64 | ID_Data ff 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector  3 | Length 64 | ID_Data ff 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector  4 | Length 64 | ID_Data 05 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector  5 | Length 64 | ID_Data ff 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector  6 | Length 64 | ID_Data 07 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector  7 | Length 64 | ID_Data 08 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector  8 | Length 64 | ID_Data 09 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector  9 | Length 64 | ID_Data 0a 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 10 | Length 64 | ID_Data ff 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 11 | Length 64 | ID_Data 0c 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 12 | Length 64 | ID_Data 0d 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 13 | Length 64 | ID_Data 0e 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 14 | Length 64 | ID_Data 0f 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 15 | Length 64 | ID_Data 10 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 16 | Length 64 | ID_Data 11 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 17 | Length 64 | ID_Data 12 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 18 | Length 64 | ID_Data 13 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 19 | Length 64 | ID_Data 14 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 20 | Length 64 | ID_Data 15 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 21 | Length 64 | ID_Data 16 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 22 | Length 64 | ID_Data 17 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 23 | Length 64 | ID_Data 18 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 24 | Length 64 | ID_Data 19 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 25 | Length 64 | ID_Data 1a 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 26 | Length 64 | ID_Data 1b 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 27 | Length 64 | ID_Data 1c 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 28 | Length 64 | ID_Data 1d 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 29 | Length 64 | ID_Data 1e 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 30 | Length 64 | ID_Data 1f 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 31 | Length 64 | ID_Data 20 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 32 | Length 64 | ID_Data 21 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 33 | Length 64 | ID_Data 22 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 34 | Length 64 | ID_Data 23 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 35 | Length 64 | ID_Data 24 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 36 | Length 64 | ID_Data 25 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 37 | Length 64 | ID_Data 26 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 38 | Length 64 | ID_Data 27 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 39 | Length 64 | ID_Data 28 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 40 | Length 64 | ID_Data 29 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 41 | Length 64 | ID_Data 2a 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 42 | Length 64 | ID_Data 2b 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 43 | Length 64 | ID_Data 2c 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 44 | Length 64 | ID_Data 2d 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 45 | Length 64 | ID_Data 2e 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 46 | Length 64 | ID_Data 2f 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 47 | Length 64 | ID_Data 30 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 48 | Length 64 | ID_Data 31 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 49 | Length 64 | ID_Data 32 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 50 | Length 64 | ID_Data 33 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 51 | Length 64 | ID_Data 34 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 52 | Length 64 | ID_Data 35 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 53 | Length 64 | ID_Data 36 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 54 | Length 64 | ID_Data 37 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 55 | Length 64 | ID_Data 38 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 56 | Length 64 | ID_Data 39 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 57 | Length 64 | ID_Data 3a 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 58 | Length 64 | ID_Data 3b 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 59 | Length 64 | ID_Data 3c 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 60 | Length 64 | ID_Data 3d 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 61 | Length 64 | ID_Data 3e 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 62 | Length 64 | ID_Data ff 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 63 | Length 64 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 64 | Length 64 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 65 | Length 64 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 66 | Length 64 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 67 | Length 64 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 68 | Length 64 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 69 | Length 64 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 70 | Length 64 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 71 | Length 64 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 72 | Length 64 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 73 | Length 64 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 74 | Length 64 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 75 | Length 64 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 76 | Length 64 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 77 | Length 64 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 78 | Length 64 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
Physical Sector 79 | Length 64 | ID_Data 00 00 00 00 00 00 00 00 00 00 00 00 00
$
```

Read all 20 logical sectors for a physical sector.  
* Assuming the disk is formatted with 64-byte logical sectors as most ordinary disks are. (but for example, the TPDD1 Utility Disk is formatted with 1280-byte logical sectors and only has 1 logical sector per physical sector, not 20)  
* Assuming you want to read physical sector 4  
Note the 2 places where "4" appears on the command line

```
$ ./pdd rs 4 1 \;rs\ 4\ {2..20}
Physical  4 | Logical  1 | Length   64
1c ed 34 08 1c ed cd 81 5a 21 65 f5 11 5e f6 3e 06 cd 6a 5a 21 ff ff 22 7d f6 23 39 22 5a f5 cd 55 ee 2a 5a f5 f9 cd 5c 42 af 32 b0 fa cd 4e 42 06 36 21 a1 fd 22 d7 fd 36 ff 23 05 c2 4e ed 68
Physical  4 | Logical  2 | Length   64
0e c0 cd 7b 59 0e 80 cd 7b 59 0e a0 cd 7b 59 7d 3d 32 ef fd f5 fe 12 ca 8d ed cd d4 59 e5 21 22 5b cd 60 5a e1 2c 7d fe 13 c2 70 ed f1 fa 8d ed af 32 ee fd cd e0 f4 21 07 18 cd 99 42 cd f8 7d
Physical  4 | Logical  3 | Length   64
21 08 01 cd 99 42 21 69 ee cd 60 5a 21 01 1c cd 99 42 21 5c ee cd 60 5a af 30 32 6d ff cd 75 5d cd 75 72 da dd ed fe 0d ca db ed fe 20 da 26 ee ca 24 ee cd 46 42 c3 b3 ed ca 38 ed cd a0 ee cd
Physical  4 | Logical  4 | Length   64
e8 ee c3 38 ed 3e 02 f5 21 38 ed 22 55 f6 f1 21 cf ed e5 21 00 00 39 22 5c f5 3d fa 35 ef ca 18 f2 3d 3d fa eb f0 ca 1d f5 3d 3d fa 80 f4 ca ef f4 3d ca a9 f4 3d c2 c9 ed cd 46 ee 21 18 ee c3
Physical  4 | Logical  5 | Length   64
a2 57 31 3a a7 30 2c b7 52 41 4d 3a ba 00 3e 1c f5 3a ee fd 5f f1 d6 1c 01 b3 ed c5 f8 01 ce 58 c5 ca f6 58 3d ca ed 58 c1 3d ca e6 58 c3 c1 58 21 65 f5 7e fe 4d da f0 17 23 16 02 c3 f0 17 21
Physical  4 | Logical  6 | Length   64
91 ee 37 c3 f0 17 44 53 4b 4d 47 52 20 76 33 2e 30 32 00 4c 69 73 74 20 4c 6f 61 64 20 53 61 76 65 20 53 76 61 6c 20 45 72 61 73 20 4b 69 6c 6c 20 46 72 6d 74 20 4d 65 6e 75 00 39 38 4e 31 44
Physical  4 | Logical  7 | Length   64
00 26 2e 2b 7c b5 c2 99 ee c9 f5 cd e5 f4 f1 21 03 ef 4f 7e 23 a7 c2 a9 ee 0d c2 a9 ee cd 60 5a c3 46 42 3e 03 21 3e 02 21 3e 01 21 3e 04 21 3e 05 21 3e 06 21 3e 07 21 3e 08 21 3e 09 21 3e 0a
Physical  4 | Logical  8 | Length   64
21 3e 0b 21 3e 0c 21 3e 0d 2a 5c f5 f9 6f af 30 b5 c9 3a 3d f6 fe 04 c8 21 2c ef cd 60 5a 21 50 5f cd 60 5a 21 03 00 cd 60 5a c3 34 5f 00 4f 6b 20 00 4e 52 00 43 4d 00 41 42 00 46 46 00 41 45
Physical  4 | Logical  9 | Length   64
00 4f 4d 00 57 50 00 48 54 00 49 4f 00 4e 44 00 42 46 00 46 45 00 20 45 72 72 6f 72 21 20 00 cd 65 ef 3e 01 32 6c f5 4f cd 4e 42 cd 91 f0 06 0a c5 cd 6b f0 c1 0e 02 05 c2 46 ef 21 08 01 cd 99
Physical  4 | Logical 10 | Length   64
42 21 c7 f0 cd 83 f1 0e 02 ca 3e ef c3 24 f2 cd 97 ee cd dd ef 21 07 00 cd a5 ef cd 9f 76 cd 9f ef 30 cd 74 6d ca bc ee 4f 21 88 f5 cd 85 6d c2 b9 ee 77 23 0d c2 82 ef 3a 88 f5 fe 12 c8 fe 43
Physical  4 | Logical 11 | Length   64
c2 d1 ee 01 31 4d cd 68 f4 cd d8 ef c3 97 ee 22 6a f5 21 6a f5 e5 7e 23 86 47 7e f5 23 a7 ca c0 ef 4f 78 86 23 0d c2 b9 ef 47 78 2f 57 01 5a 5a cd 68 f4 c1 04 04 e1 7e cd da ef 23 05 c2 cd ef
Physical  4 | Logical 12 | Length   64
7a 21 3e 0d cd 39 6e db bb e6 20 c8 c3 bc ee 21 6a f5 cd 9f 76 e5 cd 14 f0 cd 14 f0 4f cd 14 f0 41 79 a7 ca 03 f0 cd 14 f0 0d c2 fc ef e1 04 04 af 30 86 23 05 c2 08 f0 2f be c2 b9 ee c9 cd dd
Physical  4 | Logical 13 | Length   64
ef cd 85 6d da c2 ee c2 b9 ee 77 23 c9 21 88 f5 cd e8 ef 3a 8a f5 a7 c9 cd 65 ef 0e 00 61 2e 46 22 84 f5 21 00 1a cd a5 ef cd 23 f0 4f 3a 88 f5 fe 12 79 c0 e6 f0 ca bf ee fe 10 ca c5 ee fe 40
Physical  4 | Logical 14 | Length   64
ca d4 ee fe 50 ca ce ee fe 60 ca cb ee fe 70 ca d7 ee c3 d1 ee cd 33 f0 af 32 96 f5 21 8a f5 b6 ca 9a f0 cd 60 5a 3a 3d f6 f5 2a a3 f5 7c 65 6f cd ee 39 f1 c6 07 fe 1e da 96 f0 cd 3f 42 3e 03
Physical  4 | Logical 15 | Length   64
32 3d f6 c9 cd 3f 42 3a a5 f5 6f 26 00 11 80 00 cd 3f 37 cd ee 39 3e 30 e7 21 e4 7e cd 60 5a 21 08 01 cd 99 42 21 c7 f0 cd 83 f1 ca 38 ed c3 24 f2 4e 61 6d 65 20 6f 6e 20 64 69 73 6b 3a 00 3a
Physical  4 | Logical 16 | Length   64
ee fd 21 a1 fd 11 02 00 b7 ca e7 f0 19 3d c3 de f0 cd ec 5a c9 cd d5 f0 22 60 f5 cd be f1 78 b1 ca dd ee c5 21 c7 f0 cd 7b f1 da fa f0 2a 60 f5 ca 0f f1 11 88 f6 c3 14 f1 54 5d 13 13 13 01 09
Physical  4 | Logical 17 | Length   64
00 09 cd e8 f3 cd 2e f0 a7 ca 32 f1 cd 48 f4 ca 38 ed cd 1c f4 cd 31 f0 a7 c2 c8 ee 3e 01 cd fa f1 2a 60 f5 cd eb 5a c1 af 32 5e f5 11 6c f5 7e 12 23 13 0b 3a 5e f5 3c 32 5e f5 f5 78 b1 ca 5e
Physical  4 | Logical 18 | Length   64
f1 f1 fe 80 da 45 f1 fe f1 e5 67 2e 04 d5 c5 cd 20 f4 c1 d1 e1 78 b1 c2 3e f1 cd 76 f1 c3 bf ee 2e 02 c3 1e f4 11 07 01 eb cd 99 42 eb cd 7a 42 cd 60 5a cd 39 46 da c2 ee 21 bb f1 e5 21 88 f6
Physical  4 | Logical 19 | Length   64
7e 4f a7 c8 fe 3b d8 fe 61 da aa f1 fe 7b d2 aa f1 e6 df 77 23 7e a7 c8 fe 3a c2 b5 f1 37 c9 fe 20 d8 c3 9d f1 0c 0d c9 e5 cd eb 5a d1 1a e6 20 c2 e8 f1 1a e6 40 c2 dc f1 e5 cd f6 05 c1 7d 91
Physical  4 | Logical 20 | Length   64
4f 7c 98 47 0b c9 3e 1a 01 ff ff be 23 03 c2 e1 f1 c9 1a e6 10 c2 c5 ee 23 23 4e 23 46 03 03 03 03 03 03 c9 32 6c f5 21 01 01 cd a5 ef cd 23 f0 c8 c3 4a f0 4e 61 6d 65 20 66 6f 72 20 52 41 4d
$
```
