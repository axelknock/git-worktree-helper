_wt_help() {
    cat <<'EOF'
git-worktree-helper — git worktree helper

Usage:
  git-worktree-helper new <branch>     Create a new worktree and cd into it
  git-worktree-helper list             List worktrees for the current repository
  git-worktree-helper switch           Fuzzy-switch to an existing worktree
  git-worktree-helper delete [opts]    Delete a worktree (trash by default)
  git-worktree-helper pr [worktree]   Open a PR for a worktree (requires gh)
  git-worktree-helper prune [opts]    Remove worktrees with closed PRs (requires gh)
  git-worktree-helper help             Show this help

Details:
  • Branch names are normalized (spaces and slashes become '-')
  • Worktrees are created under:
      $GIT_WORKTREE_DEFAULT_PATH/<repo>/<branch>
  • Existing branches are reused if present

Examples:
  git-worktree-helper new "feat/add auth"
  git-worktree-helper list
  git-worktree-helper switch
  git-worktree-helper delete
  git-worktree-helper pr feat-add-auth
  git-worktree-helper prune
EOF
}

_wt_debug() {
    if [[ -n "${WT_DEBUG:-}" ]]; then
        printf '[gwh] %s\n' "$*" >&2
    fi
}

_wt_require_repo() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "Not inside a git repository"
        return 1
    fi
}

_wt_worktree_candidates() {
    _wt_debug "worktree_candidates: start"
    git worktree list --porcelain | awk '
      $1 == "worktree" { path = $2 }
      $1 == "branch" {
        branch = $2
        sub("^refs/heads/", "", branch)
        print branch "\t" path
      }
      $1 == "detached" {
        print "(detached)" "\t" path
      }
    '
}

_wt_normalize_branch() {
    echo "$1" |
        tr '[:upper:]' '[:lower:]' |
        sed -E 's/[[:space:]]+/-/g; s|/|-|g; s/-+/-/g'
}

