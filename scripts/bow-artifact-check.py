#!/usr/bin/env python3
"""Check that bow's *storage* holds everything `bst artifact pull` needs (#1094).

`bst artifact show` only asks the index remote (bb-asset). bow's index can keep an
artifact's entry after storage (bb-storage) has evicted the data, and llvm/rust were
exactly that on 2026-10-03. This asks both, the way a pull does
(buildstream/_artifactcache.py `pull` and `_pull_artifact_storage`), without
downloading any file data:

  1. index: Remote Asset FetchBlob for the artifact URN, which yields the Artifact
     proto's digest;
  2. storage: the Artifact proto itself, read so its references are known;
  3. storage: the `files` tree, walked breadth-first by reading Directory protos
     with BatchReadBlobs (bb-storage answers GetTree with UNIMPLEMENTED), then
     FindMissingBlobs over every file it references plus the low/high-diversity
     metadata, public data and logs. Buildtrees/sources/buildroot are skipped
     because a default pull skips them.

Run with the project venv's Python (`uv run python3`), which has grpc and
BuildStream's generated protos.

Usage: bow-artifact-check.py [--probe] <index host:port> <storage host:port> <server cert>
  stdin:  one "<element>\\t<full cache key>" per line, as `bst show --format
          '%{name}\\t%{full-key}'` prints them (not read with --probe)
  env:    BOW_TOKEN (bearer token)
  stdout: one "ok|missing|error\\t<element>\\t<detail>" per input line
Exit: 0 all ok, 1 any missing, 2 usage or connection error.

--probe only asks whether bow is reachable and accepts the token: one Remote Asset
FetchBlob on the index (NOT_FOUND is a healthy answer) and one empty FindMissingBlobs
on storage. Transient UNAVAILABLE/DEADLINE_EXCEEDED are retried; anything else, such
as UNAUTHENTICATED, fails at once. mise/tasks/bst runs it before every --pull/--push
build (#1113), because BuildStream only *warns* when it cannot reach a remote and then
builds everything from source, the toolchain included.
"""
import os
import string
import sys
import time

import grpc
from buildstream._protos.build.bazel.remote.asset.v1 import remote_asset_pb2, remote_asset_pb2_grpc
from buildstream._protos.build.bazel.remote.execution.v2 import (
    remote_execution_pb2 as re_pb2,
    remote_execution_pb2_grpc as re_grpc,
)
from buildstream._protos.buildstream.v2 import artifact_pb2
from buildstream._protos.google.rpc import code_pb2

URN = "urn:fdc:buildstream.build:2020:artifact:{}"  # _artifactcache.REMOTE_ASSET_ARTIFACT_URN_TEMPLATE
CHUNK = 10000  # digests per FindMissingBlobs
DIR_BATCH = 500  # Directory protos per BatchReadBlobs; each is small
TIMEOUT = 120
PROBE_TIMEOUT = 20
PROBE_ATTEMPTS = 4
PROBE_WAIT = 15  # seconds between attempts: ~1 minute of patience in total
RETRYABLE = {grpc.StatusCode.UNAVAILABLE, grpc.StatusCode.DEADLINE_EXCEEDED}

# Project name per junction, from each project's project.conf `name:`. It is not
# derivable from the junction element's name (gnome-build-meta.bst -> gnome), and
# the artifact name is keyed on it. Local elements belong to krytis.
PROJECTS = {"freedesktop-sdk.bst": "freedesktop-sdk", "gnome-build-meta.bst": "gnome"}


def artifact_name(element, cache_key):
    """BuildStream's Element.get_artifact_name(): element.py _get_normal_name +
    _compose_artifact_name."""
    junction, _, path = element.rpartition(":")
    project = PROJECTS[junction] if junction else "krytis"
    normal = os.path.splitext(path.replace(os.sep, "-"))[0]
    valid = string.digits + string.ascii_letters + "-._"
    normal = "".join(c if c in valid else "_" for c in normal)
    return f"{project}/{normal}/{cache_key}"


def channel(target, cert, token):
    creds = grpc.composite_channel_credentials(
        grpc.ssl_channel_credentials(root_certificates=cert),
        grpc.access_token_call_credentials(token),
    )
    return grpc.secure_channel(target, creds, options=[("grpc.max_receive_message_length", -1)])


def key(d):
    return (d.hash, d.size_bytes)


def missing_blobs(cas, digests):
    """Return (digests storage does not have, number of distinct digests asked)."""
    uniq = list({key(d): d for d in digests if d.hash}.values())
    out = []
    for i in range(0, len(uniq), CHUNK):
        req = re_pb2.FindMissingBlobsRequest(blob_digests=uniq[i:i + CHUNK])
        out.extend(cas.FindMissingBlobs(req, timeout=TIMEOUT).missing_blob_digests)
    return out, len(uniq)


def walk_tree(cas, root):
    """Return (file digests, number of unreadable directories) under root."""
    files, missing_dirs, seen = [], 0, set()
    level = [root]
    while level:
        level = [d for d in {key(d): d for d in level}.values() if key(d) not in seen]
        seen.update(key(d) for d in level)
        nxt = []
        for i in range(0, len(level), DIR_BATCH):
            req = re_pb2.BatchReadBlobsRequest(digests=level[i:i + DIR_BATCH])
            for r in cas.BatchReadBlobs(req, timeout=TIMEOUT).responses:
                if r.status.code != code_pb2.OK:
                    missing_dirs += 1
                    continue
                d = re_pb2.Directory()
                d.ParseFromString(r.data)
                files.extend(f.digest for f in d.files)
                nxt.extend(sub.digest for sub in d.directories)
        level = nxt
    return files, missing_dirs


