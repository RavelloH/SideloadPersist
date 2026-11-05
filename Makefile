SHELL := /bin/bash
SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC := $(shell xcrun --sdk iphoneos --find clang)
CFLAGS := -arch arm64 -isysroot $(SDK) -miphoneos-version-min=15.0 -O2 -fobjc-arc -fmodules -Wall -Wextra -Wno-unused-parameter -DMINIZ_NO_ZLIB_COMPATIBLE_NAMES -Ivendor/miniz -Ivendor/fishhook -Isrc
SOURCES := src/PDEntry.m src/PDIntro.m src/PDGuide.m src/PDStorage.m src/PDPreferencesBackend.m src/PDPreferencesHook.m src/PDReadme.m src/PDExperimentalScope.m src/PDArchive.m src/PDV2Archive.m src/PDV2Restore.m vendor/miniz/miniz.c vendor/miniz/miniz_tdef.c vendor/miniz/miniz_tinfl.c vendor/miniz/miniz_zip.c vendor/fishhook/fishhook.c
FRAMEWORKS := -framework Foundation -framework UIKit -framework UniformTypeIdentifiers -framework Security
LDFLAGS := -dynamiclib -Wl,-install_name,@rpath/SideloadPersist.dylib
.PHONY: all clean
all: dist/SideloadPersist.dylib
dist/SideloadPersist.dylib: $(SOURCES) src/PDStorage.h src/PDPreferencesBackend.h src/PDPreferencesHook.h src/PDReadme.h src/PDExperimentalScope.h src/PDIntro.h src/PDGuide.h src/PDArchive.h src/PDV2Archive.h src/PDV2Restore.h
	mkdir -p dist
	$(CC) $(CFLAGS) $(LDFLAGS) $(FRAMEWORKS) $(SOURCES) -o $@
clean:
	rm -rf dist
