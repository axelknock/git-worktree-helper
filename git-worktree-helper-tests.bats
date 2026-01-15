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

@test "gwh switch moves to worktree" {
    run zsh -c 'source "$WT_SCRIPT"; cd "$REPO"; gwh new "feat/demo" >/dev/null; cd "$REPO"; gwh switch feat-demo; pwd'
    [ "$status" -eq 0 ]
    expected="$GIT_WORKTREE_DEFAULT_PATH/$(basename "$REPO")/feat-demo"
    output_real=$(cd "$output" && pwd -P)
    expected_real=$(cd "$expected" && pwd -P)
    [ "$output_real" = "$expected_real" ]
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
