"""Offline regression checks for the catalogue verifier."""

import io
import unittest
from contextlib import nullcontext
from types import SimpleNamespace

from verify_catalogue import artifacts, verify


URL = "https://huggingface.co/example/model/resolve/main/file.gguf?download=true"


class CatalogueTests(unittest.TestCase):
    def test_missing_or_partial_catalogue_never_checks_as_complete(self):
        model = dict(id="model", filename="file.gguf", sizeBytes=100, projectorSizeBytes=0)
        row = dict(model=model, weights=URL)
        self.assertEqual(artifacts([row]), [("model", "file.gguf", URL, 100)])
        vision = dict(model=dict(model, projectorFilename="eye.gguf", projectorSizeBytes=50),
                      weights=URL, projector=URL.replace("file.gguf", "eye.gguf"))
        self.assertEqual(artifacts([vision])[-1], ("model", "eye.gguf", vision["projector"], 50))
        for bad in [[], [row, row], [dict(model=model)], [dict(row, projector=URL)],
                    [dict(row, model=dict(model, projectorSizeBytes=50))],
                    [dict(vision, model=dict(vision["model"], projectorSizeBytes=0))]]:
            with self.subTest(bad=bad), self.assertRaises((ValueError, KeyError)):
                artifacts(bad)

    def probe(self, status, headers, body=b"GGUF", size=100):
        data = io.BytesIO(body)
        response = SimpleNamespace(status=status, headers=headers, read=data.read, geturl=lambda: URL)

        def serve(request, timeout):
            self.assertEqual(request.get_method(), "GET")
            self.assertEqual(request.get_header("Range"), "bytes=0-3")
            self.assertIn("?download=true&pocketd_verify=", request.full_url)
            return nullcontext(response)

        verify(URL, size, open_url=serve)
        return data.tell()

    def test_range_and_full_response_both_read_only_the_magic(self):
        self.assertEqual(self.probe(206, {"Content-Range": "bytes 0-3/100"}), 4)
        self.assertEqual(self.probe(200, {"Content-Length": "100"}, b"GGUF" + bytes(96)), 4)

    def test_timeout_retries_once_with_a_fresh_resolve_url(self):
        requested = []

        def timeout(request, **kwargs):
            requested.append(request.full_url)
            raise TimeoutError("CDN did not answer")

        with self.assertRaises(TimeoutError):
            verify(URL, 100, open_url=timeout)
        self.assertEqual(len(requested), 2)
        self.assertNotEqual(*requested)

    def test_rejects_unverified_or_incorrect_final_response(self):
        for status, headers, body in [
            (206, {"Content-Range": "bytes 0-3/101"}, b"GGUF"),
            (206, {"Content-Length": "4", "X-Linked-Size": "100"}, b"GGUF"),
            (206, {"Content-Range": "bytes 0-3/100", "Content-Length": "100"}, b"GGUF"),
            (200, {"Content-Length": "100", "Transfer-Encoding": "chunked"}, b"GGUF"),
            (200, {}, b"GGUF"), (200, {"Content-Length": "100"}, b"<htm"),
            (302, {"X-Linked-Size": "100"}, b""), (401, {}, b""), (404, {}, b""),
        ]:
            with self.subTest(status=status, headers=headers), self.assertRaises(ValueError):
                self.probe(status, headers, body)


if __name__ == "__main__":
    unittest.main()
