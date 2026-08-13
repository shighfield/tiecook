FPC=fpc
FLAGS=-Mobjfpc -Sh -O2 -FUunits -CX -XX

MINGW_SYSROOT=/usr/x86_64-w64-mingw32/bin
WIN_DLLS=libssl-1_1-x64.dll libcrypto-1_1-x64.dll libssp-0.dll

.PHONY: clean windows

tiecook: tiecook.pas uconfig.pas uapi.pas umodels.pas ufv.pas
	mkdir -p units
	$(FPC) $(FLAGS) tiecook.pas

windows: tiecook.pas uconfig.pas uapi.pas umodels.pas ufv.pas
	mkdir -p units-win64
	$(FPC) $(FLAGS) -Twin64 -FUunits-win64 tiecook.pas -otiecook.exe
	for dll in $(WIN_DLLS); do cp $(MINGW_SYSROOT)/$$dll .; done

clean:
	rm -rf units units-win64 *.o *.ppu tiecook tiecook.exe $(WIN_DLLS)
