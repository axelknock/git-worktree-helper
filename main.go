package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

type worktreeCandidate struct {
	Branch string
	Path   string
}

var (
	errNoMatch        = errors.New("no matching worktree")
	errMultipleMatch  = errors.New("Multiple worktrees match; use a longer name")
	whitespacePattern = regexp.MustCompile(`[[:space:]]+`)
	dashPattern       = regexp.MustCompile(`-+`)
)

func main() {
	cmdName := filepath.Base(os.Args[0])
	if len(os.Args) < 2 {
		printHelp(cmdName)
		return
	}

	command := os.Args[1]
	args := os.Args[2:]

	var exitCode int
	switch command {
	case "", "help", "-h", "--help":
		printHelp(cmdName)
		exitCode = 0
	case "new":
		exitCode = cmdNew(cmdName, args)
	case "list":
		exitCode = cmdList()
	case "switch":
		exitCode = cmdSwitch(cmdName, args)
	case "delete":
		exitCode = cmdDelete(cmdName, args)
	case "completion":
		exitCode = cmdCompletion(cmdName, args)
	default:
		fmt.Fprintf(os.Stderr, "Unknown command: %s\n\n", command)
		printHelp(cmdName)
		exitCode = 1
	}

	if exitCode != 0 {
		os.Exit(exitCode)
	}
}

func printHelp(cmdName string) {
	fmt.Printf(`%s — git worktree helper

Usage:
  %s new <branch>     Create a new worktree and print its path
  %s list             List worktrees for the current repository
  %s switch <target>  Print the path to an existing worktree
  %s delete [opts]    Delete a worktree (trash by default)
  %s completion zsh   Print zsh completion script
  %s help             Show this help

Details:
  • Branch names are normalized (spaces and slashes become '-')
  • Worktrees are created under:
      $GIT_WORKTREE_DEFAULT_PATH/<repo>/<branch>
  • Existing branches are reused if present
  • Use: cd "$(%s new ...)" or cd "$(%s switch ...)"

Examples:
  %s new "feat/add auth"
  %s list
  %s switch
  %s delete
  %s completion zsh
`,
		cmdName,
		cmdName,
		cmdName,
		cmdName,
		cmdName,
		cmdName,
		cmdName,
		cmdName,
		cmdName,
		cmdName,
		cmdName,
		cmdName,
		cmdName,
		cmdName,
	)
}

func debugf(format string, args ...any) {
	if os.Getenv("WT_DEBUG") == "" {
		return
	}
	fmt.Fprintf(os.Stderr, "[gwh] "+format+"\n", args...)
}

func requireRepo() bool {
	cmd := exec.Command("git", "rev-parse", "--is-inside-work-tree")
	cmd.Stdout = nil
	cmd.Stderr = nil
	if err := cmd.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "Not inside a git repository")
		return false
	}
	return true
}

func gitOutput(args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return "", err
	}
	return strings.TrimSpace(out.String()), nil
}

func worktreeCandidates() ([]worktreeCandidate, error) {
	debugf("worktree_candidates: start")
	out, err := gitOutput("worktree", "list", "--porcelain")
	if err != nil {
		return nil, err
	}

	var candidates []worktreeCandidate
	var currentPath string
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		switch fields[0] {
		case "worktree":
			if len(fields) > 1 {
				currentPath = fields[1]
			}
		case "branch":
			if len(fields) > 1 {
				branch := strings.TrimPrefix(fields[1], "refs/heads/")
				candidates = append(candidates, worktreeCandidate{
					Branch: branch,
					Path:   currentPath,
				})
			}
		case "detached":
			candidates = append(candidates, worktreeCandidate{
				Branch: "(detached)",
				Path:   currentPath,
			})
		}
	}
	return candidates, nil
}

func normalizeBranch(raw string) string {
	lowered := strings.ToLower(raw)
	normalized := whitespacePattern.ReplaceAllString(lowered, "-")
	normalized = strings.ReplaceAll(normalized, "/", "-")
	normalized = dashPattern.ReplaceAllString(normalized, "-")
	return normalized
}

