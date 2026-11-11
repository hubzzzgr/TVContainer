import pathlib
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

HARNESS = pathlib.Path(sys.argv.pop(1)).resolve()
SCENEBOX = pathlib.Path(sys.argv.pop(1)) if len(sys.argv) > 1 else None

def thin(platform=3, cpu=0x100000c):
    section = struct.pack('<16s16sQQIIIIIIII', b'__text', b'__TEXT', 512, 1, 512, 0, 0, 0, 0, 0, 0, 0)
    segment = struct.pack('<II16sQQQQiiII', 0x19, 152, b'__TEXT', 0, 1024, 0, 1024, 7, 5, 1, 0) + section
    commands = segment + struct.pack('<IIQQ', 0x80000028, 24, 512, 0) + struct.pack('<IIIIII', 0x32, 24, platform, 0x110000, 0x110000, 0)
    return (struct.pack('<IIIIIIII', 0xfeedfacf, cpu, 0, 2, 3, len(commands), 0, 0) + commands).ljust(1024, b'\0')

def fat(payload, wide=False, endian='>'):
    header = struct.pack(endian + 'II', 0xcafebabf if wide else 0xcafebabe, 1)
    record = struct.pack(endian + ('IIQQII' if wide else 'IIIII'), 0x100000c, 0, 0x4000, len(payload), 14, *([0] if wide else []))
    return (header + record).ljust(0x4000, b'\0') + payload

class ExecutableTests(unittest.TestCase):
    def prepare(self, content, main=True):
        with tempfile.TemporaryDirectory() as directory:
            file = pathlib.Path(directory) / 'binary'
            file.write_bytes(content)
            result = subprocess.run([str(HARNESS), str(file), str(int(main))], capture_output=True, text=True)
            return result, file.read_bytes()

    def test_thin_and_all_universal_formats(self):
        for wide in (False, True):
            for endian in ('>', '<'):
                result, output = self.prepare(fat(thin(), wide, endian))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output, thin())
        self.assertEqual(self.prepare(thin())[1], thin())

    def test_platform_and_architecture_rejected(self):
        for content in (thin(2), thin(7), thin(cpu=0x1000007), fat(thin(2))):
            result, output = self.prepare(content)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(output, content)

    def test_truncated_and_overflowing_wrappers(self):
        for content in (b'bad', fat(thin())[:100], struct.pack('>II', 0xcafebabe, 0xffffffff),
                        struct.pack('>IIIIQQII', 0xcafebabf, 1, 0x100000c, 0, 0xfffffffffffffff0, 1024, 14, 0)):
            self.assertNotEqual(self.prepare(content)[0].returncode, 0)

    def test_optional_future_sdk_stub(self):
        content = bytearray(thin())
        struct.pack_into('<I', content, 32 + 152 + 24 + 12, 0x640000)
        self.assertNotEqual(self.prepare(bytes(content), True)[0].returncode, 0)
        self.assertEqual(self.prepare(fat(bytes(content)), False)[0].returncode, 0)

    @unittest.skipUnless(SCENEBOX, 'No SceneBox fixture')
    def test_actual_scenebox_binaries(self):
        tested = wrapped = 0
        with zipfile.ZipFile(SCENEBOX) as ipa:
            for name in ipa.namelist():
                if name.endswith('/'): continue
                content = ipa.read(name)
                if content[:4] not in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe'): continue
                main = name == 'Payload/SceneBox.app/SceneBox'
                result, output = self.prepare(content, main)
                self.assertEqual(result.returncode, 0, name + ': ' + result.stderr)
                if content[:4] == b'\xca\xfe\xba\xbe':
                    offset, length = struct.unpack_from('>II', content, 16)
                    self.assertEqual(output, content[offset:offset + length])
                    wrapped += 1
                tested += 1
        self.assertGreaterEqual(wrapped, 8)
        self.assertGreaterEqual(tested, 9)

unittest.main()
