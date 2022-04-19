# Connecting a TPDD drive to a PC.
You will need:

* A working [TPDD drive](http://tandy.wiki/TPDD)  
If your drive doesn't work, see the section about the belt.

* The [special cable](http://tandy.wiki/TPDD#Cable) that came with it, or you can [build one](https://github.com/bkw777/TPDD_Cable), or you may possibly be able to buy one from arcadeshopper.com

* Some 720K disks. Not 1.44M

* Some form of serial port. Either an old motherboard or laptop that has real com ports, or a usb-serial adapter, preferrably with [FTDI chip and nuts](http://tandy.wiki/Model_T_Serial_Cable#USB-Serial_Adapters) not screws.

* Serial cable adapters to go from the PC's 9-pin male connector to the tpdd cables's 25-pin male connector.

## Serial Cable Adapters
The tpdd cable expects to be plugged in to a female 25 pin DTE port. This is an uncommon combination. PC serial ports may be either 9 or 25 pins (usually 9), always DTE and always male.

If you had an old IBM XT or AT clone with a 25 pin serial port, that would be 25 pin, male DTE, and all you'd need to connect the TPDD cable is a 25 pin female-female gender-changer.

Most desktop/server motherboards that have any com ports, and most usb-serial adapters, have 9-pin male DTE ports. So for those you need a 9f-25m adapter and a 25f-25f gender-changer.

Assuming you have a motherboard or usb-serial adapter with a 9-pin male connector, here's what you need...

----

If you can find one, the simplest is a DE9F to DB25F straight-through adapter. These are not common.  
https://www.jensentools.com/pan-pacific-ad-d25f9f-a-serial-adapter-db-9f-to-db-25f/p/502-600

You may possibly get lucky on ebay but be careful and make sure you're getting 9-female to 25-male, straight-through NOT null-modem. Also make sure the 9-pin side has screws not nuts. Nuts would get in the way with the nuts on the usb-serial adapter or motherboard com port. Most 9-25 adapters will NOT be right.

If you can find one, then that single adapter does the whole job, and you can skip the rest of this file.

----

Otherwise, it's probably easier to find a combination of one of each  
* 9 pin female to 25 pin male adapter or cable, straight through or "modem", NOT null-modem  
* 25 pin female to 25 pin female gender-changer, also straight through not null-modem

You may already have a DE9F to DB25M adapter like this. It may even have come with your usb-serial adapter.  
https://www.amazon.com/dp/B00066HOWK

Or a DE9F to DB25M "modem" cable like this. They come with external modems.  
https://www.amazon.com/dp/B002I9XYCC

Yet another option is there are some usb-serial adapters that have a male 25 pin connector.  
https://www.amazon.com/dp/B01AT2FTOU  
note this one has FTDI chip, don't get Prolific if you can avoid it

----

Then lastly you just need to add a 25 pin female to female gender changer. Just gender-changer, not null-modem.  
https://www.amazon.com/dp/B0006IEV6U
