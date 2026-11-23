#!/bin/sh
# rebuild replica: live schema + post-export migrations + seed data
cd "$(dirname "$0")"
python3 load.py "$@" | grep -vE "0 failed" ; python3 seed.py
