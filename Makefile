SHELL := /bin/bash
SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC := $(shell xcrun --sdk iphoneos --find clang)
CFLAGS := -arch arm64 -isysroot $(SDK) -miphoneos-version-min=15.0 -O2 -fobjc-arc -fmodules -Wall -Wextra -Wno-unused-parameter -Ivendor/fishhook -Isrc
SOURCES := src/PDGate.m src/PDRedirect.m src/PDHooks.m src/PDDiagnostics.m vendor/fishhook/fishhook.c
FRAMEWORKS := -framework Foundation -framework UIKit -framework UniformTypeIdentifiers
LDFLAGS := -dynamiclib -Wl,-install_name,@rpath/SideloadPersist.dylib
.PHONY: all clean
all: dist/SideloadPersist.dylib
dist/SideloadPersist.dylib: $(SOURCES) src/PDRedirect.h
	mkdir -p dist
	$(CC) $(CFLAGS) $(LDFLAGS) $(FRAMEWORKS) $(SOURCES) -o $@
clean:
	rm -rf dist
