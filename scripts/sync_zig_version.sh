#!/bin/sh
set -e

# Read version from argument if provided, otherwise from VERSION file
if [ -n "$1" ]; then
  VERSION="$1"
else
  VERSION=$(cat VERSION)
fi

# Remove 'v' prefix if present
VERSION=${VERSION#v}

# Update build.zig.zon
# Assuming the line format is: .version = "0.0.0",
sed -i.bak "s/\.version = \".*\"/.version = \"$VERSION\"/" build.zig.zon
rm build.zig.zon.bak

echo "Updated build.zig.zon to version $VERSION"
