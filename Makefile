TESTS_INIT=tests/minimal_init.lua
TESTS_DIR=tests/

.PHONY: build release

# Detect OS and ARCH
UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

# Set default values
TARGET_ARCH :=
DYLIB_EXT :=
RUST_TARGET :=

# macOS detection
ifeq ($(UNAME_S),Darwin)
    ifeq ($(UNAME_M),arm64)
        RUST_TARGET := aarch64-apple-darwin
    else
        RUST_TARGET := x86_64-apple-darwin
    endif
    DYLIB_EXT := dylib
endif

# Linux detection
ifeq ($(UNAME_S),Linux)
    RUST_TARGET := x86_64-unknown-linux-gnu
    DYLIB_EXT := so
endif

# Windows detection (assuming MSYS2/MinGW environment)
ifeq ($(OS),Windows_NT)
    ifeq ($(PROCESSOR_ARCHITECTURE),AMD64)
        RUST_TARGET := x86_64-pc-windows-msvc
    else
        RUST_TARGET := i686-pc-windows-msvc
    endif
    DYLIB_EXT := dll
endif

build:
	@echo "Building for target: $(RUST_TARGET)"
	@if [ -z "$(RUST_TARGET)" ]; then \
		echo "Error: Unsupported platform"; \
		exit 1; \
	fi
	rm -f lua/backend.so && \
	cd cargo/backend && \
	cargo build --target $(RUST_TARGET) && \
	cp target/$(RUST_TARGET)/debug/libbackend.$(DYLIB_EXT) ../../lua/backend.so

release:
	@echo "Building release for target: $(RUST_TARGET)"
	@if [ -z "$(RUST_TARGET)" ]; then \
		echo "Error: Unsupported platform"; \
		exit 1; \
	fi
	rm -f lua/backend.so && \
	cd cargo/backend && \
	cargo build --release --target $(RUST_TARGET) && \
	cp target/$(RUST_TARGET)/release/libbackend.$(DYLIB_EXT) ../../lua/backend.so
