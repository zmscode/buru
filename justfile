set quiet
alias b := build
alias r := run
alias c := clean

# Build the executable into zig-out/bin.
build:
    zig build

# Build and run, forwarding any extra arguments: `just r alpha beta`.
run *args:
    zig build run -- {{ args }}

# Delete the build cache and the install prefix.
clean:
    rm -rf .zig-cache zig-out

# Install a release build to ~/.local/bin and the fish completions.
install:
    zig build -Doptimize=ReleaseSafe --prefix ~/.local
    ~/.local/bin/buru completions fish > ~/.config/fish/completions/buru.fish

# Publish a GitHub release for the version in build.zig.zon and update the tap.
release:
    scripts/release.sh

# Build the release tarballs and print the formula without publishing.
release-dry-run:
    scripts/release.sh --dry-run
