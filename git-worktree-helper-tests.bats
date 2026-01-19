#!/usr/bin/env bats

setup() {
    tmpdir=$(mktemp -d /tmp/wt-test.XXXXXX)
    repo="$tmpdir/repo"
    worktree_root="$tmpdir/worktrees"
    mkdir -p "$repo" "$worktree_root"

    git -C "$repo" -c init.defaultBranch=main init >/dev/null
    git -C "$repo" -c user.name='wt test' -c user.email='wt@example.test' \
        commit --allow-empty -m 'init' >/dev/null

    export REPO="$repo"
    export GIT_WORKTREE_DEFAULT_PATH="$worktree_root"
    export WT_SCRIPT="$BATS_TEST_DIRNAME/git-worktree-helper.sh"
}

teardown() {
    rm -rf "$tmpdir"
}

@test "gwh help shows usage" {
    run zsh -c 'source "$WT_SCRIPT"; gwh help'
    [ "$status" -eq 0 ]
    [[ "$output" == *"git worktree helper"* ]]
}

@test "gwh list shows current worktree" {
    run zsh -c 'source "$WT_SCRIPT"; cd "$REPO"; gwh list'
    [ "$status" -eq 0 ]
    [[ "$output" == *"$REPO"* ]]
}

@test "gwh new creates worktree and cds" {
    run zsh -c 'source "$WT_SCRIPT"; cd "$REPO"; gwh new "feat/demo"; pwd'
    [ "$status" -eq 0 ]
    expected="$GIT_WORKTREE_DEFAULT_PATH/$(basename "$REPO")/feat-demo"
    output_real=$(cd "$output" && pwd -P)
    expected_real=$(cd "$expected" && pwd -P)
    [ "$output_real" = "$expected_real" ]
    [ -d "$expected" ]
}

@test "gwh new without name generates a worktree" {
    run zsh -c 'source "$WT_SCRIPT"; cd "$REPO"; gwh new 2>/dev/null; pwd'
    [ "$status" -eq 0 ]
    base="$GIT_WORKTREE_DEFAULT_PATH/$(basename "$REPO")"
    [[ "$output" == "$base/"* ]]
    [ -d "$output" ]
}

@test "gwh switch moves to worktree" {
    run zsh -c 'source "$WT_SCRIPT"; cd "$REPO"; gwh new "feat/demo" >/dev/null; cd "$REPO"; gwh switch feat-demo; pwd'
    [ "$status" -eq 0 ]
    expected="$GIT_WORKTREE_DEFAULT_PATH/$(basename "$REPO")/feat-demo"
    output_real=$(cd "$output" && pwd -P)
    expected_real=$(cd "$expected" && pwd -P)
    [ "$output_real" = "$expected_real" ]
}

@test "gwh rename renames the current worktree" {
    run zsh -c 'source "$WT_SCRIPT"; cd "$REPO"; gwh new "feat/demo" >/dev/null; gwh rename "feat/renamed"; echo "PWD=$(pwd)"; echo "BRANCH=$(git rev-parse --abbrev-ref HEAD)"'
    [ "$status" -eq 0 ]
    expected="$GIT_WORKTREE_DEFAULT_PATH/$(basename "$REPO")/feat-renamed"
    [[ "$output" == *"PWD=$expected"* ]]
    [[ "$output" == *"BRANCH=feat-renamed"* ]]
    [ -d "$expected" ]
    [ ! -e "$GIT_WORKTREE_DEFAULT_PATH/$(basename "$REPO")/feat-demo" ]
}

@test "gwh delete removes worktree with --force" {
    run zsh -c 'source "$WT_SCRIPT"; cd "$REPO"; gwh new "feat/demo" >/dev/null; cd "$REPO"; gwh delete --force feat-demo'
    [ "$status" -eq 0 ]
    expected="$GIT_WORKTREE_DEFAULT_PATH/$(basename "$REPO")/feat-demo"
    [ ! -e "$expected" ]
}

@test "gwh switch reports ambiguous matches" {
    run zsh -c 'source "$WT_SCRIPT"; cd "$REPO"; gwh new "feat/alpha" >/dev/null; cd "$REPO"; gwh new "feat/alpine" >/dev/null; cd "$REPO"; gwh switch fe'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Multiple worktrees match; use a longer name"* ]]
}

@test "gwh pr runs gh in the worktree when available" {
    mkdir -p "$tmpdir/bin"
    cat >"$tmpdir/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh:$PWD:$*"
EOF
    chmod +x "$tmpdir/bin/gh"

    run zsh -c 'source "$WT_SCRIPT"; PATH="'"$tmpdir"'/bin:$PATH"; cd "$REPO"; gwh new "feat/demo" >/dev/null; cd "$REPO"; gwh pr feat-demo'
    [ "$status" -eq 0 ]
    expected="$GIT_WORKTREE_DEFAULT_PATH/$(basename "$REPO")/feat-demo"
    expected_real=$(cd "$expected" && pwd -P)
    [[ "$output" == *"gh:$expected:"* ]] || [[ "$output" == *"gh:$expected_real:"* ]]
    [[ "$output" == *"pr create --web"* ]]
}

@test "gwh prune removes worktrees with closed prs" {
    mkdir -p "$tmpdir/bin"
    cat >"$tmpdir/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "view" ]]; then
    branch="${3:-}"
    if [[ "$branch" == "feat-closed" ]]; then
        echo "CLOSED"
        exit 0
    fi
    if [[ "$branch" == "feat-open" ]]; then
        echo "OPEN"
        exit 0
    fi
fi
exit 1
EOF
    chmod +x "$tmpdir/bin/gh"

    run zsh -c 'source "$WT_SCRIPT"; PATH="'"$tmpdir"'/bin:$PATH"; cd "$REPO"; gwh new "feat/closed" >/dev/null; cd "$REPO"; gwh new "feat/open" >/dev/null; cd "$REPO"; gwh prune --force'
    [ "$status" -eq 0 ]

    closed_path="$GIT_WORKTREE_DEFAULT_PATH/$(basename "$REPO")/feat-closed"
    open_path="$GIT_WORKTREE_DEFAULT_PATH/$(basename "$REPO")/feat-open"
    [ ! -e "$closed_path" ]
    [ -d "$open_path" ]
}
