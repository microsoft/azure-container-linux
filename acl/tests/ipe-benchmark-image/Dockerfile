# syntax=docker/dockerfile:1

ARG UBUNTU_IMAGE=ubuntu@sha256:561618e2c15bf2397621dd04f96926663a3b5616c189cf7e38db7e82f5c538ea

FROM ${UBUNTU_IMAGE} AS build

ARG TARGETARCH=amd64
ARG STRESS_NG_VERSION=0.18.02
ARG STRESS_NG_SHA256=45eac8d354df5be26c9675ec7fc24910f846e47eb6b151e9955d6eae30cfe060
ARG LMBENCH_VERSION=3.0-a9+debian.1-6build3
ARG LMBENCH_SHA256=372b9d640b5c319f68530ad8c324b1a77b2c228933fd4c50e60ee89855a14cb0

RUN test "${TARGETARCH}" = "amd64"

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/build

RUN curl --fail --location --silent --show-error \
        "https://github.com/ColinIanKing/stress-ng/archive/refs/tags/V${STRESS_NG_VERSION}.tar.gz" \
        --output stress-ng.tar.gz \
    && echo "${STRESS_NG_SHA256}  stress-ng.tar.gz" | sha256sum --check --strict \
    && tar --extract --gzip --file stress-ng.tar.gz \
    && make --directory "stress-ng-${STRESS_NG_VERSION}" -j"$(nproc)" \
    && install -D --mode=0755 \
        "stress-ng-${STRESS_NG_VERSION}/stress-ng" \
        /out/usr/local/bin/stress-ng \
    && install -D --mode=0644 \
        "stress-ng-${STRESS_NG_VERSION}/COPYING" \
        /out/usr/share/doc/stress-ng/COPYING

RUN curl --fail --location --silent --show-error \
        "https://archive.ubuntu.com/ubuntu/pool/multiverse/l/lmbench/lmbench_${LMBENCH_VERSION}_amd64.deb" \
        --output lmbench.deb \
    && echo "${LMBENCH_SHA256}  lmbench.deb" | sha256sum --check --strict \
    && dpkg-deb --extract lmbench.deb lmbench \
    && install -D --mode=0755 \
        lmbench/usr/lib/lmbench/bin/x86_64-linux-gnu/lat_proc \
        /out/opt/lmbench/bin/lat_proc \
    && install -D --mode=0755 \
        lmbench/usr/lib/lmbench/bin/x86_64-linux-gnu/hello \
        /out/opt/lmbench/bin/hello \
    && install -D --mode=0644 \
        lmbench/usr/share/doc/lmbench/copyright \
        /out/usr/share/doc/lmbench/copyright

COPY run-ipe-bench.py /out/usr/local/bin/run-ipe-bench
RUN chmod 0755 /out/usr/local/bin/run-ipe-bench

FROM ${UBUNTU_IMAGE}

ARG VCS_REF=unknown
ARG STRESS_NG_VERSION=0.18.02
ARG LMBENCH_VERSION=3.0-a9+debian.1-6build3

LABEL org.opencontainers.image.title="ACL IPE benchmark" \
      org.opencontainers.image.description="Pinned stress-ng and lmbench workloads for measuring IPE audit-mode overhead" \
      org.opencontainers.image.source="https://github.com/microsoft/azure-container-linux/tree/${VCS_REF}/acl/tests/ipe-benchmark-image" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.version="stress-ng-${STRESS_NG_VERSION}_lmbench-${LMBENCH_VERSION}" \
      com.microsoft.acl.stress-ng.version="${STRESS_NG_VERSION}" \
      com.microsoft.acl.lmbench.version="${LMBENCH_VERSION}"

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        python3 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/ /

ENV HOME=/tmp \
    LMBENCH_VERSION=3.0-a9+debian.1-6build3 \
    PATH=/opt/lmbench/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# stress-ng deliberately refuses the spawn stressor when effective UID is 0.
USER 65532:65532

WORKDIR /tmp

STOPSIGNAL SIGTERM
CMD ["sleep", "infinity"]
