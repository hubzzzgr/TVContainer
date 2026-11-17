"""Verify the packaged configuration keeps the ID and isolates debug-only UI."""
import pathlib
import plistlib
import sys

app = pathlib.Path(sys.argv[1])
debug = sys.argv[2] == "Debug"
info = plistlib.loads((app / "Info.plist").read_bytes())
assert info["CFBundleIdentifier"] == "com.hubzzzgr.tvcontainer"
ui = (app / "Frameworks/LiveContainerSwiftUI.framework/LiveContainerSwiftUI").read_bytes()
assert (b"No captured crashes." in ui) == debug, "Crash menu configuration mismatch"
runtime = (app / "Frameworks/LiveContainerShared.framework/LiveContainerShared").read_bytes()
assert (b"Fault address:" in runtime) == debug, "Crash capture configuration mismatch"
print(f"Validated {sys.argv[2]} crash logging configuration and shared application ID.")
