#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
if [[ ! -d build/slink.app ]]; then
    ./build.sh
fi
open "$PWD/build/slink.app"
