# tiecook2 — standalone recipe library: import, then browse
#
# The native x86_64 ppcx64 targets win64 directly; FPC's internal linker
# emits the PE, so `make win` needs no mingw toolchain.

FPC     ?= fpc
MAIN    := tiecook2.pas
OPTS    := -Mobjfpc -Sh -O2 -vw
BIN     := tiecook2
WINBIN  := tiecook2.exe

.PHONY: all linux win run test clean

all: linux

linux: $(BIN)
$(BIN): *.pas
	@mkdir -p units
	$(FPC) $(OPTS) -FUunits -o$(BIN) $(MAIN)

win: $(WINBIN)
$(WINBIN): *.pas
	@mkdir -p units-win64
	$(FPC) -Twin64 $(OPTS) -FUunits-win64 -o$(WINBIN) $(MAIN)

run: linux
	./$(BIN)

test:
	@bash test/run_tests.sh

clean:
	rm -rf units units-win64 $(BIN) $(WINBIN) test/.build
