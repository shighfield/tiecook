# tiecook — standalone recipe library: import, then browse
#
# The native x86_64 ppcx64 targets win64 directly; FPC's internal linker
# emits the PE, so `make win` needs no mingw toolchain. The Tandoor importer
# links OpenSSL, so `make win` also copies the OpenSSL 1.1 DLLs the exe loads
# at runtime (from the mingw-w64 sysroot; needs the mingw-w64-openssl-1.1 AUR
# package). Ship all four files together.

FPC     ?= fpc
MAIN    := tiecook.pas
OPTS    := -Mobjfpc -Sh -O2 -vw
BIN     := tiecook
WINBIN  := tiecook.exe

MINGW_SYSROOT := /usr/x86_64-w64-mingw32/bin
WIN_DLLS := libssl-1_1-x64.dll libcrypto-1_1-x64.dll libssp-0.dll

# Linking OpenSSL pulls in libc, so the native link needs gcc's crt*.o. Ask
# gcc where they are (the versioned dir moves with gcc updates).
GCCLIB := $(shell dirname $$(gcc -print-file-name=crtendS.o))

.PHONY: all linux win installer run test clean

all: linux

linux: $(BIN)
$(BIN): *.pas
	@mkdir -p units
	$(FPC) $(OPTS) -FUunits -Fl$(GCCLIB) -o$(BIN) $(MAIN)

win: $(WINBIN)
$(WINBIN): *.pas
	@mkdir -p units-win64
	$(FPC) -Twin64 $(OPTS) -FUunits-win64 -o$(WINBIN) $(MAIN)
	@for dll in $(WIN_DLLS); do cp -u $(MINGW_SYSROOT)/$$dll . ; done

# Windows installer: tiecook-setup.exe (needs makensis). Builds the Windows
# exe + DLLs first, then packages them with config.example.
installer: win config.example installer.nsi
	makensis installer.nsi

run: linux
	./$(BIN)

test:
	@bash test/run_tests.sh

clean:
	rm -rf units units-win64 $(BIN) $(WINBIN) $(WIN_DLLS) tiecook-setup.exe test/.build
