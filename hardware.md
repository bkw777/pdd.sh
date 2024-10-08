# Connecting a TPDD drive to a PC.
You will need:

* A working [TPDD drive](http://tandy.wiki/TPDD)  
If your drive doesn't work, see the section about the belt.

* The [special cable](http://tandy.wiki/TPDD#Cable) that came with it, or you can [build one](https://github.com/bkw777/TPDD_Cable), or you may possibly be able to buy one from [arcadeshopper](https://arcadeshopper.ecwid.com/#!/Special-serial-cable-for-Tandy-Portable-Disk-Drive-and-Tandy-Portable-Disk-Drive-2/p/144969001/category=28313042) or [soigeneris](https://www.soigeneris.com/tpdd2_cable)

* Some [720K disks](https://www.ebay.com/sch/i.html?_nkw=720+floppy). Not 1.44M

* A serial port. Either an old machine that has a real com port, or a [usb-serial adapter](http://tandy.wiki/Model_T_Serial_Cable#USB-Serial_Adapters), preferrably with FTDI chip, ideally with nuts not screws.

* Serial cable adapter(s) to go from the PC's 9-pin male connector to the tpdd cables's 25-pin male connector, straight through, not null-modem.

## Serial Cable Adapter(s)
There is more than one way to get there...

The tpdd drive special cable is designed to be connected to the female 25 pin DTE port found on all the KC-85 clone machines (TRS-80 Model 100 etc). This is an uncommon combination of properties. PC serial ports may be either 9 or 25 pins (usually 9), always DTE and always male.

If you had an old IBM XT or AT clone with a 25 pin serial port, that would be 25 pin, male DTE, and all you would need in order to connect the TPDD cable is a 25 pin female-female gender-changer.

Most desktop/server motherboards that have any com ports, and most usb-serial adapters, have 9-pin male DTE ports. So for those you need a 9f-25m adapter and a 25f-25f gender-changer.

Assuming you have a motherboard com port or usb-serial adapter with a 9-pin male connector, here's what you need...

----

If you can find one, the simplest is a single DE9F to DB25F straight-through adapter. These are not too common, but here are a couple.  
[Startech AT925FF](https://www.amazon.com/dp/B00066HJCA/)  
[Pan Pacific AD-D25F9F-A](https://www.jensentools.com/pan-pacific-ad-d25f9f-a-serial-adapter-db-9f-to-db-25f/p/502-600)

You may possibly get lucky on ebay but be careful and make sure you're getting female to female, and straight-through NOT null-modem. Also make sure the 9-pin side has screws not nuts. Nuts would get in the way with the nuts on the usb-serial adapter or motherboard com port and you wouldn't be able to plug it in. Most random 9-25 adapters you find will not work.

If you can get one of those adapters, that's it, skip the rest of this file.

----

Alternatively, if you can't find one of the adapters above, it may be easier to find a combination of one of each of the following  
* 9 pin female to 25 pin male adapter or cable, straight through or "modem", NOT null-modem  
* 25 pin female to 25 pin female gender-changer, also straight through not null-modem

For the 9-25 part, any one of these 3 examples works:

You may already have a DE9F to DB25M adapter like this. It may even have come with your usb-serial adapter.  
https://www.amazon.com/dp/B00066HOWK

Or you may already have a DE9F to DB25M "modem" cable like this. They come with external modems.  
https://www.amazon.com/dp/B002I9XYCC

Yet another option is there are some usb-serial adapters that have a male 25 pin connector.  
https://www.amazon.com/dp/B01AT2FTOU  
note this one has an FTDI chip, don't get Prolific if you can avoid it

----

Then lastly you just need to add a 25 pin female to female gender changer. Just gender-changer, not null-modem.  
https://www.amazon.com/dp/B0006IEV6U
