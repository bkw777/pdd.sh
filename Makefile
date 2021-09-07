
NAME = pdd
SOURCE = $(NAME).sh

PREFIX = /usr/local
BINDIR = $(PREFIX)/bin

PHONY: all
all: $(SOURCE)

install: all
	@install -v -m 755 -D $(SOURCE) $(BINDIR)/$(NAME) && cd $(BINDIR) && { ln -svf $(NAME) $(NAME)1 ;ln -svf $(NAME) $(NAME)2 ; }

PHONY: uninstall
uninstall:
	@rm -v $(BINDIR)/$(NAME){,1,2}
