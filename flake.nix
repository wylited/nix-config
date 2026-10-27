{
  description = "Wylited's homelab config — fleet: warden, scout-darwin, scout-asahi, rogue-glyph, artificer (plan: ./../PLAN.md)";

  inputs = {
    # rolling unstable, locked on first eval — lets warden track the latest
    # immich without rebasing the whole fleet (services.immich.package)
    nixpkgs-immich.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        home-manager.follows = "home-manager";
      };
    };
    # secrets: encrypted-in-repo, decrypted at activation (plan 03 — the key
    # strategy decision lives in modules/secrets.nix)
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # hardware-specific NixOS modules (warden: Cezanne laptop — plan 03 input list)
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    # wycal — CalDAV web client (cal.ts.wyli.tech on warden); nix-built via
    # bun2nix. Public repo (flipped 2026-10-28) so the fleet flake stays
    # evaluable without github credentials.
    wycal.url = "github:wylited/wycal";

    # TODO when scout-asahi lands: nixos-apple-silicon input
    #   github:nix-community/nixos-apple-silicon (see nix-migration plan 05)
  };

  outputs = inputs@{ self, nixpkgs, nix-darwin, home-manager, ... }: {
    # ============ scout-darwin (sd — M1 Pro MacBook, macOS boot) ============
    darwinConfigurations.scout-darwin = nix-darwin.lib.darwinSystem {
      system = "aarch64-darwin";

      specialArgs = { inherit self inputs; };

      modules = [
        ./hosts/scout-darwin
        inputs.sops-nix.darwinModules.sops   # platform half of modules/secrets.nix (plan 03)
        home-manager.darwinModules.home-manager {
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            extraSpecialArgs = { inherit self inputs; };
            users.wyli = { imports = [ ./home/wyli.nix ]; };
          };
        }
      ];
    };

    # ============ warden (wa — homeserver, all of PLAN.md) ============
    nixosConfigurations.warden = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit self inputs; };
      modules = [
        ./hosts/warden
        inputs.sops-nix.nixosModules.sops    # platform half of modules/secrets.nix (plan 03)
        home-manager.nixosModules.home-manager {
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            extraSpecialArgs = { inherit self inputs; };
            users.wyli = { imports = [ ./home/wyli.nix ]; };
          };
        }
      ];
    };

    # ============ scout-asahi (sa — same M1 Pro, Asahi NixOS boot, plan 05) ============
    nixosConfigurations.scout-asahi = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      specialArgs = { inherit self inputs; };
      modules = [
        ./hosts/scout-asahi
        inputs.sops-nix.nixosModules.sops    # platform half of modules/secrets.nix (plan 03)
        home-manager.nixosModules.home-manager {
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            extraSpecialArgs = { inherit self inputs; };
            users.wyli = { imports = [ ./home/wyli.nix ]; };
          };
        }
      ];
    };

    # ============ artificer (an — rpi5, 8 GB, NixOS sd-image). Archetype
    #               named 2026-10-11; hosting deferred. Provisioning route
    #               decided 2026-10-11: build the sd-image on warden (binfmt),
    #               dd to card/USB-SSD, boot — then remote rebuilds from
    #               warden. nixos-anywhere skipped: kexec is the flaky part
    #               on Pi kernels, and the sd-image module owns the Pi-5
    #               firmware/boot files for us. ============
    nixosConfigurations.artificer-nixos = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      specialArgs = { inherit self inputs; };
      modules = [
        ./hosts/artificer
        inputs.sops-nix.nixosModules.sops    # platform half of modules/secrets.nix (plan 03)
      ];
    };
  };
}
