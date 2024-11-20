{
  inputs = {
    # keep-sorted start block=yes case=no
    flake-utils.url = "github:numtide/flake-utils";
    gomod2nix = {
      url = "github:nix-community/gomod2nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    systems.url = "github:nix-systems/default";
    treefmt-nix = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:numtide/treefmt-nix";
    };
    # keep-sorted end
  };

  outputs =
    {
      self,
      flake-utils,
      nixpkgs,
      treefmt-nix,
      systems,
      gomod2nix,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ gomod2nix.overlays.default ];
        };
        treefmtEval = treefmt-nix.lib.evalModule pkgs (
          { pkgs, ... }:
          {
            projectRootFile = "flake.nix";
            programs.keep-sorted.enable = true;
            programs.nixfmt = {
              enable = true;
              package = pkgs.nixfmt-rfc-style;
            };
            programs.statix.enable = true;
          }
        );
        shellHook = ''
          GOROOT="$(dirname $(dirname $(which go)))/share/go"
          unset GOPATH;
        '';
      in
      with pkgs;
      rec {
        devShells = {
          # $ nix develop
          default = pkgs.mkShell {
            inherit shellHook;
            buildInputs = with pkgs; [
              unzip
              crane # Manipulate oci repos
            ];
            nativeBuildInputs = with pkgs; [
              go
              gotools
              gopls
              golint
              golangci-lint
              packages.gomod2nix
            ];
          };
        };
        packages.default =
          let
            inherit (pkgs.lib.importTOML ./gomod2nix.toml) mod;
            commit = if (self ? rev) then self.rev else "dirty";
          in
          pkgs.buildGoApplication rec {
            pname = "zarf";
            version = "0.42.2";
            pwd = ./.;
            src = ./.;
            modules = ./gomod2nix.toml;

            CGO_ENABLED = 0;

            ldflags = [
              "-s"
              "-w"
              "-X github.com/zarf-dev/zarf/src/config.CLIVersion=v${version}"
              "-X k8s.io/component-base/version.gitVersion=v0.0.0+zarfv${version}"
              "-X k8s.io/component-base/version.gitCommit=${commit}"
              "-X k8s.io/component-base/version.buildDate=\"\""
              "-X github.com/derailed/k9s/cmd.version=${mod."github.com/derailed/k9s".version}"
              "-X github.com/derailed/k9s/cmd.version=${mod."github.com/derailed/k9s".version}"
              "-X github.com/google/go-containerregistry/cmd/crane/cmd.Version=${
                mod."github.com/google/go-containerregistry".version
              }"
              "-X github.com/zarf-dev/zarf/src/cmd/tools.syftVersion=${mod."github.com/anchore/syft".version}"
              "-X github.com/zarf-dev/zarf/src/cmd/tools.archiverVersion=${
                mod."github.com/mholt/archiver/v3".version
              }"
              "-X github.com/zarf-dev/zarf/src/cmd/tools.helmVersion=${mod."helm.sh/helm/v3".version}"
              "-X helm.sh/helm/v3/pkg/lint/rules.k8sVersionMajor=${
                lib.versions.major mod."k8s.io/client-go".version
              }"
              "-X helm.sh/helm/v3/pkg/lint/rules.k8sVersionMinor=${
                lib.versions.minor mod."k8s.io/client-go".version
              }"
              "-X helm.sh/helm/v3/pkg/chartutil.k8sVersionMajor=${
                lib.versions.major mod."k8s.io/client-go".version
              }"
              "-X helm.sh/helm/v3/pkg/chartutil.k8sVersionMinor=${
                lib.versions.minor mod."k8s.io/client-go".version
              }"
            ];

            nativeBuildInputs = [ installShellFiles ];

            postInstall = lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
              export K9S_LOGS_DIR=$(mktemp -d)
              installShellCompletion --cmd zarf \
                --bash <($out/bin/zarf completion --no-log-file bash) \
                --fish <($out/bin/zarf completion --no-log-file fish) \
                --zsh  <($out/bin/zarf completion --no-log-file zsh)
            '';

            preBuild = ''
              mkdir -p build/ui
              touch build/ui/index.html
            '';

            subPackages = [ "." ];
          };
        packages.image = pkgs.dockerTools.buildImage {
          name = "ghcr.io/a1994sc/go/" + packages.default.pname;
          tag = packages.default.version;
          fromImage = pkgs.dockerTools.pullImage {
            imageName = "cgr.dev/chainguard/static";
            finalImageName = "cgr.dev/chainguard/static";
            finalImageTag = "latest";
            imageDigest = "sha256:561b669256bd2b5a8afed34614e8cb1b98e4e2f66d42ac7a8d80d317d8c8688a";
            sha256 = "sha256-L8US9pl39QN9HcPvZU482Fn0RNHIO5Rr10zq2a6nQGk=";
            arch = "amd64";
          };
          config = {
            Cmd = [
              "/bin/${packages.default.pname}"
              "internal"
              "agent"
              "--log-level=debug"
              "--log-format=text"
              "--no-log-file"
            ];
          };
          uid = 65532;
          gid = 65532;
          copyToRoot = packages.default;
        };
        packages.gomod2nix = gomod2nix.packages.${system}.default.overrideAttrs (
          final: prev: {
            patches = [
              (pkgs.fetchpatch2 {
                url = "https://github.com/nix-community/gomod2nix/commit/f5ce6cf5a48ba9cb3d6e670fae1cd104d45eea44.patch";
                hash = "sha256-DPJh0o4xiPSscXWyEcp2TfP8DwoV6qGublr7iGT0QLs=";
              })
            ];
          }
        );
        formatter = treefmtEval.config.build.wrapper;
      }
    );
}
