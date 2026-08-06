upstream_remote := "upstream"
main_branch := "main"
fork_branch := "fork/stable"
patches_dir := "patches/em-client"

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