func resolveWorktreePath(target string, candidates []worktreeCandidate) (string, error) {
	if target == "" {
		return "", errNoMatch
	}

	for _, candidate := range candidates {
		if candidate.Path == target || candidate.Branch == target {
			return candidate.Path, nil
		}
	}

	matches := map[string]struct{}{}
	for _, candidate := range candidates {
		if strings.HasPrefix(candidate.Branch, target) || strings.HasPrefix(candidate.Path, target) {
			matches[candidate.Path] = struct{}{}
		}
	}

	if len(matches) == 1 {
		for path := range matches {
			return path, nil
		}
	}

	if len(matches) > 1 {
		return "", errMultipleMatch
	}

	return "", errNoMatch
}

func isRegisteredWorktree(path string) bool {
	candidates, err := worktreeCandidates()
	if err != nil {
		return false
	}
	for _, candidate := range candidates {
		if candidate.Path == path {
			return true
		}
	}
	return false
}

func repoWorktreeBase() (string, error) {
	root := os.Getenv("GIT_WORKTREE_DEFAULT_PATH")
	if root == "" {
		return "", errors.New("GIT_WORKTREE_DEFAULT_PATH is not set")
	}
	repoRoot, err := gitOutput("rev-parse", "--show-toplevel")
	if err != nil {
		return "", err
	}
	repoName := filepath.Base(repoRoot)
	return filepath.Join(root, repoName), nil
}

func findStaleWorktree(target string) (string, error) {
	if target == "" {
		return "", errNoMatch
	}

	if info, err := os.Stat(target); err == nil && info.IsDir() {
		return target, nil
	}

	base, err := repoWorktreeBase()
	if err != nil {
		return "", errNoMatch
	}
	if info, err := os.Stat(base); err != nil || !info.IsDir() {
		return "", errNoMatch
	}

	targetNorm := normalizeBranch(target)
	entries, err := os.ReadDir(base)
	if err != nil {
		return "", errNoMatch
	}

	var matches []string
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		if strings.HasPrefix(entry.Name(), targetNorm) {
			matches = append(matches, filepath.Join(base, entry.Name()))
		}
	}

	if len(matches) == 1 {
		return matches[0], nil
	}
	if len(matches) > 1 {
		return "", errMultipleMatch
	}
	return "", errNoMatch
}

func cmdSwitch(cmdName string, args []string) int {
	if !requireRepo() {
		return 1
	}

	if len(args) == 0 {
		fmt.Printf("Usage: %s switch <worktree>\n", cmdName)
		return 1
	}

	candidates, err := worktreeCandidates()
	if err != nil {
		return 1
	}
	worktreePath, err := resolveWorktreePath(args[0], candidates)
	if err != nil {
		if !errors.Is(err, errNoMatch) {
			fmt.Fprintln(os.Stderr, err.Error())
		}
		return 1
	}

	fmt.Println(worktreePath)
	return 0
}

func cmdNew(cmdName string, args []string) int {
	if len(args) == 0 {
		fmt.Printf("Usage: %s new <branch-name>\n", cmdName)
		return 1
	}

	if !requireRepo() {
		return 1
	}

	if os.Getenv("GIT_WORKTREE_DEFAULT_PATH") == "" {
		fmt.Fprintln(os.Stderr, "GIT_WORKTREE_DEFAULT_PATH is not set")
		return 1
	}

	repoRoot, err := gitOutput("rev-parse", "--show-toplevel")
	if err != nil {
		return 1
	}

	repoName := filepath.Base(repoRoot)
	branch := normalizeBranch(args[0])
	worktreePath := filepath.Join(os.Getenv("GIT_WORKTREE_DEFAULT_PATH"), repoName, branch)

	headCheck := exec.Command("git", "rev-parse", "--verify", "HEAD")
	headCheck.Stdout = nil
	headCheck.Stderr = nil
	if err := headCheck.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "Repository has no commits; create an initial commit before adding a worktree")
		return 1
	}

	if _, err := os.Stat(worktreePath); err == nil {
		if isRegisteredWorktree(worktreePath) {
			fmt.Fprintf(os.Stderr, "Worktree already exists: %s\n", worktreePath)
		} else {
			fmt.Fprintf(os.Stderr, "Path exists but is not a registered worktree: %s\n", worktreePath)
			fmt.Fprintf(os.Stderr, "Delete it with: %s delete --force %s\n", cmdName, branch)
		}
		return 1
	}

	if err := os.MkdirAll(filepath.Dir(worktreePath), 0o755); err != nil {
		return 1
	}

	branchExists := exec.Command("git", "show-ref", "--verify", "--quiet", "refs/heads/"+branch)
	branchExists.Stdout = nil
	branchExists.Stderr = nil
	err = branchExists.Run()

	var addCmd *exec.Cmd
	if err == nil {
		addCmd = exec.Command("git", "worktree", "add", worktreePath, branch)
	} else {
		addCmd = exec.Command("git", "worktree", "add", "-b", branch, worktreePath)
	}
	addCmd.Stdout = os.Stderr
	addCmd.Stderr = os.Stderr
	if err := addCmd.Run(); err != nil {
		return 1
	}

	fmt.Println(worktreePath)
	return 0
}

