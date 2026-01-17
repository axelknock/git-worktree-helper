{
  description = "git-worktree-helper";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          git-worktree-helper = pkgs.stdenvNoCC.mkDerivation {
            pname = "git-worktree-helper";
            version = "0.1.0";
            src = ./.;
            dontBuild = true;
            installPhase = ''
              install -D -m 0644 git-worktree-helper.sh \
                $out/share/git-worktree-helper/git-worktree-helper.sh
              mkdir -p $out/bin
              cat > $out/bin/git-worktree-helper <<EOF
#!/usr/bin/env bash
set -o pipefail
source "${placeholder "out"}/share/git-worktree-helper/git-worktree-helper.sh"
git-worktree-helper "\$@"
EOF
              chmod 0755 $out/bin/git-worktree-helper
              ln -s $out/bin/git-worktree-helper $out/bin/gwh
            '';
            meta = with pkgs.lib; {
              description = "Git worktree helper functions for bash/zsh";
              license = licenses.mit;
              platforms = platforms.all;
            };
          };

          default = self.packages.${system}.git-worktree-helper;
        });

      homeManagerModules.default = { config, pkgs, lib, ... }:
        let
          cfg = config.programs.git-worktree-helper;
          pkg = self.packages.${pkgs.stdenv.hostPlatform.system}.git-worktree-helper;
          sourceLine = ''
            source ${pkg}/share/git-worktree-helper/git-worktree-helper.sh
          '';
        in
        {
          options.programs.git-worktree-helper = {
            enable = lib.mkEnableOption "git-worktree-helper";
            enableBash = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Source git-worktree-helper in bash.";
            };
            enableZsh = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Source git-worktree-helper in zsh.";
            };
          };

          config = lib.mkIf cfg.enable {
            home.packages = [ pkg ];

            programs.bash.initExtra = lib.mkIf cfg.enableBash sourceLine;
            programs.zsh.initContent = lib.mkIf cfg.enableZsh sourceLine;
          };
        };
    };
}
