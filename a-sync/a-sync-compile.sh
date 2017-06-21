#!/bin/sh

LD_LIBRARY_PATH=../lib:$LD_LIBRARY_PATH
# cater for Mac OS
DYLD_LIBRARY_PATH=../lib:$DYLD_LIBRARY_PATH
export LD_LIBRARY_PATH DYLD_LIBRARY_PATH
guild compile -L .. -o $1 $2
