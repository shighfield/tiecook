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

.PHONY: all linux win installer appimage run test clean

APPIMAGETOOL ?= appimagetool

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

# Linux AppImage: tiecook-x86_64.AppImage — a single portable executable for
# people who don't want to build from source. Needs appimagetool (set
# APPIMAGETOOL= if it's not on PATH). The binary itself only needs libc;
# OpenSSL is bundled so "import tandoor" works on any distro.
appimage: linux appimage/AppRun appimage/tiecook.desktop appimage/tiecook.png
	rm -rf AppDir
	mkdir -p AppDir/usr/bin AppDir/usr/lib
	cp $(BIN) AppDir/usr/bin/tiecook
	cp -L /usr/lib/libssl.so.3 /usr/lib/libcrypto.so.3 AppDir/usr/lib/
	install -m755 appimage/AppRun AppDir/AppRun
	cp appimage/tiecook.desktop AppDir/tiecook.desktop
	cp appimage/tiecook.png AppDir/tiecook.png
	ARCH=x86_64 $(APPIMAGETOOL) AppDir tiecook-x86_64.AppImage
	rm -rf AppDir

run: linux
	./$(BIN)

test:
	@bash test/run_tests.sh

clean:
	rm -rf units units-win64 $(BIN) $(WINBIN) $(WIN_DLLS) tiecook-setup.exe \
	       AppDir tiecook-x86_64.AppImage test/.build
