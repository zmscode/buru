#!/usr/bin/env bash
# Build release binaries, publish a GitHub release and update the Homebrew tap.
#
#   scripts/release.sh            release the version in build.zig.zon
#   scripts/release.sh --dry-run  build dist/ and print the formula only
#
# Pre-built binaries because buru targets Zig 0.17-dev, which Homebrew does not
# package. Switch the formula to a source build once 0.17 is stable.
set -euo pipefail

repo="zmscode/buru"
tap="zmscode/homebrew-buru"
targets=(aarch64-macos x86_64-macos)

cd "$(dirname "$0")/.."
dry_run=false
[[ "${1:-}" == "--dry-run" ]] && dry_run=true

version=$(sed -n 's/^ *\.version = "\(.*\)",/\1/p' build.zig.zon)
tag="v$version"
[[ -n "$version" ]] || { echo "no .version in build.zig.zon" >&2; exit 1; }

if ! $dry_run; then
    [[ -z "$(git status --porcelain)" ]] || { echo "working tree is not clean" >&2; exit 1; }
    if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        echo "tag $tag already exists; bump .version in build.zig.zon" >&2
        exit 1
    fi
fi

echo "==> testing"
zig build test

sha() { shasum -a 256 "dist/buru-$version-$1.tar.gz" | cut -d' ' -f1; }

echo "==> building $version"
rm -rf dist
mkdir -p dist
for t in "${targets[@]}"; do
    zig build -Dtarget="$t" -Doptimize=ReleaseSafe --prefix "dist/$t"
    stage="dist/stage-$t"
    mkdir -p "$stage"
    cp "dist/$t/bin/buru" README.md LICENSE "$stage/"
    tarball="dist/buru-$version-$t.tar.gz"
    tar -czf "$tarball" -C "$stage" buru README.md LICENSE
    echo "    $tarball  $(sha "$t")"
done

# the native binary should report the version the formula test expects
native="dist/$(uname -m | sed 's/arm64/aarch64/')-macos/bin/buru"
[[ "$("$native" --version)" == "buru $version" ]] || { echo "version mismatch" >&2; exit 1; }

url() { echo "https://github.com/$repo/releases/download/$tag/buru-$version-$1.tar.gz"; }

cat >dist/buru.rb <<EOF
class Buru < Formula
  desc "Markdown task tracker for private/tasks.md in your projects"
  homepage "https://github.com/$repo"
  license "MIT"

  # Pre-built binaries: buru targets Zig 0.17-dev, and Homebrew's zig is 0.16.
  # Switch to a source build (depends_on "zig" => :build) once 0.17 is stable.
  on_macos do
    on_arm do
      url "$(url aarch64-macos)"
      sha256 "$(sha aarch64-macos)"
    end
    on_intel do
      url "$(url x86_64-macos)"
      sha256 "$(sha x86_64-macos)"
    end
  end

  def install
    bin.install "buru"
    generate_completions_from_executable(bin/"buru", "completions", shells: [:fish])
    doc.install "README.md", "LICENSE"
  end

  test do
    assert_match "buru #{version}", shell_output("#{bin}/buru --version")

    system bin/"buru", "init"
    assert_path_exists testpath/"private/tasks.md"

    # stdin is not a terminal here, so buru reads plain lines
    pipe_output("#{bin}/buru h", "Write tests\nfirst point\n\n")
    assert_match "\`H001\` | **Write tests**", (testpath/"private/tasks.md").read

    system bin/"buru", "done", "h1"
    assert_match "- [x] \`H001\`", (testpath/"private/done.md").read
  end
end
EOF

if $dry_run; then
    echo "==> dry run: dist/buru.rb"
    cat dist/buru.rb
    exit 0
fi

echo "==> publishing $tag"
git tag -a "$tag" -m "buru $version"
git push origin "$tag"
gh release create "$tag" -R "$repo" --title "buru $version" --generate-notes \
    "dist/buru-$version-aarch64-macos.tar.gz" "dist/buru-$version-x86_64-macos.tar.gz"

echo "==> updating $tap"
tapdir=$(mktemp -d)
trap 'rm -rf "$tapdir"' EXIT
gh repo clone "$tap" "$tapdir" -- --quiet
mkdir -p "$tapdir/Formula"
cp dist/buru.rb "$tapdir/Formula/buru.rb"
git -C "$tapdir" add Formula/buru.rb
git -C "$tapdir" commit -m "buru $version"
git -C "$tapdir" push --quiet

echo "==> done: brew upgrade zmscode/buru/buru"
