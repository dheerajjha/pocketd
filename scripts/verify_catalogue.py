"""Check the files exported by verify-catalogue.sh without fetching the weights."""

import json
import sys
import uuid
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


def artifacts(entries):
    if not isinstance(entries, list) or not entries:
        raise ValueError("empty or invalid catalogue")
    seen, files = set(), []
    for entry in entries:
        model = entry["model"]
        ident = model["id"]
        if not ident or ident in seen:
            raise ValueError(f"empty or duplicate model id: {ident!r}")
        seen.add(ident)
        parts = [(model["filename"], entry["weights"], model["sizeBytes"])]
        name, url, size = model.get("projectorFilename"), entry.get("projector"), model["projectorSizeBytes"]
        if name is not None or url is not None or size != 0:
            parts.append((name, url, size))
        for name, url, size in parts:
            remote = urlsplit(url or "")
            if (not isinstance(name, str) or not name.endswith(".gguf") or type(size) is not int or size <= 4
                    or remote.scheme != "https" or not remote.hostname or remote.username is not None):
                raise ValueError(f"{ident}: incomplete or invalid file declaration: {name!r}")
            files.append((ident, name, url, size))
    return files


def probe(url, size, open_url):
    # A cached /resolve/main redirect may point to an expired signed CDN URL.
    # Ask for a fresh redirect, keeping the product's own path and query intact.
    parts = urlsplit(url)
    query = (parts.query + "&" if parts.query else "") + "pocketd_verify=" + uuid.uuid4().hex
    request = Request(parts._replace(query=query).geturl(), headers={
        "Range": "bytes=0-3", "Accept-Encoding": "identity", "Cache-Control": "no-cache",
    })
    with open_url(request, timeout=30) as response:
        # Only headers from the final GET count. A 206 Content-Length describes
        # the slice, not the file. If the server ignores Range, close after the
        # same four bytes; never read a model-sized body to discover its length.
        if urlsplit(response.geturl()).scheme != "https":
            raise ValueError("download redirected off HTTPS")
        length = response.headers.get("Content-Length")
        if response.status == 206:
            span = response.headers.get("Content-Range")
            if span != f"bytes 0-3/{size}" or length not in (None, "4"):
                raise ValueError(f"expected bytes 0-3/{size}; got {span!r}, Content-Length {length!r}")
        elif response.status == 200:
            if (length != str(size) or response.headers.get("Content-Range") is not None
                    or response.headers.get("Transfer-Encoding") is not None):
                raise ValueError(f"expected full length {size}; got Content-Length {length!r}")
        else:
            raise ValueError(f"HTTP {response.status}")
        if response.headers.get("Content-Encoding", "identity").lower() != "identity" or response.read(4) != b"GGUF":
            raise ValueError("not an unencoded GGUF file")


def verify(url, size, open_url=urlopen):
    # A CDN read can time out even for this four-byte request. Retry that once
    # with a fresh resolve URL; HTTP refusals and inconsistent sizes stand.
    try:
        probe(url, size, open_url)
    except (TimeoutError, URLError) as error:
        if not isinstance(getattr(error, "reason", error), TimeoutError):
            raise
        probe(url, size, open_url)


def main():
    try:
        entries = json.load(sys.stdin)
        files = artifacts(entries)
        for ident, name, url, size in files:
            try:
                verify(url, size)
            except HTTPError as error:
                raise ValueError(f"{ident}/{name}: HTTP {error.code}") from None
            except (URLError, OSError, ValueError) as error:
                raise ValueError(f"{ident}/{name}: {error}") from None
            print(f"ok  {ident}/{name}: {size} bytes")
    except (KeyError, TypeError, ValueError) as error:
        sys.exit(f"FAIL  {error}")
    print(f"Verified {len(files)} files for {len(entries)} models (exact bytes).")


if __name__ == "__main__":
    main()
