#!/usr/bin/env bash
#
# Copyright (c) 2026 Marin Atanasov Nikolov <dnaeon@gmail.com>
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#
#  1. Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer
#     in this position and unchanged.
#  2. Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR(S) ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE AUTHOR(S) BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
# NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# Snapshot the shell completion scripts into committed files.
#
# The `elpacman completions' sub-command is the source of truth; this
# script simply captures its output into `completions/' so that the
# scripts can be shipped and packaged.  Run it with `make completions'
# whenever the set of sub-commands or options changes.

set -euo pipefail

_SCRIPT_DIR="$( dirname "$( readlink -f -- "${BASH_SOURCE[0]}" )" )"
_PROJECT_DIR="$( dirname -- "${_SCRIPT_DIR}" )"
_OUT_DIR="${_PROJECT_DIR}/completions"
_ELPACMAN="${_PROJECT_DIR}/elpacman"

mkdir -p "${_OUT_DIR}"

# Run against a clean Emacs; the completion output does not depend on
# the user's configuration.
ELPACMAN_NO_INIT="1" "${_ELPACMAN}" completions bash > "${_OUT_DIR}/elpacman.bash"
ELPACMAN_NO_INIT="1" "${_ELPACMAN}" completions zsh  > "${_OUT_DIR}/_elpacman"

printf 'Wrote %s\n' "${_OUT_DIR}/elpacman.bash"
printf 'Wrote %s\n' "${_OUT_DIR}/_elpacman"
