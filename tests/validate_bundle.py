"""Inspect the actual archived bundle, including runtime-resolved dylib paths."""
import pathlib
import plistlib
import struct
import sys

app = pathlib.Path(sys.argv[1])
required = [
    'TVContainer',
    'Frameworks/LiveContainerShared.framework/LiveContainerShared',
    'Frameworks/LiveContainerSwiftUI.framework/LiveContainerSwiftUI',
    'Frameworks/ZSign.dylib',
    'Frameworks/TweakLoader.dylib',
    'Frameworks/OpenSSL.framework/OpenSSL',
]
info = plistlib.loads((app / 'Info.plist').read_bytes())
assert info['CFBundleDisplayName'] == 'TVContainer'
assert info['CFBundleExecutable'] == 'TVContainer'
assert info['CFBundleSupportedPlatforms'] == ['AppleTVOS']
assert info['UIDeviceFamily'] == [3]
for path in app.rglob('*'):
    assert 'sidestore' not in path.name.lower(), path
    assert path.suffix != '.appex', path

identities = set()
dependencies = []
for relative in required:
    binary = app / relative
    data = binary.read_bytes()
    magic, cpu, _, _, count, command_size, _, _ = struct.unpack_from('<8I', data)
    assert magic == 0xFEEDFACF and cpu == 0x0100000C, binary
    cursor, platform = 32, None
    for _ in range(count):
        command, size = struct.unpack_from('<2I', data, cursor)
        assert size >= 8 and cursor + size <= 32 + command_size, binary
        if command == 0x32:  # LC_BUILD_VERSION
            platform = struct.unpack_from('<I', data, cursor + 8)[0]
        if command in (0xC, 0xD, 0x18 | 0x80000000, 0x1F | 0x80000000):
            offset = struct.unpack_from('<I', data, cursor + 8)[0]
            name = data[cursor + offset:cursor + size].split(b'\0', 1)[0].decode()
            if command == 0xD:
                assert name.startswith('@rpath/'), (binary, name)
                identities.add(name)
            else:
                dependencies.append((binary, name))
        cursor += size
    assert platform == 3, (binary, platform)  # PLATFORM_TVOS

for binary, name in dependencies:
    if name.startswith(('/usr/lib/', '/System/Library/')):
        continue
    assert name in identities, (binary, 'unbundled dependency', name)

print(f'Validated {len(required)} arm64 tvOS binaries, library paths, and standalone bundle contents.')
