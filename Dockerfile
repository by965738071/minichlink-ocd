FROM ubuntu:latest

RUN apt-get update && \
    apt-get install -y \
    tar xz-utils \
    ca-certificates \
    git libudev-dev

# Download zig https://ziglang.org/download/index.json
ADD "https://ziglang.org/builds/zig-aarch64-linux-0.17.0-dev.1099+7db2ef610.tar.xz" /tmp/zig.tar.xz
RUN tar -Jxf /tmp/zig.tar.xz -C /usr/local/bin --strip-components=1
RUN ls -la

ENTRYPOINT [ "/bin/bash" ]

# Run:
# docker build -t zig:latest . && docker run -it -v $PWD:/mnt -w /mnt --rm zig:latest zig build