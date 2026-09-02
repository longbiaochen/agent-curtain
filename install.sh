#!/bin/zsh
set -eu
here=${0:a:h}
exec "$here/script/build_and_run.sh" --install
