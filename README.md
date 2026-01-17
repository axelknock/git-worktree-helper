## Testing

```sh
bats git-worktree-helper-tests.bats
```

## Nix flake install (bash/zsh)

This repo exposes a `homeManagerModules.default` module that sources the helper
in your shell, plus a `packages.*.git-worktree-helper` package that installs
`git-worktree-helper` (and `gwh`) into `PATH` for non-interactive use.
Sourcing is still recommended for interactive shells so `new`/`switch` can `cd`
and completions are available.

Example Home Manager configuration:

```nix
{
  inputs.git-worktree-helper.url = "github.com/axelknock/git-worktree-helper";

  outputs = { self, nixpkgs, home-manager, git-worktree-helper, ... }:
    let
      system = "aarch64-darwin";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      homeConfigurations."you" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          git-worktree-helper.homeManagerModules.default
          {
            programs.git-worktree-helper.enable = true;
          }
        ];
      };
    };
}
```

If you prefer to source it manually, use:

```nix
{
  home.packages = [ git-worktree-helper.packages.${pkgs.stdenv.hostPlatform.system}.git-worktree-helper ];
  programs.bash.initExtra = ''
    source ${git-worktree-helper.packages.${pkgs.stdenv.hostPlatform.system}.git-worktree-helper}/share/git-worktree-helper/git-worktree-helper.sh
  '';
  programs.zsh.initContent = ''
    source ${git-worktree-helper.packages.${pkgs.stdenv.hostPlatform.system}.git-worktree-helper}/share/git-worktree-helper/git-worktree-helper.sh
  '';
}
```
