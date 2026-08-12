FPC=fpc
FLAGS=-Mobjfpc -Sh -O2 -FUunits -CX -XX

.PHONY: clean

tiecook: tiecook.pas uconfig.pas uapi.pas umodels.pas utui.pas
	mkdir -p units
	$(FPC) $(FLAGS) tiecook.pas

clean:
	rm -rf units *.o *.ppu tiecook
