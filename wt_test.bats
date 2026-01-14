#!/usr/bin/env bats

setup() {
    tmpdir=$(mktemp -d /tmp/wt-test.XXXXXX)
    repo="$tmpdir/repo"
    worktree_root="$tmpdir/worktrees"
    mkdir -p "$repo" "$worktree_root"

    git -C "$repo" init >/dev/null
    git -C "$repo" -c user.name='wt test' -c user.email='wt@example.test' \
        commit --allow-empty -m 'init' >/dev/null

    export REPO="$repo"
    export GIT_WORKTREE_DEFAULT_PATH="$worktree_root"
    export WT_SCRIPT="$BATS_TEST_DIRNAME/.wt.sh"
}

teardown() {
    rm -rf "$tmpdir"
}

@test "wt help shows usage" {
    run zsh -c 'source "$WT_SCRIPT"; wt help'
    [ "$status" -eq 0 ]
    [[ "$output" == *"git worktree helper"* ]]
}

@test "wt list shows current worktree" {
    run zsh -c 'source "$WT_SCRIPT"; cd "$REPO"; wt list'
    [ "$status" -eq 0 ]
    [[ "$output" == *"$REPO"* ]]
}

@test "wt new creates worktree and cds" {
    run zsh -c 'source "$WT_SCRIPT"; cd "$REPO"; wt new "feat/demo"; pwd'
    [ "$status" -eq 0 ]
    expected="$GIT_WORKTREE_DEFAULT_PATH/$(basename "$REPO")/feat-demo"
    [ "$output" = "$expected" ]
    [ -d "$expected" ]
}

@test "wt switch moves to worktree" {
    run zsh -c 'source "$WT_SCRIPT"; cd "$REPO"; wt new "feat/demo" >/dev/null; cd "$REPO"; wt switch feat-demo; pwd'
    [ "$status" -eq 0 ]
    expected="$GIT_WORKTREE_DEFAULT_PATH/$(basename "$REPO")/feat-demo"
    [ "$output" = "$expected" ]
}

@test "wt delete removes worktree with --force" {
    run zsh -c 'source "$WT_SCRIPT"; cd "$REPO"; wt new "feat/demo" >/dev/null; cd "$REPO"; wt delete --force feat-demo'
    [ "$status" -eq 0 ]
    expected="$GIT_WORKTREE_DEFAULT_PATH/$(basename "$REPO")/feat-demo"
    [ ! -e "$expected" ]
}

@test "wt switch reports ambiguous matches" {
    run zsh -c 'source "$WT_SCRIPT"; cd "$REPO"; wt new "feat/alpha" >/dev/null; cd "$REPO"; wt new "feat/alpine" >/dev/null; cd "$REPO"; wt switch fe'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Multiple worktrees match; use a longer name"* ]]
}
