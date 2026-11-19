TARGET := iphone:clang:latest:15.0
ARCHS = arm64
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = LockLyrics

LockLyrics_FILES = $(wildcard src/*.m)
LockLyrics_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -O2
LockLyrics_FRAMEWORKS = Foundation UIKit MediaPlayer CoreImage CoreGraphics
LockLyrics_LDFLAGS = -Wl,-install_name,@rpath/LockLyrics.dylib

include $(THEOS_MAKE_PATH)/library.mk
