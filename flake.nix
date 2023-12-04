{
  description = "LiquidHaskell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    liquidhaskell-src = {
      url = "github:ucsd-progsys/liquidhaskell";
      flake = false;
    };
    liquid-fixpoint-src = {
      url = "github:ucsd-progsys/liquid-fixpoint";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, liquidhaskell-src, liquid-fixpoint-src }:
    let
      composeOverlays = funs: builtins.foldl' nixpkgs.lib.composeExtensions (self: super: { }) funs;

      haskellOverlay = compiler: final: prev: new:
        let new-overrides = new.overrides or (a: b: { }); in
        {
          haskell = prev.haskell // {
            packages = prev.haskell.packages // {
              ${compiler} = prev.haskell.packages.${compiler}.override
                (old: old // new // {
                  overrides = self: super: old.overrides self super // new-overrides self super;
                });
            };
          };
        };
      
      haskellPackagesOverlay = compiler: final: prev: cur-packages-overlay:
        haskellOverlay compiler final prev { overrides = cur-packages-overlay; };

      ghc = "ghc947";

      beComponent = pkgs: pkg: pkgs.haskell.lib.overrideCabal pkg (old: {
        enableLibraryProfiling = false;
        buildTools = (old.buildTools or [ ]) ++ [ pkgs.z3 ];
      });

      mkOutputs = system: 
        let
          # do not use when defining the overlays
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ self.overlay.${system} ];
          };
        in
        {

        packages = {
          # Group 0: Liquid-Fixpoint
          liquid-fixpoint = pkgs.haskell.packages.${ghc}.liquid-fixpoint;
          # Group 1: LH without tests
          liquidhaskell-boot = pkgs.haskell.packages.${ghc}.liquidhaskell-boot;
          liquidhaskell = pkgs.haskell.packages.${ghc}.liquidhaskell;
          # Group 2: Depends on LH
          liquid-parallel = pkgs.haskell.packages.${ghc}.liquid-parallel;
          liquid-platform = pkgs.haskell.packages.${ghc}.liquid-platform;
          liquid-prelude = pkgs.haskell.packages.${ghc}.liquid-prelude;
          liquid-vector = pkgs.haskell.packages.${ghc}.liquid-vector;
          # Group 3: Depends on all of the above
          liquidhaskell_with_tests = pkgs.haskell.packages.${ghc}.liquidhaskell_with_tests;
        };

        defaultPackage = pkgs.haskell.packages.${ghc}.liquidhaskell_with_tests;

        devShell = self.defaultPackage.${system}.env;

        overlay = composeOverlays [
          # Liquid-Fixpoint Overlays
          self.overlays.${system}.patchHaskellGit
          self.overlays.${system}.addLiquidFixpoint
          self.overlays.${system}.fixSmtlibBackendsProcess

          # LiquidHaskell Overlays
          self.overlays.${system}.addLiquidHaskellWithoutTests
          self.overlays.${system}.addLiquidHaskellBoot
          self.overlays.${system}.addLiquidHaskellPackages
          self.overlays.${system}.addLiquidHaskellWithTests
        ];

        overlays = {

          ################# Liquid-Fixpoint #################
          
          patchHaskellGit = final: prev: haskellPackagesOverlay ghc final prev (selfH: superH: {
              # git has a MFP bug and hasn't been fixed yet as of 2023-12-03
              git = final.haskell.lib.overrideCabal (selfH.callHackage "git" "0.3.0" { }) (old: {
                broken = false;
                # git-0.3.0 defines a Monad a fail function, which is incompatible with ghc-8.10.1 
                # https://hackage.haskell.org/package/git-0.3.0/docs/src/Data.Git.Monad.html#line-240
                patches = [
                  (final.writeText "git-0.3.0_fix-monad-fail-for-ghc-8.10.x.patch" ''
                    diff --git a/Data/Git/Monad.hs b/Data/Git/Monad.hs
                    index 480af9f..27c3b3e 100644
                    --- a/Data/Git/Monad.hs
                    +++ b/Data/Git/Monad.hs
                    @@ -130 +130 @@ instance Resolvable Git.RefName where
                    -class (Functor m, Applicative m, Monad m) => GitMonad m where
                    +class (Functor m, Applicative m, Monad m, MonadFail m) => GitMonad m where
                    @@ -242,0 +243 @@ instance Monad GitM where
                    +instance MonadFail GitM where
                    @@ -315,0 +317 @@ instance Monad CommitAccessM where
                    +instance MonadFail CommitAccessM where
                    @@ -476,0 +479 @@ instance Monad CommitM where
                    +instance MonadFail CommitM where
                  '')
                ];
              });
            });
          
          addLiquidFixpoint = final: prev: haskellPackagesOverlay ghc final prev (selfH: superH:
            let callCabal2nix = final.haskell.packages.${ghc}.callCabal2nix; in
            with final.haskell.lib; {
              liquid-fixpoint = overrideCabal (callCabal2nix "liquid-fixpoint" liquid-fixpoint-src { }) (old: {
                buildTools = [ final.z3 ];
                # bring the `fixpoint` binary into scope for tests run by nix-build
                preCheck = ''export PATH="$PWD/dist/build/fixpoint:$PATH"'';
              });
            });
 
          fixSmtlibBackendsProcess = final: prev: haskellPackagesOverlay ghc final prev (selfH: superH:
            with final.haskell.lib; {
              smtlib-backends-process = overrideCabal superH.smtlib-backends-process (old: {
                # smtlib-backends-process needs z3 to run its tests
                testHaskellDepends = old.testHaskellDepends ++ [ final.z3 ];
                broken = false;
              });
            }
          );

          ################## LiquidHaskell ##################
          
          addLiquidHaskellWithoutTests = final: prev: haskellPackagesOverlay ghc final prev (selfH: superH:
              let callCabal2nix = final.haskell.packages.${ghc}.callCabal2nix; in
              with final.haskell.lib; {
                liquidhaskell =
                  let src = final.nix-gitignore.gitignoreSource [ ".swp" "*.nix" "result" "liquid-*" ] liquidhaskell-src;
                  in
                  dontHaddock # src/Language/Haskell/Liquid/Types/RefType.hs:651:3: error: parse error on input ‘-- | _meetable t1 t2’
                    (doJailbreak # LH requires slightly old versions of recursion-schemes and optparse-applicative
                      (dontCheck (beComponent final (callCabal2nix "liquidhaskell" src { }))));
              });
          
          addLiquidHaskellBoot = final: prev: haskellPackagesOverlay ghc final prev (selfH: superH:
            let callCabal2nix = final.haskell.packages.${ghc}.callCabal2nix; in
            with final.haskell.lib; {
              liquidhaskell-boot = dontHaddock (beComponent final (callCabal2nix "liquidhaskell-boot" "${liquidhaskell-src}/liquidhaskell-boot" { }));
            }
          );

          addLiquidHaskellPackages = final: prev: haskellPackagesOverlay ghc final prev (selfH: superH:
            let callCabal2nix = final.haskell.packages.${ghc}.callCabal2nix; in {
              liquid-parallel = (beComponent final (callCabal2nix "liquid-parallel" "${liquidhaskell-src}/liquid-parallel" { }));
              liquid-platform = (beComponent final (callCabal2nix "liquid-platform" "${liquidhaskell-src}/liquid-platform" { }));
              liquid-prelude = (beComponent final (callCabal2nix "liquid-prelude" "${liquidhaskell-src}/liquid-prelude" { }));
              liquid-vector = (beComponent final (callCabal2nix "liquid-vector" "${liquidhaskell-src}/liquid-vector" { }));
            });

          addLiquidHaskellWithTests = final: prev: haskellPackagesOverlay ghc final prev (selfH: superH:
            with final.haskell.lib; {
              liquidhaskell_with_tests = overrideCabal selfH.liquidhaskell (old: {
                doCheck = true; # change the value set above
                testDepends = old.testDepends or [ ] ++ [ final.hostname ];
                testHaskellDepends = (old.testHaskellDepends or []) ++ builtins.attrValues (builtins.removeAttrs self.packages.${system} [ "liquidhaskell_with_tests" ]);
                preCheck = ''export TASTY_LIQUID_RUNNER="liquidhaskell -v0"'';
              });
            });
        };

      };
    in
    flake-utils.lib.eachDefaultSystem mkOutputs;
}
