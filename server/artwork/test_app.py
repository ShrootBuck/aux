import concurrent.futures
from contextlib import closing
import hashlib
import io
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch
from PIL import Image
from app import create_app


class ArtworkTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.config = dict(TESTING=True, DATA_DIR=self.temp.name, MIN_FREE_BYTES=0)
        self.app = create_app(self.config)
        self.app.logger.disabled = True
        self.client = self.app.test_client()
        response = self.client.post('/v1/installations')
        self.auth = {'Authorization': 'Bearer '+response.json['token']}

    def tearDown(self):
        self.temp.cleanup()

    def image(self, size=(64, 64), color='red'):
        data = io.BytesIO()
        image = Image.new('RGB', size, color)
        exif = Image.Exif()
        exif[270] = 'private metadata'
        image.save(data, 'JPEG', exif=exif)
        return data.getvalue()

    def upload(self, client=None, data=None):
        return (client or self.client).post('/v1/artwork', headers=self.auth, content_type='image/jpeg', data=data or self.image())

    def test_hash_delivery_deduplication_metadata_and_restart(self):
        first = self.upload()
        self.assertEqual(first.status_code, 201)
        path = '/covers/'+first.json['sha256']+'.jpg'
        image = self.client.get(path, buffered=True)
        self.assertEqual(image.status_code, 200)
        self.assertEqual(image.content_type, 'image/jpeg')
        self.assertEqual(hashlib.sha256(image.data).hexdigest(), first.json['sha256'])
        self.assertFalse(Image.open(io.BytesIO(image.data)).getexif())
        self.assertIn('immutable', image.headers['Cache-Control'])
        self.assertEqual(self.client.head(path, buffered=True).data, b'')
        self.assertEqual(self.client.get(path, headers={'If-None-Match': image.headers['ETag']}, buffered=True).status_code, 304)
        restarted = create_app(self.config).test_client()
        self.assertEqual(self.upload(restarted).status_code, 200)
        self.assertEqual(restarted.get(path, buffered=True).data, image.data)
        self.assertEqual(len(list(Path(self.temp.name).glob('covers/*.jpg'))), 1)

    def test_invalid_and_oversized_images(self):
        self.assertEqual(self.upload(data=b'not jpeg').status_code, 422)
        self.assertEqual(self.upload(data=self.image((701, 64))).status_code, 422)
        self.assertEqual(self.upload(data=b'x'*250001).status_code, 413)
        self.assertEqual(self.client.post('/v1/artwork', headers=self.auth, content_type='text/html', data=b'hello').status_code, 415)

    def test_authentication_and_revocation(self):
        self.assertEqual(self.client.post('/v1/artwork', data=self.image()).status_code, 401)
        self.assertEqual(self.client.post('/v1/artwork', headers={'Authorization':'Bearer '+'x'*43}).status_code, 401)
        with closing(sqlite3.connect(Path(self.temp.name)/'artwork.sqlite')) as db:
            db.execute('UPDATE installations SET revoked=1')
            db.commit()
        self.assertEqual(self.upload().status_code, 401)

    def test_limits_persist_and_rejected_images_count(self):
        for _ in range(60):
            self.assertEqual(self.upload(data=b'bad').status_code, 422)
        response = self.upload(create_app(self.config).test_client())
        self.assertEqual(response.status_code, 429)
        self.assertGreater(int(response.headers['Retry-After']), 0)

    def test_registration_limits_and_ip_spoofing(self):
        for _ in range(4):
            self.assertEqual(self.client.post('/v1/installations').status_code, 201)
        # CF headers have no effect when not explicitly enabled behind the tunnel.
        self.assertEqual(self.client.post('/v1/installations', headers={'CF-Connecting-IP':'8.8.8.8'}).status_code, 429)

    def test_capacity_preserves_existing_reads(self):
        response = self.upload()
        self.app.config['MAX_STORAGE_BYTES'] = 0
        self.assertEqual(self.upload(data=self.image((32,32))).status_code, 507)
        self.assertEqual(self.client.get('/covers/'+response.json['sha256']+'.jpg', buffered=True).status_code, 200)
        self.assertEqual(self.upload().status_code, 200)

    def test_oldest_eviction_preserves_newer_images_and_duplicate_age(self):
        uploads = [self.upload(data=self.image(color=color)) for color in ['red', 'green', 'blue']]
        keys = [response.json['sha256'] for response in uploads]
        root = Path(self.temp.name)
        with closing(sqlite3.connect(root/'artwork.sqlite')) as db:
            for age, key in enumerate(keys, 1):
                db.execute('UPDATE objects SET created=? WHERE hash=?', (age, key))
            db.commit()
        # Duplicate uploads must not refresh the oldest image's upload date.
        self.assertEqual(self.upload().status_code, 200)
        sizes = [(root/'covers'/f'{key}.jpg').stat().st_size for key in keys]
        self.config['MAX_STORAGE_BYTES'] = sum(sizes)
        restarted = create_app(self.config).test_client()
        incoming = self.upload(restarted, self.image(color='yellow'))
        self.assertEqual(incoming.status_code, 201)
        self.assertEqual(restarted.get('/covers/'+keys[0]+'.jpg').status_code, 404)
        for key in keys[1:] + [incoming.json['sha256']]:
            self.assertEqual(restarted.get('/covers/'+key+'.jpg', buffered=True).status_code, 200)
        with closing(sqlite3.connect(root/'artwork.sqlite')) as db:
            self.assertLessEqual(db.execute('SELECT SUM(bytes) FROM objects').fetchone()[0], sum(sizes))
        self.assertEqual(len(list((root/'covers').glob('*.jpg'))), 3)

    def test_eviction_removes_multiple_oldest_and_allows_reupload(self):
        first = self.upload()
        self.upload(data=self.image(color='blue'))
        self.upload(data=self.image(color='green'))
        root = Path(self.temp.name)
        self.app.config['MAX_STORAGE_BYTES'] = (root/'covers'/f"{first.json['sha256']}.jpg").stat().st_size
        incoming = self.upload(data=self.image(color='yellow'))
        self.assertEqual(incoming.status_code, 201)
        self.assertEqual(len(list((root/'covers').glob('*.jpg'))), 1)
        restored = self.upload()
        self.assertEqual(restored.status_code, 201)
        self.assertEqual(restored.json['url'], first.json['url'])

    def test_disk_pressure_and_failed_staging_do_not_evict(self):
        first = self.upload()
        self.app.config['MAX_STORAGE_BYTES'] = 350
        with patch('app.shutil.disk_usage') as disk:
            disk.return_value.free = 0
            self.assertEqual(self.upload(data=self.image(color='blue')).status_code, 507)
        with patch('app.os.fsync', side_effect=OSError('write failed')):
            with self.assertRaises(OSError):
                self.upload(data=self.image(color='blue'))
        self.assertEqual(self.client.get('/covers/'+first.json['sha256']+'.jpg', buffered=True).status_code, 200)
        self.assertFalse(list(Path(self.temp.name).glob('covers/.upload-*')))

    def test_exact_capacity_and_invalid_uploads_preserve_images(self):
        first = self.upload()
        path = Path(self.temp.name)/'covers'/f"{first.json['sha256']}.jpg"
        self.app.config['MAX_STORAGE_BYTES'] = path.stat().st_size
        self.assertEqual(self.upload().status_code, 200)
        self.assertEqual(self.upload(data=b'not an image').status_code, 422)
        self.assertTrue(path.is_file())

    def test_concurrent_distinct_uploads_stay_within_capacity(self):
        self.app.config['MAX_STORAGE_BYTES'] = 700
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda color: self.upload(self.app.test_client(), self.image(color=color)),
                                    ['red', 'green', 'blue', 'yellow']))
        self.assertTrue(all(result.status_code == 201 for result in results))
        files = list(Path(self.temp.name).glob('covers/*.jpg'))
        self.assertEqual(len(files), 2)
        self.assertLessEqual(sum(path.stat().st_size for path in files), 700)
        with closing(sqlite3.connect(Path(self.temp.name)/'artwork.sqlite')) as db:
            self.assertEqual(set(db.execute('SELECT hash,bytes FROM objects').fetchall()),
                             {(path.stem, path.stat().st_size) for path in files})

    def test_migrates_upload_age_and_reconciles_interrupted_eviction(self):
        first = self.upload()
        key = first.json['sha256']
        root = Path(self.temp.name)
        path = root/'covers'/f'{key}.jpg'
        os.utime(path, (1234, 1234))
        with closing(sqlite3.connect(root/'artwork.sqlite')) as db:
            db.execute('DROP TABLE objects')
            db.execute('CREATE TABLE objects (hash TEXT PRIMARY KEY, bytes INTEGER NOT NULL)')
            db.execute('INSERT INTO objects VALUES (?,?)', (key, path.stat().st_size))
            db.execute('INSERT INTO objects VALUES (?,?)', ('0'*64, 999))
            db.commit()
        create_app(self.config)
        with closing(sqlite3.connect(root/'artwork.sqlite')) as db:
            self.assertEqual(db.execute('SELECT hash,created FROM objects').fetchall(), [(key, 1234)])

    def test_paths_and_health(self):
        for path in ['/covers/'+'0'*64+'.jpg', '/covers/../../artwork.sqlite', '/covers/a.svg', '/covers/']:
            self.assertEqual(self.client.get(path).status_code, 404)
        self.assertEqual(self.client.get('/health').json['status'], 'ok')
        self.assertEqual(self.client.get('/health').headers['Cache-Control'], 'no-store')

    def test_concurrent_uploads_publish_one_complete_file(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: self.upload(self.app.test_client()), range(4)))
        self.assertEqual(sorted(r.status_code for r in results), [200,200,200,201])
        self.assertEqual(len({r.json['sha256'] for r in results}), 1)


if __name__ == '__main__':
    unittest.main()
