#!/bin/bash
set -euo pipefail
archive_path="${archive_path:-build/TVContainer.xcarchive}"
ipa_name="${ipa_name:-TVContainer.ipa}"
app="$archive_path/Products/Applications/TVContainer.app"
test -d "$app"
python3 tests/validate_bundle.py "$app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$app/Info.plist")" = AppleTVOS
mkdir -p build/package/Payload
ditto "$app" build/package/Payload/TVContainer.app
(cd build/package && /usr/bin/zip -qry "../$ipa_name" Payload)
echo "Created build/$ipa_name (unsigned; sign with a tvOS development profile before installation)"
