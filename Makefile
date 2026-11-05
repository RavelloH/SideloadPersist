SHELL := /bin/bash
SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC := $(shell xcrun --sdk iphoneos --find clang)
CFLAGS := -arch arm64 -isysroot $(SDK) -miphoneos-version-min=15.0 -O2 -fobjc-arc -fmodules -Wall -Wextra -Wno-unused-parameter -DMINIZ_NO_ZLIB_COMPATIBLE_NAMES -Ivendor/miniz -Isrc
SOURCES := src/PDEntry.m src/PDIntro.m src/PDStorage.m src/PDExperimentalScope.m src/PDArchive.m vendor/miniz/miniz.c vendor/miniz/miniz_tdef.c vendor/miniz/miniz_tinfl.c vendor/miniz/miniz_zip.c
FRAMEWORKS := -framework Foundation -framework UIKit -framework UniformTypeIdentifiers -framework Security
LDFLAGS := -dynamiclib -Wl,-install_name,@rpath/SideloadPersist.dylib
.PHONY: all clean
all: dist/SideloadPersist.dylib
dist/SideloadPersist.dylib: $(SOURCES) src/PDStorage.h src/PDExperimentalScope.h src/PDIntro.h src/PDArchive.h
	mkdir -p dist
	$(CC) $(CFLAGS) $(LDFLAGS) $(FRAMEWORKS) $(SOURCES) -o $@
clean:
	rm -rf dist
