#!/bin/bash

# ----------------------
# KUDU Deployment Script
# Version: 0.1.11
# ----------------------

# Helpers
# -------

exitWithMessageOnError () {
  if [ ! $? -eq 0 ]; then
    echo "An error has occurred during web site deployment."
    echo $1
    exit 1
  fi
}

# Prerequisites
# -------------

# Verify node.js installed
hash node 2>/dev/null
exitWithMessageOnError "Missing node.js executable, please install node.js, if already installed make sure it can be reached from current environment."

# Setup
# -----

SCRIPT_DIR="${BASH_SOURCE[0]%\\*}"
SCRIPT_DIR="${SCRIPT_DIR%/*}"
ARTIFACTS=$SCRIPT_DIR/../artifacts
KUDU_SYNC_CMD=${KUDU_SYNC_CMD//\"}

if [[ ! -n "$DEPLOYMENT_SOURCE" ]]; then
  DEPLOYMENT_SOURCE=$SCRIPT_DIR
fi

if [[ ! -n "$NEXT_MANIFEST_PATH" ]]; then
  NEXT_MANIFEST_PATH=$ARTIFACTS/manifest

  if [[ ! -n "$PREVIOUS_MANIFEST_PATH" ]]; then
    PREVIOUS_MANIFEST_PATH=$NEXT_MANIFEST_PATH
  fi
fi

if [[ ! -n "$DEPLOYMENT_TARGET" ]]; then
  DEPLOYMENT_TARGET=$ARTIFACTS/wwwroot
else
  KUDU_SERVICE=true
fi

if [[ ! -n "$KUDU_SYNC_CMD" ]]; then
  # Install kudu sync
  echo Installing Kudu Sync
  npm install kudusync -g --silent
  exitWithMessageOnError "npm failed"

  if [[ ! -n "$KUDU_SERVICE" ]]; then
    # In case we are running locally this is the correct location of kuduSync
    KUDU_SYNC_CMD=kuduSync
  else
    # In case we are running on kudu service this is the correct location of kuduSync
    KUDU_SYNC_CMD=$APPDATA/npm/node_modules/kuduSync/bin/kuduSync
  fi
fi

############################################################################
# Build
############################################################################

# Install go if needed
export GOROOT=$HOME/go
export PATH=$PATH:$GOROOT/bin
export GOPATH=$DEPLOYMENT_SOURCE
if [ ! -e "$GOROOT" ]; then
  GO_ARCHIVE=$HOME/tmp/go.zip
  mkdir -p ${GO_ARCHIVE%/*}
  curl https://storage.googleapis.com/golang/go1.4.1.windows-amd64.zip -o $GO_ARCHIVE
  unzip $GO_ARCHIVE -d $HOME
fi

# Create and store unique artifact name
DEPLOYMENT_ID=${SCM_COMMIT_ID:0:10}
ARTIFACT_NAME=$WEBSITE_SITE_NAME-$DEPLOYMENT_ID.exe
TARGET_ARTIFACT=$DEPLOYMENT_SOURCE/_target/$ARTIFACT_NAME
echo $TARGET_ARTIFACT > _artifact.txt

echo Building go artifact $TARGET_ARTIFACT from commit $DEPLOYMENT_ID
go build -v -o $TARGET_ARTIFACT

##################################################################################################################################
# Deployment
# ----------

echo Handling Basic Web Site deployment.

if [[ "$IN_PLACE_DEPLOYMENT" -ne "1" ]]; then
  "$KUDU_SYNC_CMD" -v 50 -f "$DEPLOYMENT_SOURCE" -t "$DEPLOYMENT_TARGET" -n "$NEXT_MANIFEST_PATH" -p "$PREVIOUS_MANIFEST_PATH" -i ".git;.hg;.deployment;deploy.sh;.gitignore"
  exitWithMessageOnError "Kudu Sync failed"
fi

echo Removing old artifacts
find ${TARGET_ARTIFACT%/*} $DEPLOYMENT_TARGET/_target -type f -name ${ARTIFACT_NAME%-*}-*.exe -maxdepth 1 -print0 |
grep -zv $ARTIFACT_NAME |
xargs -0 rm -v

##################################################################################################################################

# Post deployment stub
if [[ -n "$POST_DEPLOYMENT_ACTION" ]]; then
  POST_DEPLOYMENT_ACTION=${POST_DEPLOYMENT_ACTION//\"}
  cd "${POST_DEPLOYMENT_ACTION_DIR%\\*}"
  "$POST_DEPLOYMENT_ACTION"
  exitWithMessageOnError "post deployment action failed"
fi

echo "Finished successfully."

