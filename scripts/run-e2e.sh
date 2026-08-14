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

# End-to-end smoke test for `elpacman'.
#
# This exercises every sub-command against a throw-away Emacs
# configuration created under a temporary directory, so that the real
# `~/.emacs.d' is never touched.  It requires network access, since it
# installs and upgrades real packages.
#
# The temporary configuration has its own `custom-file' carrying a
# `package-selected-packages' list, so that the customization-saving
# path taken by `install' and `delete' is exercised for real.

set -euo pipefail

_SCRIPT_DIR="$( dirname "$( readlink -f -- "${BASH_SOURCE[0]}" )" )"
_PROJECT_DIR="$( dirname -- "${_SCRIPT_DIR}" )"
_CORE="${_PROJECT_DIR}/elpacman.el"
EMACS="${EMACS:-emacs}"

# A small, dependency-light package to install and remove.
_PACKAGE="sml-mode"

# Create the throw-away configuration and arrange for it to be removed
# on exit, however the script terminates.
_HOME="$( mktemp -d "${TMPDIR:-/tmp}/elpacman-e2e.XXXXXX" )"
cleanup() { rm -rf "${_HOME}"; }
trap cleanup EXIT

mkdir -p "${_HOME}/.emacs.d"

cat > "${_HOME}/.emacs.d/init.el" <<'EOF'
;; A minimal but realistic init file for the end-to-end test.
(require 'package)
(setq package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                         ("nongnu" . "https://elpa.nongnu.org/nongnu/")
                         ("melpa" . "https://melpa.org/packages/")))
(setq custom-file (expand-file-name "custom.el" user-emacs-directory))
(when (file-exists-p custom-file)
  (load custom-file))
(package-initialize)
EOF

cat > "${_HOME}/.emacs.d/custom.el" <<'EOF'
(custom-set-variables
 '(package-selected-packages '(sml-mode)))
EOF

# Run the core exactly as the wrapper does, but against the temporary
# configuration.  We load the temporary init file explicitly and set
# HOME so that every path the configuration references stays inside the
# sandbox.  Confirmation prompts are assumed "yes".
elp() {
    HOME="${_HOME}" \
    ELPACMAN_ASSUME_YES="1" \
    ELPACMAN_TTY="" \
        "${EMACS}" --batch \
        -l "${_HOME}/.emacs.d/init.el" \
        --script "${_CORE}" -- "$@"
}

# `run STEP ARGS...' announces and runs a sub-command, aborting the
# whole script if it exits non-zero.
run() {
    local step="$1"
    shift
    printf '\n### %s: elpacman %s\n' "${step}" "$*"
    elp "$@"
}

run "version"    version
run "help"       help
run "update"     update
run "search"     search "${_PACKAGE}"
run "install"    install "${_PACKAGE}"
run "list"       list
run "info"       info "${_PACKAGE}"
run "outdated"   outdated
run "check"      check
run "recompile"  recompile
run "delete"     delete "${_PACKAGE}"

# The customization file must survive the install/delete cycle as valid,
# balanced Emacs Lisp.  This is the regression guard for the bug where
# the progress capture hijacked the `princ' calls that write it.
printf '\n### verify: custom-file is still valid Emacs Lisp\n'
"${EMACS}" -Q --batch --eval "(condition-case nil
    (with-temp-buffer
      (insert-file-contents \"${_HOME}/.emacs.d/custom.el\")
      (goto-char (point-min))
      (while (progn (skip-chars-forward \" \t\n\") (not (eobp)))
        (forward-sexp))
      (message \"custom-file OK\"))
  (error (message \"custom-file CORRUPT\") (kill-emacs 1)))"

printf '\nAll end-to-end steps passed.\n'
