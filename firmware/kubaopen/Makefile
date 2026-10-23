CC ?= cc
CFLAGS ?= -std=c99 -Wall -Wextra -Werror -O2 -fsanitize=address,undefined

test: test/test_kubaopen
	./test/test_kubaopen

test/test_kubaopen: kubaopen.c kubaopen.h kubaopen_hal.h test/test_kubaopen.c
	$(CC) $(CFLAGS) -o $@ kubaopen.c test/test_kubaopen.c

clean:
	rm -f test/test_kubaopen

.PHONY: test clean
