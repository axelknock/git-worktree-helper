package main

import (
	"errors"
	"testing"
)

func TestNormalizeBranch(t *testing.T) {
	tests := []struct {
		in   string
		want string
	}{
		{"Feat/Add Auth", "feat-add-auth"},
		{"foo  bar", "foo-bar"},
		{"foo---bar", "foo-bar"},
		{"foo/bar baz", "foo-bar-baz"},
	}

	for _, tt := range tests {
		if got := normalizeBranch(tt.in); got != tt.want {
			t.Fatalf("normalizeBranch(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestResolveWorktreePath(t *testing.T) {
	candidates := []worktreeCandidate{
		{Branch: "feat-demo", Path: "/tmp/feat-demo"},
		{Branch: "feat-alpine", Path: "/tmp/feat-alpine"},
	}

	if got, err := resolveWorktreePath("/tmp/feat-demo", candidates); err != nil || got != "/tmp/feat-demo" {
		t.Fatalf("exact path match failed: %v %q", err, got)
	}

	if got, err := resolveWorktreePath("feat-demo", candidates); err != nil || got != "/tmp/feat-demo" {
		t.Fatalf("exact branch match failed: %v %q", err, got)
	}

	if _, err := resolveWorktreePath("feat", candidates); err == nil {
		t.Fatalf("expected ambiguous match error")
	}

	if _, err := resolveWorktreePath("missing", candidates); !errors.Is(err, errNoMatch) {
		t.Fatalf("expected no match error, got %v", err)
	}
}
