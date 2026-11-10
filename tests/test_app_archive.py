import io
import pathlib
import subprocess
import sys
import tempfile
import unittest
import zipfile

HARNESS = pathlib.Path(sys.argv.pop(1)).resolve()


def ipa_bytes(apps=1):
    data = io.BytesIO()
    with zipfile.ZipFile(data, 'w', zipfile.ZIP_DEFLATED) as archive:
        for index in range(apps):
            archive.writestr(f'Payload/App{index}.app/Executable', b'guest executable')
    return data.getvalue()


class AppArchiveTests(unittest.TestCase):
    def prepare(self, data, filename='download'):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / filename
            source.write_bytes(data)
            stage = root / 'stage'
            result = subprocess.run([str(HARNESS), str(source), str(stage)], capture_output=True, text=True)
            if result.returncode == 0:
                app = pathlib.Path(result.stdout.strip())
                self.assertEqual((app / 'Executable').read_bytes(), b'guest executable')
                self.assertTrue(app.resolve().is_relative_to(stage.resolve()))
            return result

    def test_direct_ipa(self):
        self.assertEqual(self.prepare(ipa_bytes(), 'testapp.ipa').returncode, 0)

    def test_direct_ipa_without_filename_extension(self):
        self.assertEqual(self.prepare(ipa_bytes()).returncode, 0)

    def test_ipa_with_zip_extension(self):
        self.assertEqual(self.prepare(ipa_bytes(), 'testapp.zip').returncode, 0)

    def test_zip_wrapped_ipa(self):
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('testapp.ipa', ipa_bytes())
        self.assertEqual(self.prepare(data.getvalue(), 'testapp.ipa.zip').returncode, 0)

    def test_ipa_in_wrapper_subfolder(self):
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as archive:
            archive.writestr('Download/TestApp.IPA', ipa_bytes())
        self.assertEqual(self.prepare(data.getvalue()).returncode, 0)

    def test_multiple_wrapped_ipas_rejected(self):
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as archive:
            archive.writestr('one.ipa', ipa_bytes())
            archive.writestr('two.ipa', ipa_bytes())
        self.assertNotEqual(self.prepare(data.getvalue()).returncode, 0)

    def test_multiple_payload_apps_rejected(self):
        self.assertNotEqual(self.prepare(ipa_bytes(apps=2)).returncode, 0)

    def test_html_download_page_rejected(self):
        self.assertNotEqual(self.prepare(b'<html>download page</html>', 'app.ipa').returncode, 0)


if __name__ == '__main__':
    unittest.main()