def check(fetch, cas, name):
    """Return (status, detail) for one artifact name."""
    try:
        resp = fetch.FetchBlob(remote_asset_pb2.FetchBlobRequest(uris=[URN.format(name)]), timeout=TIMEOUT)
    except grpc.RpcError as e:
        if e.code() == grpc.StatusCode.NOT_FOUND:
            return "missing", "not in index"
        raise
    if resp.status.code == code_pb2.NOT_FOUND:
        return "missing", "not in index"
    if resp.status.code != code_pb2.OK:
        return "error", f"index status {resp.status.code}: {resp.status.message}"

    read = cas.BatchReadBlobs(re_pb2.BatchReadBlobsRequest(digests=[resp.blob_digest]), timeout=TIMEOUT)
    r = read.responses[0]
    if r.status.code != code_pb2.OK:
        return "missing", "in index, but storage lacks the Artifact proto"
    artifact = artifact_pb2.Artifact()
    artifact.ParseFromString(r.data)

    wanted = [artifact.low_diversity_meta, artifact.high_diversity_meta]
    if artifact.HasField("public_data"):
        wanted.append(artifact.public_data)
    wanted.extend(log.digest for log in artifact.logs)
    if artifact.HasField("files"):
        files, missing_dirs = walk_tree(cas, artifact.files)
        if missing_dirs:
            return "missing", f"in index, but storage lacks {missing_dirs} directories of the files tree"
        wanted.extend(files)

    missing, total = missing_blobs(cas, wanted)
    if missing:
        return "missing", f"in index, but storage lacks {len(missing)} of {total} blobs"
    return "ok", f"{total} blobs in storage"


def probe_once(index, storage, cert, token):
    """One reachability check. Raises grpc.RpcError tagged with the endpoint."""
    # Fresh channels per attempt: a gRPC channel that failed to connect sits in
    # its own reconnect backoff, which would outlast a short retry loop.
    fetch = remote_asset_pb2_grpc.FetchStub(channel(index, cert, token))
    cas = re_grpc.ContentAddressableStorageStub(channel(storage, cert, token))
    try:
        fetch.FetchBlob(remote_asset_pb2.FetchBlobRequest(
            uris=[URN.format("krytis/bow-probe/0")]), timeout=PROBE_TIMEOUT)
    except grpc.RpcError as e:
        if e.code() != grpc.StatusCode.NOT_FOUND:  # a healthy "no such artifact"
            e.endpoint = index
            raise
    try:
        cas.FindMissingBlobs(re_pb2.FindMissingBlobsRequest(), timeout=PROBE_TIMEOUT)
    except grpc.RpcError as e:
        e.endpoint = storage
        raise


def probe(index, storage, cert, token):
    """Return (0, detail) if both endpoints answer with this token, else (2, reason)."""
    for attempt in range(1, PROBE_ATTEMPTS + 1):
        try:
            probe_once(index, storage, cert, token)
            return 0, f"bow reachable: index {index}, storage {storage}"
        except grpc.RpcError as e:
            reason = f"{getattr(e, 'endpoint', '?')}: {e.code().name}: {e.details()}"
            if e.code() not in RETRYABLE or attempt == PROBE_ATTEMPTS:
                return 2, reason
        print(f"bow probe {attempt}/{PROBE_ATTEMPTS} failed ({reason}); retrying in {PROBE_WAIT}s",
              file=sys.stderr, flush=True)
        time.sleep(PROBE_WAIT)
    raise AssertionError("unreachable")


def main():
    args = sys.argv[1:]
    probe_only = args[:1] == ["--probe"]
    if probe_only:
        args = args[1:]
    if len(args) != 3 or not os.environ.get("BOW_TOKEN"):
        print("Usage:" + __doc__.split("Usage:", 1)[1], file=sys.stderr)
        return 2
    index, storage, cert_path = args
    with open(cert_path, "rb") as f:
        cert = f.read()
    token = os.environ["BOW_TOKEN"]
    if probe_only:
        rc, detail = probe(index, storage, cert, token)
        print(detail, file=sys.stderr if rc else sys.stdout, flush=True)
        return rc
    fetch = remote_asset_pb2_grpc.FetchStub(channel(index, cert, token))
    cas = re_grpc.ContentAddressableStorageStub(channel(storage, cert, token))

    worst = 0
    for line in sys.stdin:
        if not line.strip():
            continue
        element, cache_key = line.rstrip("\n").split("\t")
        try:
            status, detail = check(fetch, cas, artifact_name(element, cache_key))
        except grpc.RpcError as e:
            print(f"error\t{element}\t{e.code().name}: {e.details()}", flush=True)
            return 2
        print(f"{status}\t{element}\t{detail}", flush=True)
        if status != "ok":
            worst = max(worst, 1 if status == "missing" else 2)
    return worst


if __name__ == "__main__":
    sys.exit(main())
