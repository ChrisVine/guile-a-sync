#!/bin/sh

LD_LIBRARY_PATH=../lib:../lib/.libs:$LD_LIBRARY_PATH
# cater for Mac OS
DYLD_LIBRARY_PATH=../lib:../lib/.libs:$DYLD_LIBRARY_PATH
export LD_LIBRARY_PATH DYLD_LIBRARY_PATH
# call up guile directly rather than via the guild shell script: with
# luck, with Mac OS the guile binary will be in a non-protected
# directory
guile --no-auto-compile -c "(let () (add-to-load-path \"..\")(compile-file \"$1\" #:output-file \"$2\"))"
