FROM nixos/nix

# Set the working directory for the application
WORKDIR /app

RUN echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf
RUN echo "filter-syscalls = false" >> /etc/nix/nix.conf

# docker build -t nix:latest . -f ./nix.Dockerfile && docker run -it -v $PWD:/mnt -w /mnt --rm nix:latest
# nix develop .#cross-amd64 -c zig build -Dcpu=baseline -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu
# nix develop .#cross-aarch64 -c zig build -Dcpu=baseline -Doptimize=ReleaseFast -Dtarget=aarch64-linux-gnu
# nix develop -c zig build --verbose -Dcpu=baseline -Doptimize=ReleaseFast -Dtarget=x86_64-windows
# nix develop -c zig build --verbose -Dcpu=baseline -Doptimize=ReleaseFast -Dtarget=aarch64-windows