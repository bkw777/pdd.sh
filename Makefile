
NAME = pdd
SOURCE = $(NAME).sh

PREFIX = /usr/local
BINDIR = $(PREFIX)/bin

PHONY: all
all: $(SOURCE)

install: all
	@mkdir -p $(BINDIR)
	@install -v -o root -m 755 $(SOURCE) $(BINDIR)/$(NAME) && cd $(BINDIR) && { ln -svf $(NAME) $(NAME)1 ;ln -svf $(NAME) $(NAME)2 ; }

PHONY: uninstall
uninstall:
	@rm -v $(BINDIR)/$(NAME) $(BINDIR)/$(NAME)1 $(BINDIR)/$(NAME)2