func cmdList() int {
	if !requireRepo() {
		return 1
	}

	currentRoot, err := gitOutput("rev-parse", "--show-toplevel")
	if err != nil {
		return 1
	}

	out, err := gitOutput("worktree", "list", "--porcelain")
	if err != nil {
		return 1
	}

	var (
		currentPath string
		isCurrent   bool
	)

	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		switch fields[0] {
		case "worktree":
			if len(fields) > 1 {
				currentPath = fields[1]
				isCurrent = (currentPath == currentRoot)
			}
		case "branch":
			if len(fields) > 1 {
				branch := strings.TrimPrefix(fields[1], "refs/heads/")
				marker := " "
				if isCurrent {
					marker = "*"
				}
				fmt.Printf("%s %-12s %s\n", marker, branch, currentPath)
			}
		}
	}
	return 0
}

func cmdDelete(cmdName string, args []string) int {
	force := false
	keep := false
	target := ""

	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch arg {
		case "--force", "-f":
			force = true
		case "--keep":
			keep = true
		case "--help", "-h":
			fmt.Printf("Usage: %s delete [--force] [--keep] [branch-or-path]\n", cmdName)
			return 0
		default:
			if target == "" {
				target = arg
			} else {
				fmt.Fprintf(os.Stderr, "Unexpected argument: %s\n", arg)
				return 1
			}
		}
	}

	if !requireRepo() {
		return 1
	}

	if target == "" {
		fmt.Printf("Usage: %s delete [--force] [--keep] <worktree>\n", cmdName)
		return 1
	}

	var worktreePath string
	candidates, err := worktreeCandidates()
	if err == nil {
		if resolved, resolveErr := resolveWorktreePath(target, candidates); resolveErr == nil {
			worktreePath = resolved
		} else if !errors.Is(resolveErr, errNoMatch) {
			fmt.Fprintln(os.Stderr, resolveErr.Error())
		}
	}

	if worktreePath == "" {
		if resolved, resolveErr := findStaleWorktree(target); resolveErr == nil {
			worktreePath = resolved
		} else if !errors.Is(resolveErr, errNoMatch) {
			fmt.Fprintln(os.Stderr, resolveErr.Error())
		}
	}

	if worktreePath == "" {
		fmt.Fprintf(os.Stderr, "Worktree not found: %s\n", target)
		return 1
	}

	currentRoot, err := gitOutput("rev-parse", "--show-toplevel")
	if err != nil {
		return 1
	}
	if worktreePath == currentRoot {
		fmt.Fprintln(os.Stderr, "Refusing to delete the current worktree")
		return 1
	}

	if _, err := os.Stat(worktreePath); err != nil {
		fmt.Fprintf(os.Stderr, "Worktree path does not exist: %s\n", worktreePath)
		return 1
	}

	if isRegisteredWorktree(worktreePath) {
		if err := detachWorktree(worktreePath); err != nil {
			return 1
		}
	}

	if keep {
		return 0
	}

	if force {
		if err := os.RemoveAll(worktreePath); err != nil {
			return 1
		}
		return 0
	}

	if err := trash(worktreePath); err != nil {
		fmt.Fprintln(os.Stderr, "Worktree detached; directory left in place")
		return 1
	}

	return 0
}

