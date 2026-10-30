# shellcheck shell=bash disable=SC2034
# local.sh: this repo's own pipeline settings. Loaded at the end of routing.sh, so anything here wins
# over the kit's defaults. setup.sh --update never touches this file. Commit it with the repo.
# API keys go in .agents/secrets.sh (git ignores it), never here.
