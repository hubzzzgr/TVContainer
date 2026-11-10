import pathlib
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile

HARNESS = pathlib.Path(sys.argv.pop(1)).resolve()


class ArchiveTests(unittest.TestCase):
    def extract(self, name, *, symlink=False, truncated=False):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            archive = root / 'app.ipa'
            with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as output:
                item = zipfile.ZipInfo(name)
                if symlink:
                    item.create_system = 3
                    item.external_attr = (stat.S_IFLNK | 0o777) << 16
                output.writestr(item, b'target' if symlink else b'test app')
            if truncated:
                archive.write_bytes(archive.read_bytes()[:40])
            destination = root / 'stage'
            destination.mkdir()
            result = subprocess.run([str(HARNESS), str(archive), str(destination)])
            escaped = root / 'escaped'
            self.assertFalse(escaped.exists())
            return result.returncode, (destination / 'Payload/App.app/data').exists()

    def test_normal_ipa(self):
        status, exists = self.extract('Payload/App.app/data')
        self.assertEqual(status, 0)
        self.assertTrue(exists)

    def test_parent_traversal(self):
        self.assertNotEqual(self.extract('../escaped')[0], 0)

    def test_absolute_path(self):
        self.assertNotEqual(self.extract('/tmp/tvcontainer-escaped')[0], 0)

    def test_symlink(self):
        self.assertNotEqual(self.extract('Payload/App.app/link', symlink=True)[0], 0)

    def test_truncated_archive(self):
        self.assertNotEqual(self.extract('Payload/App.app/data', truncated=True)[0], 0)


if __name__ == '__main__':
    unittest.main()
