
SOURCES = pdd.sh
PREFIX = /usr/local

PHONY: all
all: $(SOURCES)

install: all
	install -d $(PREFIX)/bin/
	@for i in $(SOURCES) ;do install -v -T -m 755 $${i} $(PREFIX)/bin/$${i%.*} ;done
