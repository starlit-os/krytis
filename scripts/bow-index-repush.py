#!/usr/bin/env python3
"""Restore bow's strong-key index entries for locally cached artifacts.

When bow evicts the strong-key index entry but keeps the weak-key entry,
BuildStream's push finds the weak entry via FetchBlob with both URNs and skips
the index push (BuildStream's buildstream/_artifactcache.py,
_push_artifact_proto). After bst artifact push, check that storage has the
local Artifact proto and register just its strong URN via PushBlob.

Usage: bow-index-repush.py <index host:port> <storage host:port> <server cert>
  stdin:  one "<element>\\t<strong cache key>" per line
  env:    BOW_TOKEN (push bearer token)
  stdout: one "repushed\\t<element>" or "skipped\\t<element>\\t<reason>" per row
Exit: 0 all repushed, 1 any skipped, 2 usage or certificate error.
"""
import hashlib
import importlib.util
import os
from pathlib import Path
import string
import sys

import grpc
from buildstream._protos.build.bazel.remote.asset.v1 import remote_asset_pb2, remote_asset_pb2_grpc
from buildstream._protos.build.bazel.remote.execution.v2 import (
    remote_execution_pb2 as re_pb2,
    remote_execution_pb2_grpc as re_grpc,
)
from buildstream._protos.buildstream.v2 import artifact_pb2
from google.protobuf.message import DecodeError

spec = importlib.util.spec_from_file_location(
    "bow_artifact_check", Path(__file__).with_name("bow-artifact-check.py")
)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def repush(push, cas, refs, element, cache_key):
    """Return a reason if the strong-key entry could not be restored."""
    if len(cache_key) != 64 or any(c not in string.hexdigits.lower() for c in cache_key):
        return "invalid strong cache key"

    name = checker.artifact_name(element, cache_key)
    data = (refs / name).read_bytes()
    artifact = artifact_pb2.Artifact()
    artifact.ParseFromString(data)
    if artifact.strong_key != cache_key:
        return "local Artifact proto strong key does not match"

    digest = re_pb2.Digest(hash=hashlib.sha256(data).hexdigest(), size_bytes=len(data))
    missing, _ = checker.missing_blobs(cas, [digest])
    if missing:
        return "storage lacks the Artifact proto"

    request = remote_asset_pb2.PushBlobRequest(uris=[checker.URN.format(name)], blob_digest=digest)
    push.PushBlob(request, timeout=checker.TIMEOUT)
    return None


def main():
    args = sys.argv[1:]
    token = os.environ.get("BOW_TOKEN")
    if len(args) != 3 or not token:
        print("Usage:" + __doc__.split("Usage:", 1)[1], file=sys.stderr)
        return 2

    index, storage, cert_path = args
    try:
        cert = Path(cert_path).read_bytes()
    except OSError as e:
        print(e, file=sys.stderr)
        return 2

    refs = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "buildstream/artifacts/refs"
    push = remote_asset_pb2_grpc.PushStub(checker.channel(index, cert, token))
    cas = re_grpc.ContentAddressableStorageStub(checker.channel(storage, cert, token))

    rc = 0
    for line in sys.stdin:
        if not line.strip():
            continue
        element, _, cache_key = line.rstrip("\n").partition("\t")
        try:
            reason = repush(push, cas, refs, element, cache_key)
        except KeyError:
            reason = "unknown junction"
        except (OSError, DecodeError) as e:
            reason = str(e)
        except grpc.RpcError as e:
            reason = f"{e.code().name}: {e.details()}"

        if reason is None:
            print(f"repushed\t{element}", flush=True)
        else:
            reason = " ".join(reason.split())
            print(f"skipped\t{element}\t{reason}", flush=True)
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
