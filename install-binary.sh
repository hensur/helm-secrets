#!/usr/bin/env bash

set -ueo pipefail

if hash sops 2>/dev/null; then
    echo "sops is already installed:"
    sops --version
else
    echo "Please install sops: https://github.com/mozilla/sops or make it available in the PATH"
fi

### git diff config
if [ -x "$(command -v git --version)" ];
then
    git config --global diff.sopsdiffer.textconv "sops -d"
else
    echo -e "${RED}[FAIL]${NOC} Install git command"
    exit 1
fi
