# IPE benchmark image

This linux/amd64 image measures process and executable-mapping work with two
recognizable upstream tools:

- `stress-ng 0.18.02`: `fork`, `spawn`, and `dynlib`
- Ubuntu's `lmbench 3.0-a9` package: `lat_proc exec`

The Ubuntu base image, stress-ng source archive, and lmbench package are pinned
by digest. The runner uses each tool's own machine-readable result rather than
timing the command with a custom loop. It retains every repetition in JSON.

## Build and run

```bash
docker buildx build \
  --platform linux/amd64 \
  --load \
  --tag ipe-bench:stress-ng-lmbench-v1 \
  acl/tests/ipe-benchmark-image

docker run --detach --name ipe-bench ipe-bench:stress-ng-lmbench-v1
docker exec ipe-bench run-ipe-bench
docker cp ipe-bench:/tmp/ipe-bench-results.json .
docker rm --force ipe-bench
```

The image intentionally runs as non-root. Upstream stress-ng refuses to run its
`spawn` stressor as effective UID 0, so do not override the image user.

Defaults are seven recorded repetitions after one warmup repetition. The
recorded workload order is deterministically shuffled to counterbalance drift.
The same `IPE_BENCH_SEED` produces the same order on both comparison nodes.
Operation counts and repetition counts can be changed with the `IPE_BENCH_*`
environment variables listed by `run-ipe-bench.py`.

## Measurement contract

Start the container before timing so image pull, snapshot preparation, and pod
scheduling are outside this microbenchmark. Compare the same image digest on
matched IPE-off and IPE-audit nodes.

For the IPE-audit arm, independently verify on the host that:

1. an IPE policy is active in permissive/audit mode;
2. the container layers created signed dm-verity devices;
3. the benchmark emitted zero IPE denial records.

Those controls distinguish the normal signed `ALLOW` path from the unverified
`DENY`-plus-audit path. The latter is a useful worst case, but it is not the
overhead expected for signed production containers.
