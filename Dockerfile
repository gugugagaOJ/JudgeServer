###############################################
# Builder Stage
###############################################
FROM ubuntu:24.04 AS builder
ARG TARGETARCH
ARG TARGETVARIANT
ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /app

RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-builder \
    --mount=type=cache,target=/var/lib/apt,id=apt-lib-builder \
    bash -c " \
set -ex && \
apt-get update && \
apt-get install -y libtool make cmake libseccomp-dev gcc g++ \
                   python3 python3-venv python3-dev build-essential \
"

COPY Judger/ /app/

RUN bash -c " \
set -ex && \
mkdir -p build && \
cmake -S . -B build && \
cmake --build build --parallel $(nproc) \
"

RUN bash -c " \
set -ex && \
cd bindings/Python && \
python3 -m venv .venv && \
.venv/bin/pip3 install build && \
.venv/bin/python3 -m build -w \
"


###############################################
# Final Runtime Stage
###############################################
FROM ubuntu:24.04
ARG TARGETARCH
ARG TARGETVARIANT
ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /app

###############################################
# Install Base Dependencies + Python 3.12 + GCC13 + Go
###############################################
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-final \
    --mount=type=cache,target=/var/lib/apt,id=apt-lib-final \
    bash -c " \
set -ex && \
apt-get update && \
apt-get install -y \
  ca-certificates curl gnupg software-properties-common \
  python3.12 python3.12-venv python3.12-dev \
  gcc-13 g++-13 \
  golang-go \
  strace \
  && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-13 13 \
  && update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-13 13 \
"


###############################################
# Install Java 21 (Temurin)
###############################################
RUN <<'EOF'
set -ex
curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
    | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg

cat << 'EOT' > /etc/apt/sources.list.d/adoptium.sources
Types: deb
URIs: https://packages.adoptium.net/artifactory/deb
Suites: noble
Components: main
Signed-By: /etc/apt/keyrings/adoptium.gpg
EOT

apt-get update
apt-get install -y temurin-21-jdk
EOF


###############################################
# Install Node 20
###############################################
RUN <<'EOF'
set -ex
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg

cat << 'EOT' > /etc/apt/sources.list.d/nodesource.sources
Types: deb
URIs: https://deb.nodesource.com/node_20.x
Suites: nodistro
Components: main
Signed-By:/etc/apt/keyrings/nodesource.gpg
EOT

apt-get update
apt-get install -y nodejs
EOF


###############################################
# Copy Judger Binaries
###############################################
COPY --from=builder --chmod=755 --link /app/output/libjudger.so /usr/lib/judger/libjudger.so
COPY --from=builder /app/bindings/Python/dist/ /app/


###############################################
# Python Virtualenv for Service Runtime
###############################################
RUN --mount=type=cache,target=/root/.cache/pip,id=pip-cache-final \
    bash -c " \
set -ex && \
python3.12 -m venv .venv && \
CC=gcc .venv/bin/pip3 install --upgrade pip && \
.venv/bin/pip3 install --compile --no-cache-dir flask gunicorn idna psutil requests && \
.venv/bin/pip3 install *.whl \
"


###############################################
# Copy Server + Permissions + Users
###############################################
COPY server/ /app/

RUN bash -c " \
set -ex && \
chmod -R u=rwX,go=rX /app/ && \
chmod +x /app/entrypoint.sh && \
gcc -shared -fPIC -o unbuffer.so unbuffer.c && \
useradd -u 901 -r -s /sbin/nologin -M compiler && \
useradd -u 902 -r -s /sbin/nologin -M code && \
useradd -u 903 -r -s /sbin/nologin -M -G code spj && \
mkdir -p /usr/lib/judger \
"


###############################################
# Print Versions for Debugging
###############################################
RUN bash -c " \
gcc --version && \
g++ --version && \
python3.12 --version && \
java -version && \
node --version && \
go version \
"


###############################################
# Runtime
###############################################
HEALTHCHECK --interval=5s CMD [ "/app/.venv/bin/python3", "/app/service.py" ]
EXPOSE 8080
ENTRYPOINT [ "/app/entrypoint.sh" ]

