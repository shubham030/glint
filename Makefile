IDF_EXPORT := source $(HOME)/esp/esp-idf-v5.5/export.sh >/dev/null 2>&1

.PHONY: all fw host flash monitor bars hello clean

all: fw host

fw:
	cd firmware && $(IDF_EXPORT) && idf.py build

host:
	cd host && swift build -c release

flash:
	cd firmware && $(IDF_EXPORT) && idf.py -p $(PORT) flash

monitor:
	cd firmware && $(IDF_EXPORT) && idf.py -p $(PORT) monitor

hello: host
	./host/.build/release/vdisp hello

bars: host
	./host/.build/release/vdisp bars --seconds 10 --fps 10

# The virtual display lives exactly as long as this process — keep it in a
# terminal tab (or ask for the LaunchAgent setup to run it at login).
display: host
	./host/.build/release/vdisp display

mirror: host
	./host/.build/release/vdisp mirror --landscape

clean:
	cd firmware && rm -rf build
	cd host && swift package clean
