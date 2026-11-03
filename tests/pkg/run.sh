#!/bin/sh
# The own packages (pkg/build.sh) in a throwaway Void container (tests/pkg/pkg_test.sh).
#   sh tests/pkg/run.sh
set -eu
# macOS tar: no AppleDouble ("._name") files for the extended attributes
export COPYFILE_DISABLE=1
repo=$(cd "$(dirname "$0")/../.." && pwd)
img=$(sh "$repo/tests/docker/build.sh")
# the repository's files as git has them (the packages carry /root/vh), and the commit's time
# from a list, not through xargs: on Linux it splits a long list into several archives, and the
# reader stops at the end of the first
git -C "$repo" ls-files -z --cached --others --exclude-standard | (cd "$repo" && tar -cf - --no-recursion --null -T -) |
	docker run --rm -i "$img" bash -c 'mkdir -p /src && cd /src && tar -xf - 2>/dev/null && bash /src/tests/pkg/pkg_test.sh /src'
