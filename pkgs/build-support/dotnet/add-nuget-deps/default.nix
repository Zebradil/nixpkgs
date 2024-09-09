{
  writeShellScript,
  runtimeShell,
  nix,
  lib,
  substituteAll,
  nuget-to-nix,
  cacert,
  fetchNupkg,
  callPackage,
}:

{
  nugetDeps,
  overrideFetchAttrs ? x: { },
}:
fnOrAttrs: finalAttrs:
let
  attrs = if builtins.isFunction fnOrAttrs then fnOrAttrs finalAttrs else fnOrAttrs;

  deps =
    if (nugetDeps != null) then
      if lib.isDerivation nugetDeps then
        [ nugetDeps ]
      else if lib.isList nugetDeps then
        nugetDeps
      else
        assert (lib.isPath nugetDeps);
        callPackage nugetDeps { fetchNuGet = fetchNupkg; }
    else
      [ ];

  finalPackage = finalAttrs.finalPackage;

in
attrs
// {
  buildInputs = attrs.buildInputs or [ ] ++ deps;

  passthru =
    attrs.passthru or { }
    // {
      nugetDeps = deps;
    }
    // lib.optionalAttrs (nugetDeps == null || lib.isPath nugetDeps) rec {
      fetch-drv =
        let
          pkg' = finalPackage.overrideAttrs (old: {
            buildInputs = attrs.buildInputs or [ ];
            nativeBuildInputs = old.nativeBuildInputs or [ ] ++ [ cacert ];
            keepNugetConfig = true;
            dontBuild = true;
            doCheck = false;
            dontInstall = true;
            doInstallCheck = false;
            dontFixup = true;
            doDist = false;
          });
        in
        pkg'.overrideAttrs overrideFetchAttrs;
      fetch-deps =
        let
          drv = builtins.unsafeDiscardOutputDependency fetch-drv.drvPath;

          innerScript = substituteAll {
            src = ./fetch-deps.sh;
            isExecutable = true;
            inherit cacert;
            defaultDepsFile =
              # Wire in the depsFile such that running the script with no args
              # runs it agains the correct deps file by default.
              # Note that toString is necessary here as it results in the path at
              # eval time (i.e. to the file in your local Nixpkgs checkout) rather
              # than the Nix store path of the path after it's been imported.
              if lib.isPath nugetDeps && !lib.isStorePath nugetDeps then
                toString nugetDeps
              else
                ''$(mktemp -t "${finalAttrs.pname or finalPackage.name}-deps-XXXXXX.nix")'';
            nugetToNix = nuget-to-nix;
          };

        in
        writeShellScript "${finalPackage.name}-fetch-deps" ''
          set -eu
          export TMPDIR
          TMPDIR=$(mktemp -d -t fetch-deps-${finalPackage.name}.XXXXXX)
          trap 'chmod -R +w "$TMPDIR" && rm -fr "$TMPDIR"' EXIT
          cd "$TMPDIR"
          NIX_BUILD_SHELL="${runtimeShell}" {nix}/bin/nix-shell \
            --pure --run 'source "${innerScript}"' "${drv}"
        '';
    };
}
