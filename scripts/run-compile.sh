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

# Byte-compile `elpacman.el' with warnings promoted to errors, so that
# any compilation warning fails the build.  The Emacs binary may be
# overridden via the `EMACS' environment variable.

set -euo pipefail

_SCRIPT_DIR="$( dirname "$( readlink -f -- "${BASH_SOURCE[0]}" )" )"
_PROJECT_DIR="$( dirname -- "${_SCRIPT_DIR}" )"
EMACS="${EMACS:-emacs}"

exec "${EMACS}" -Q --batch \
    -L "${_PROJECT_DIR}" \
    --eval "(setq byte-compile-error-on-warn t)" \
    -f batch-byte-compile \
    "${_PROJECT_DIR}/elpacman.el"
