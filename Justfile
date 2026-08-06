set dotenv-load := true

upstream_remote := "upstream"
main_branch := "main"
fork_branch := "fork/stable"
patches_dir := "patches/em-client"
docker_image := "docker.io/cybercinch/stalwart"
dockerfile := "Dockerfile.fast"

# Fetch latest upstream tags/branches
fetch:
    git fetch {{upstream_remote}} --tags --prune

# Show the latest upstream v0.16.x tag
latest-tag:
    git tag -l 'v0.16.*' | sort -V | tail -1

# Fast-forward main to upstream/main. Never commit to main directly - it stays
# a clean mirror so it can be used as the base for anything bound for an
# upstream PR.
sync-main: fetch
    git checkout {{main_branch}}
    git merge --ff-only {{upstream_remote}}/main
    @echo "{{main_branch}} is now at $(git rev-parse --short {{main_branch}}). Push to origin/{{main_branch}} when ready."

# Cut a topic branch off main for something you intend to PR upstream.
# Keeping it based on main (not fork/stable) keeps the diff minimal and
# review-friendly.
feature name:
    git checkout {{main_branch}}
    git checkout -b {{name}} {{main_branch}}

# Rebase the fork branch (main + our patch stack) onto a given upstream ref
# (default: latest v0.16.x tag)
rebase ref=`git tag -l 'v0.16.*' | sort -V | tail -1`:
    git checkout {{fork_branch}}
    git rebase --onto {{ref}} {{upstream_remote}}/main {{fork_branch}}
    @echo "Rebased {{fork_branch}} onto {{ref}}. Run 'just check' then 'just export-patches'."

# Compile-check the affected crate after a rebase
check:
    cargo check -p dav

# Export the current patch stack to patches/em-client/*.patch for review/vendoring
export-patches:
    mkdir -p {{patches_dir}}
    rm -f {{patches_dir}}/*.patch
    git format-patch {{upstream_remote}}/main..{{fork_branch}} -o {{patches_dir}}

# Rebuild the fork branch from scratch on top of a fresh ref using the exported patches
apply-patches ref=`git tag -l 'v0.16.*' | sort -V | tail -1`:
    git checkout -B {{fork_branch}} {{ref}}
    git am {{patches_dir}}/*.patch

# Cherry-pick a commit (e.g. from a declined/pending upstream PR branch) into
# the fork's patch stack, then re-export so patches/ stays in sync.
land-fork commit:
    git checkout {{fork_branch}}
    git cherry-pick {{commit}}
    just export-patches

# Full cycle: fast-forward main, rebase the fork branch onto the latest
# v0.16.x tag, check, re-export patches
sync: sync-main rebase check export-patches
    @echo "{{fork_branch}} is now current with $(just latest-tag)."

# Stalwart version, read from the workspace member's Cargo.toml
stalwart-version:
    @grep -m1 '^version' crates/main/Cargo.toml | cut -d '"' -f2

# Rust target triple for a docker arch name (amd64/arm64)
rust-target arch:
    @case "{{arch}}" in \
        amd64) echo x86_64-unknown-linux-gnu ;; \
        arm64) echo aarch64-unknown-linux-gnu ;; \
        *) echo "unknown arch '{{arch}}' (expected amd64 or arm64)" >&2; exit 1 ;; \
    esac

# Cross-compile the stalwart + stalwart-cli binaries natively for one arch
# (amd64/arm64) via build.sh, instead of building inside Docker/QEMU.
build-arch arch:
    TARGET_ARCH=$(just rust-target {{arch}}) BUILD_TYPE=release ./build.sh

# Cross-compile natively for both amd64 and arm64
build-multiarch: (build-arch "amd64") (build-arch "arm64")

# Build and push a single-arch image from the pre-built binary using
# Dockerfile.fast (no cargo build inside Docker).
docker-build-arch arch version:
    docker buildx build \
      --platform linux/{{arch}} \
      -f {{dockerfile}} \
      --build-arg TARGET_ARCH=$(just rust-target {{arch}}) \
      --build-arg BUILD_TYPE=release \
      -t {{docker_image}}:{{version}}-{{arch}} \
      --push .

# Full multi-arch publish: cross-compile amd64+arm64 natively (build.sh),
# build/push each arch's image from Dockerfile.fast, then assemble+push the
# combined :latest and :<stalwart-version> manifest lists to
# docker.io/cybercinch/stalwart. Reads DOCKERHUB_USERNAME / DOCKERHUB_TOKEN
# from a local .env file (see .env.example) via dotenv-load.
docker-publish: build-multiarch
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(just stalwart-version)
    : "${DOCKERHUB_USERNAME:?Set DOCKERHUB_USERNAME in .env}"
    : "${DOCKERHUB_TOKEN:?Set DOCKERHUB_TOKEN in .env}"
    echo "$DOCKERHUB_TOKEN" | docker login docker.io -u "$DOCKERHUB_USERNAME" --password-stdin
    just docker-build-arch amd64 "$version"
    just docker-build-arch arm64 "$version"
    docker buildx imagetools create \
      -t {{docker_image}}:latest -t {{docker_image}}:"$version" \
      {{docker_image}}:"$version"-amd64 {{docker_image}}:"$version"-arm64
    echo "Published {{docker_image}}:latest and {{docker_image}}:$version (amd64+arm64)"
