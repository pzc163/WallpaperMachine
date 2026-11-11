import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import bundle_creator_libraries as library

class CreatorLibrariesTests(unittest.TestCase):
    def test_reviewed_bundle_verifies_without_network(self):
        with patch('urllib.request.urlopen', side_effect=AssertionError('Offline verifier made a request')):
            self.assertEqual(library.verify()['version'],'0.180.0')
    def test_changed_bundle_fails_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            (root/'manifest.json').write_text(json.dumps({'bundleSHA256':hashlib.sha256(b'original').hexdigest()}))
            (root/'wm-three-r180.js').write_bytes(b'changed')
            with patch.object(library,'VENDOR',root),self.assertRaises(ValueError): library.verify()
    def test_bad_archive_integrity_prevents_extraction(self):
        from io import BytesIO
        with tempfile.TemporaryDirectory() as folder,patch('urllib.request.urlopen',return_value=BytesIO(b'changed')):
            with self.assertRaises(ValueError):
                library.fetch({'url':'https://fixture.invalid','integrity':'sha512-invalid'},Path(folder)/'package')
            self.assertFalse((Path(folder)/'package').exists())

if __name__=='__main__': unittest.main()
