############################################################################
# Docker image builder
#
# To build and load into the Docker engine:
#
#   docker load -i $(nix-build -A dockerImage.dbSync --no-out-link)
#   docker load -i $(nix-build -A dockerImage.dbSyncExtended --no-out-link)
#
#  cardano-db-sync and cardano-db-sync-extended are interchangeable in the following:
#
#  To launch with provided mainnet or testnet configuration
#
#    docker run \
#      -v $PATH_TO/node.socket:/data/node.socket \
#      -v $PATH_TO/pgpass:/config/pgpass \
#      -e NETWORK=mainnet|testnet \
#      inputoutput/cardano-db-sync:<TAG>
#
#  To launch with custom config, mount a dir containing config.yaml, genesis.json,
#  topology.json, and pgpass into /config
#
#    docker run \
#      -v $PATH_TO/node.socket:/data/node.socket \
#      -v $PATH_TO/config:/config \
#      inputoutput/cardano-db-sync:<TAG>
#
############################################################################

{ iohkNix
, commonLib
, dockerTools

# The main contents of the image.
, cardano-db-sync
, cardano-db-sync-extended
, scripts

# Get the current commit
, gitrev ? iohkNix.commitIdFromGitRepoOrZero ../.git

# Other things to include in the image.
, bashInteractive
, cacert
, coreutils
, curl
, glibcLocales
, iana-etc
, iproute
, iputils
, socat
, utillinux
, writeScriptBin
, runtimeShell
, lib

, dbSyncRepoName ? "inputoutput/cardano-db-sync"
, dbSyncExtendedRepoName ? "inputoutput/cardano-db-sync-extended"
}:

let

  # Layer of tools which aren't going to change much between versions.
  baseImage = dockerTools.buildImage {
    name = "base-env";
    contents = [
      bashInteractive   # Provide the BASH shell
      cacert            # X.509 certificates of public CA's
      coreutils         # Basic utilities expected in GNU OS's
      curl              # CLI tool for transferring files via URLs
      glibcLocales      # Locale information for the GNU C Library
      iana-etc          # IANA protocol and port number assignments
      iproute           # Utilities for controlling TCP/IP networking
      iputils           # Useful utilities for Linux networking
      socat             # Utility for bidirectional data transfer
      utillinux         # System utilities for Linux
    ];
    # set up /tmp (override with TMPDIR variable)
    extraCommands = ''
      mkdir -m 0777 tmp
    '';
  };
  dbSyncDockerImage = let
    entry-point = writeScriptBin "entry-point" ''
      #!${runtimeShell}
      #echo $NETWORK
      if [[ -d /config ]]; then
        echo PGPASSFILE = "/config/pgpass";
        exec ${cardano-db-sync}/bin/cardano-db-sync
      else
        echo "Please mount the pgpass file with credentials for postgres in /config"
      fi
    '';
  in dockerTools.buildImage {
    name = "${dbSyncRepoName}";
    fromImage = baseImage;
    tag = "${gitrev}";
    created = "now";   # Set creation date to build time. Breaks reproducibility
    contents = [ entry-point ];
    config = {
      EntryPoint = [ "${entry-point}/bin/entry-point" ];
      ExposedPorts = {
        "8100/tcp" = {};
      };
    };
  };
  dbSyncExtendedDockerImage = let
    clusterStatements = lib.concatStringsSep "\n" (lib.mapAttrsToList (_: value: value) (commonLib.forEnvironments (env: ''
      elif [[ "$NETWORK" == "${env.name}" ]]; then
        exec ${scripts.${env.name}.tx-submit}
    '')));
    entry-point = writeScriptBin "entry-point" ''
      #!${runtimeShell}
      if [[ -d /config ]]; then
         exec ${cardano-tx-submit-webapi}/bin/cardano-tx-submit-webapi \
           --socket-path /data/node.socket \
           --genesis-file /config/genesis.json \
           --port 8101 \
           --config /data/config.yaml
      ${clusterStatements}
      else
        echo "Please set a NETWORK environment variable to one of: mainnet/testnet"
        echo "Or mount a /config volume containing: config.yaml and genesis.json"
      fi
    '';
  in dockerTools.buildImage {
    name = "${dbSyncExtendedRepoName}";
    fromImage = baseImage;
    tag = "${gitrev}";
    created = "now";   # Set creation date to build time. Breaks reproducibility
    contents = [ entry-point ];
    config = {
      EntryPoint = [ "${entry-point}/bin/entry-point" ];
      ExposedPorts = {
        "8101/tcp" = {};
      };
    };
  };

in {
  dbSync = dbSyncDockerImage;
  dbSyncExtended = dbSyncExtendedDockerImage;
}