func trash(target string) error {
	for _, candidate := range []string{"trash", "gio", "trash-put"} {
		path, err := exec.LookPath(candidate)
		if err != nil {
			continue
		}
		args := []string{target}
		if candidate == "gio" {
			args = []string{"trash", target}
		}
		cmd := exec.Command(path, args...)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		return cmd.Run()
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return errors.New("no trash command found; use --force to delete permanently")
	}
	trashDir := filepath.Join(home, ".Trash")
	info, err := os.Stat(trashDir)
	if err == nil && info.IsDir() {
		baseName := filepath.Base(target)
		timestamp := time.Now().Format("20060102150405")
		return os.Rename(target, filepath.Join(trashDir, baseName+"."+timestamp))
	}

	return errors.New("no trash command found; use --force to delete permanently")
}

func detachWorktree(worktreePath string) error {
	out, err := gitOutput("-C", worktreePath, "rev-parse", "--git-dir")
	if err != nil {
		fmt.Fprintf(os.Stderr, "Unable to resolve git dir for: %s\n", worktreePath)
		return err
	}

	gitDir := out
	if !filepath.IsAbs(gitDir) {
		gitDir = filepath.Join(worktreePath, gitDir)
	}

	if _, err := os.Stat(filepath.Join(worktreePath, ".git")); err == nil {
		if err := os.Remove(filepath.Join(worktreePath, ".git")); err != nil {
			return err
		}
	}

	if info, err := os.Stat(gitDir); err == nil && info.IsDir() {
		if err := os.RemoveAll(gitDir); err != nil {
			return err
		}
	}

	return nil
}

func cmdCompletion(cmdName string, args []string) int {
	if len(args) == 0 {
		fmt.Fprintf(os.Stderr, "Usage: %s completion zsh\n", cmdName)
		return 1
	}
	if args[0] != "zsh" {
		fmt.Fprintf(os.Stderr, "Unsupported shell: %s\n", args[0])
		return 1
	}
	fmt.Print(zshCompletionScript())
	return 0
}

func zshCompletionScript() string {
	script := []string{
		"#compdef gwh git-worktree-helper",
		"",
		"_gwh_worktree_candidates() {",
		"  git worktree list --porcelain | awk '",
		"    $1 == \"worktree\" { path = $2 }",
		"    $1 == \"branch\" {",
		"      branch = $2",
		"      sub(\"^refs/heads/\", \"\", branch)",
		"      print branch \"\\t\" path",
		"    }",
		"    $1 == \"detached\" {",
		"      print \"(detached)\" \"\\t\" path",
		"    }",
		"  '",
		"}",
		"",
		"_gwh_completion_worktrees() {",
		"  local -a worktrees",
		"  local candidates",
		"  candidates=$(_gwh_worktree_candidates)",
		"  worktrees=(${(f)$(echo \"$candidates\" | awk -F '\\t' '{print $1}')})",
		"  _describe -t worktrees 'worktrees' worktrees",
		"}",
		"",
		"_gwh_completion() {",
		"  local -a subcommands",
		"  subcommands=(",
		"    'new:Create a new worktree'",
		"    'list:List worktrees for the current repository'",
		"    'switch:Fuzzy-switch to an existing worktree'",
		"    'delete:Delete a worktree'",
		"    'completion:Print shell completion'",
		"    'help:Show help'",
		"  )",
		"",
		"  if (( CURRENT == 2 )); then",
		"    _describe -t commands 'gwh command' subcommands",
		"    return",
		"  fi",
		"",
		"  case $words[2] in",
		"  delete)",
		"    if [[ $words[CURRENT] == --* ]]; then",
		"      compadd -- --force --keep",
		"      return",
		"    fi",
		"    _gwh_completion_worktrees",
		"    ;;",
		"  switch)",
		"    _gwh_completion_worktrees",
		"    ;;",
		"  new)",
		"    _message 'branch name'",
		"    ;;",
		"  completion)",
		"    compadd -- zsh",
		"    ;;",
		"  esac",
		"}",
		"",
		"if typeset -f compdef >/dev/null 2>&1; then",
		"  compdef _gwh_completion gwh git-worktree-helper",
		"fi",
	}
	return strings.Join(script, "\n") + "\n"
}
