# syntax=docker/dockerfile:1
FROM ubuntu:24.04 AS compiler
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc g++ git curl ca-certificates xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://github.com/nim-lang/nightlies/releases/download/2026-04-24-version-2-2-bfeb3146d1638b39f69007a4ae5a23e23ae4e5ef/nim-2.2.10-linux_x64.tar.xz \
    | tar xJ -C /opt
ENV PATH=/opt/nim-2.2.10/bin:$PATH
WORKDIR /src/polyworld
COPY coworld/dependencies.lock coworld/dependencies.lock
COPY coworld/tools/sync_dependencies.nim coworld/tools/tooling.nim coworld/tools/
RUN nim r --hints:off coworld/tools/sync_dependencies.nim
ENV POLYWORLD_DEPS=/src/polyworld/tmp/coworld/deps
COPY config.nims config.nims
COPY src src
COPY examples examples
ARG GAME
ARG ENTRY
RUN nim c -d:coworld --nimcache:/tmp/nimcache -o:/out/game examples/${GAME}/${ENTRY}.nim
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4t64 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=compiler /out/game /usr/local/bin/polyworld
# The runner stages writable outputs as root in its shared volume.
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/polyworld"]