_wt_resolve_worktree_path() {
    target="$1"

    if [[ -z "$target" ]]; then
        echo ""
        return 1
    fi

    worktree_path=$(_wt_worktree_candidates | awk -F '\t' -v target="$target" '
      $2 == target { print $2; found = 1; exit }
      $1 == target { print $2; found = 1; exit }
    ')

    if [[ -z "$worktree_path" ]]; then
        matches=$(_wt_worktree_candidates | awk -F '\t' -v target="$target" '
          index($1, target) == 1 && !seen[$2]++ { print $2 }
          index($2, target) == 1 && !seen[$2]++ { print $2 }
        ')
        match_count=$(echo "$matches" | sed '/^$/d' | wc -l | tr -d ' ')
        if [[ "$match_count" -eq 1 ]]; then
            worktree_path="$matches"
        else
            echo "Multiple worktrees match; use a longer name" >&2
            return 1
        fi
    fi

    if [[ -z "$worktree_path" ]]; then
        return 1
    fi

    echo "$worktree_path"
}

_wt_is_registered_worktree() {
    local target="$1"
    _wt_worktree_candidates | awk -F '\t' -v path="$target" '
      $2 == path { found = 1 }
      END { exit !found }
    '
}

_wt_cmd_switch() {
    local target="$1"

    _wt_require_repo || return 1
    if [[ -n "$target" ]]; then
        worktree_path=$(_wt_resolve_worktree_path "$target") || return 1
        cd "$worktree_path"
        return 0
    fi

    echo "Usage: git-worktree-helper switch <worktree>"
    return 1
}

_wt_repo_worktree_base() {
    if [[ -z "$GIT_WORKTREE_DEFAULT_PATH" ]]; then
        return 1
    fi

    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    repo_name=$(basename "$repo_root")
    echo "$GIT_WORKTREE_DEFAULT_PATH/$repo_name"
}

_wt_find_stale_worktree() {
    target="$1"
    if [[ -d "$target" ]]; then
        echo "$target"
        return 0
    fi

    base=$(_wt_repo_worktree_base) || return 1
    if [[ ! -d "$base" ]]; then
        return 1
    fi

    target_norm=$(_wt_normalize_branch "$target")
    matches=$(find "$base" -maxdepth 1 -mindepth 1 -type d -print | awk -F/ -v target="$target_norm" '
      index($NF, target) == 1 { print }
    ')
    match_count=$(echo "$matches" | sed '/^$/d' | wc -l | tr -d ' ')

    if [[ "$match_count" -eq 1 ]]; then
        echo "$matches"
        return 0
    fi

    if [[ "$match_count" -gt 1 ]]; then
        echo "Multiple worktrees match; use a longer name"
        return 1
    fi

    return 1
}

_wt_trash() {
    local target_path="$1"

    if command -v trash >/dev/null 2>&1; then
        trash "$target_path"
        return $?
    fi

    if command -v gio >/dev/null 2>&1; then
        gio trash "$target_path"
        return $?
    fi

    if command -v trash-put >/dev/null 2>&1; then
        trash-put "$target_path"
        return $?
    fi

    if [[ -d "$HOME/.Trash" ]]; then
        base_name=$(basename "$target_path")
        timestamp=$(date +%Y%m%d%H%M%S)
        mv "$target_path" "$HOME/.Trash/${base_name}.${timestamp}"
        return $?
    fi

    echo "No trash command found; use --force to delete permanently"
    return 1
}

_wt_detach_worktree() {
    worktree_path="$1"

    worktree_gitdir=$(git -C "$worktree_path" rev-parse --git-dir 2>/dev/null)
    if [[ -z "$worktree_gitdir" ]]; then
        echo "Unable to resolve git dir for: $worktree_path"
        return 1
    fi

    if [[ "$worktree_gitdir" != /* ]]; then
        worktree_gitdir="$worktree_path/$worktree_gitdir"
    fi

    if [[ -f "$worktree_path/.git" ]]; then
        rm -f "$worktree_path/.git"
    fi

    if [[ -d "$worktree_gitdir" ]]; then
        rm -rf "$worktree_gitdir"
    fi
}

_wt_cmd_new() {
    local branch_raw="$1"
    local repo_root
    local repo_name
    local branch
    local worktree_path

    if [[ -z "$branch_raw" ]]; then
        echo "Usage: git-worktree-helper new <branch-name>"
        return 1
    fi

    _wt_require_repo || return 1

    if [[ -z "$GIT_WORKTREE_DEFAULT_PATH" ]]; then
        echo "GIT_WORKTREE_DEFAULT_PATH is not set"
        return 1
    fi

    repo_root=$(git rev-parse --show-toplevel)
    repo_name=$(basename "$repo_root")

    branch=$(_wt_normalize_branch "$branch_raw")
    worktree_path="$GIT_WORKTREE_DEFAULT_PATH/$repo_name/$branch"

    if [[ -e "$worktree_path" ]]; then
        if _wt_is_registered_worktree "$worktree_path"; then
            echo "Worktree already exists: $worktree_path"
        else
            echo "Path exists but is not a registered worktree: $worktree_path"
            echo "Delete it with: git-worktree-helper delete --force $branch"
        fi
        return 1
    fi

    mkdir -p "$(dirname "$worktree_path")"

    if git show-ref --verify --quiet "refs/heads/$branch"; then
        git worktree add -q "$worktree_path" "$branch"
    else
        git worktree add -q -b "$branch" "$worktree_path"
    fi

    cd "$worktree_path"
}

_wt_cmd_list() {
    local current_root
    _wt_require_repo || return 1
    current_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1

    git worktree list --porcelain | awk -v current="$current_root" '
      $1 == "worktree" {
        path = $2
        is_current = (path == current)
      }
      $1 == "branch" {
        branch = $2
        sub("^refs/heads/", "", branch)
        marker = is_current ? "*" : " "
        printf "%s %-12s %s\n", marker, branch, path
      }
    '
}

_wt_delete() {
    force=false
    keep=false
    target=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --force | -f)
            force=true
            ;;
        --keep)
            keep=true
            ;;
        --help | -h)
            echo "Usage: git-worktree-helper delete [--force] [--keep] [branch-or-path]"
            return 0
            ;;
        *)
            if [[ -z "$target" ]]; then
                target="$1"
            else
                echo "Unexpected argument: $1"
                return 1
            fi
            ;;
        esac
        shift
    done

    _wt_require_repo || return 1

    if [[ -z "$target" ]]; then
        echo "Usage: git-worktree-helper delete [--force] [--keep] <worktree>"
        return 1
    else
        worktree_path=$(_wt_resolve_worktree_path "$target") || true
    fi

    if [[ -z "$worktree_path" ]]; then
        worktree_path=$(_wt_find_stale_worktree "$target" 2>/dev/null) || true
    fi

    if [[ -z "$worktree_path" ]]; then
        echo "Worktree not found: $target"
        return 1
    fi

    current_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    if [[ "$worktree_path" == "$current_root" ]]; then
        echo "Refusing to delete the current worktree"
        return 1
    fi

    if [[ ! -e "$worktree_path" ]]; then
        echo "Worktree path does not exist: $worktree_path"
        return 1
    fi

    if _wt_is_registered_worktree "$worktree_path"; then
        _wt_detach_worktree "$worktree_path" || return 1
    fi

    if [[ "$keep" == true ]]; then
        return 0
    fi

    if [[ "$force" == true ]]; then
        rm -rf "$worktree_path"
        return $?
    fi

    if ! _wt_trash "$worktree_path"; then
        echo "Worktree detached; directory left in place"
        return 1
    fi
}

_wt_cmd_delete() {
    _wt_delete "$@"
}

_wt_cmd_pr() {
    local target="${1:-}"
    local worktree_path
    local branch
    local base_ref
    local base_sha
    local head_sha
    local remote_name
    local base_override
    local skip_noop_check="false"
    local prev_base_flag="false"
    local default_branch
    local candidate_ref
    local remote_head_ref
    local pr_url
    local base_fetch_time
    if [[ "$#" -gt 0 ]]; then
        shift
    fi

    if ! command -v gh >/dev/null 2>&1; then
        echo "gh not found; install GitHub CLI to open PRs"
        return 1
    fi

    _wt_require_repo || return 1

    if [[ -n "$target" && "$target" == -* ]]; then
        set -- "$target" "$@"
        target=""
    fi

    if [[ -n "$target" ]]; then
        worktree_path=$(_wt_resolve_worktree_path "$target") || return 1
    else
        worktree_path=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    fi

    branch=$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1
    if [[ "$branch" == "HEAD" ]]; then
        echo "Worktree is in detached HEAD: $worktree_path"
        return 1
    fi

    for arg in "$@"; do
        if [[ "$prev_base_flag" == "true" ]]; then
            base_override="$arg"
            prev_base_flag="false"
            continue
        fi
        if [[ "$arg" == "--base" || "$arg" == "-B" ]]; then
            prev_base_flag="true"
            continue
        fi
        if [[ "$arg" == --base=* ]]; then
            base_override="${arg#--base=}"
        fi
    done

    if [[ -n "$base_override" ]]; then
        skip_noop_check="true"
    fi

    if [[ "$skip_noop_check" != "true" ]]; then
        base_ref=""
        if git -C "$worktree_path" remote get-url origin >/dev/null 2>&1; then
            remote_name="origin"
        else
            remote_name=$(git -C "$worktree_path" remote | head -n 1)
        fi

        if [[ -n "$remote_name" ]]; then
            remote_head_ref="refs/remotes/$remote_name/HEAD"
            base_ref=$(git -C "$worktree_path" symbolic-ref -q "$remote_head_ref" 2>/dev/null)
            if [[ -z "$base_ref" ]]; then
                default_branch=$(git -C "$worktree_path" remote show "$remote_name" 2>/dev/null | awk -F': ' '/HEAD branch:/ { print $2 }')
                if [[ -n "$default_branch" ]]; then
                    candidate_ref="refs/remotes/$remote_name/$default_branch"
                    if git -C "$worktree_path" show-ref --verify --quiet "$candidate_ref"; then
                        base_ref="$candidate_ref"
                    fi
                fi
            fi
        fi

        if [[ -n "$base_ref" ]]; then
            base_fetch_time=$(git -C "$worktree_path" reflog show -1 --date=iso --format='%cd' "$base_ref" 2>/dev/null)
            if [[ -n "$base_fetch_time" ]]; then
                echo "Default base ref last fetched: $base_fetch_time"
            fi
            base_sha=$(git -C "$worktree_path" rev-parse "$base_ref" 2>/dev/null) || return 1
            head_sha=$(git -C "$worktree_path" rev-parse HEAD 2>/dev/null) || return 1
            if [[ "$base_sha" == "$head_sha" ]]; then
                echo "Branch matches $(basename "$base_ref"); no changes to open a PR"
                return 1
            fi
        else
            echo "Warning: unable to resolve default base ref locally; skipping no-op check."
        fi
    fi

    pr_url=$(cd "$worktree_path" && gh pr view "$branch" --json url -q .url 2>/dev/null)
    if [[ -n "$pr_url" ]]; then
        echo "$pr_url"
        return 0
    fi

    if ! git -C "$worktree_path" rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1; then
        if git -C "$worktree_path" remote get-url origin >/dev/null 2>&1; then
            remote_name="origin"
        else
            remote_name=$(git -C "$worktree_path" remote | head -n 1)
        fi

        if [[ -z "$remote_name" ]]; then
            echo "No git remote found; add a remote before opening a PR"
            return 1
        fi

        git -C "$worktree_path" push -u "$remote_name" "$branch" || return 1
    fi

    if [[ "$#" -eq 0 ]]; then
        (cd "$worktree_path" && gh pr create --web)
    else
        (cd "$worktree_path" && gh pr create "$@")
    fi
}

_wt_cmd_prune() {
    local force=false
    local pruned=0
    local target_state
    local current_root
    local repo_root
    local candidates
    local gh_bin
    local cwd

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --force | -f)
            force=true
            ;;
        --help | -h)
            echo "Usage: git-worktree-helper prune [--force]"
            return 0
            ;;
        *)
            echo "Unexpected argument: $1"
            return 1
            ;;
        esac
        shift
    done

    gh_bin=$(command -v gh 2>/dev/null)
    if [[ -z "$gh_bin" ]]; then
        echo "gh not found; install GitHub CLI to prune PR worktrees"
        return 1
    fi

    _wt_require_repo || return 1

    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    current_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    candidates=$(_wt_worktree_candidates)
    cwd=$PWD

    cd "$repo_root" || return 1

    while IFS=$'\t' read -r branch worktree_path; do
        if [[ "$branch" == "(detached)" || -z "$branch" || -z "$worktree_path" ]]; then
            continue
        fi

        target_state=$("$gh_bin" pr view --json state --jq '.state' "$branch" 2>/dev/null) || continue

        if [[ "$target_state" == "CLOSED" || "$target_state" == "MERGED" ]]; then
            if [[ "$worktree_path" == "$current_root" ]]; then
                echo "Skipping current worktree: $worktree_path"
                continue
            fi
            if [[ "$force" == true ]]; then
                _wt_delete --force "$worktree_path" || return 1
            else
                _wt_delete "$worktree_path" || return 1
            fi
            pruned=$((pruned + 1))
        fi
    done <<<"$candidates"

    cd "$cwd" || return 1

    if [[ "$pruned" -eq 0 ]]; then
        echo "No worktrees with closed PRs"
    fi
}

git-worktree-helper() {
    local command=$1
    if [[ "$#" -gt 0 ]]; then
        shift
    fi

    case "$command" in
    "" | help | -h | --help)
        _wt_help
        ;;
    new)
        _wt_cmd_new "$@"
        ;;
    list)
        _wt_cmd_list
        ;;
    switch)
        _wt_cmd_switch "$1"
        ;;
    delete)
        _wt_cmd_delete "$@"
        ;;
    pr)
        _wt_cmd_pr "$@"
        ;;
    prune)
        _wt_cmd_prune "$@"
        ;;

    *)
        echo "Unknown command: $command"
        echo
        _wt_help
        return 1
        ;;
    esac
}

gwh() {
    git-worktree-helper "$@"
}

_wt_completion_worktrees() {
    local -a worktrees
    local candidates
    _wt_debug "completion_worktrees: start"
    candidates=$(_wt_worktree_candidates)
    _wt_debug "completion_worktrees: candidates=${candidates}"
    worktrees=("${(@f)$(echo "$candidates" | awk -F '\t' '{print $1}')}")
    _wt_debug "completion_worktrees: count=${#worktrees[@]}"
    _describe -t worktrees 'worktrees' worktrees
}

_wt_completion() {
    local -a subcommands
    _wt_debug "completion: current=$CURRENT words=${words[*]}"
    subcommands=(
        'new:Create a new worktree'
        'list:List worktrees for the current repository'
        'switch:Fuzzy-switch to an existing worktree'
        'delete:Delete a worktree'
        'pr:Open a PR for a worktree (requires gh)'
        'prune:Remove worktrees with closed PRs (requires gh)'
        'help:Show help'
    )

    if (( CURRENT == 2 )); then
        _describe -t commands 'wt command' subcommands
        return
    fi

    case $words[2] in
    delete)
        if [[ $words[CURRENT] == --* ]]; then
            compadd -- --force --keep
            return
        fi
        _wt_completion_worktrees
        ;;
    switch)
        _wt_completion_worktrees
        ;;
    pr)
        _wt_completion_worktrees
        ;;
    prune)
        if [[ $words[CURRENT] == --* ]]; then
            compadd -- --force
            return
        fi
        ;;
    new)
        _message 'branch name'
        ;;
    esac
}

if typeset -f compdef >/dev/null 2>&1; then
    compdef _wt_completion git-worktree-helper
    compdef _wt_completion gwh
else
    _wt_debug "compdef not available; completion disabled"
fi
