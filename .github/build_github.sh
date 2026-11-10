#!/bin/bash
set -euo pipefail
archive_path="${archive_path:-build/TVContainer.xcarchive}"
app="$archive_path/Products/Applications/TVContainer.app"
test -d "$app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$app/Info.plist")" = AppleTVOS
if find "$app" -iname '*sidestore*' -o -name '*.appex' | grep -q .; then
  echo 'Unexpected SideStore component or extension in standalone archive' >&2
  exit 1
fi
mkdir -p build/package/Payload
ditto "$app" build/package/Payload/TVContainer.app
(cd build/package && /usr/bin/zip -qry ../TVContainer.ipa Payload)
echo 'Created build/TVContainer.ipa (unsigned; sign with a tvOS development profile before installation)'
