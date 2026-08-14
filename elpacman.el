;;; elpacman.el --- A command-line package manager for Emacs -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Marin Atanasov Nikolov <dnaeon@gmail.com>
;; All rights reserved.
;;
;; Author: Marin Atanasov Nikolov <dnaeon@gmail.com>
;; Maintainer: Marin Atanasov Nikolov <dnaeon@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, tools
;; URL: https://github.com/dnaeon/elpacman
;;
;; Redistribution and use in source and binary forms, with or without
;; modification, are permitted provided that the following conditions
;; are met:
;;
;;  1. Redistributions of source code must retain the above copyright
;;     notice, this list of conditions and the following disclaimer
;;     in this position and unchanged.
;;  2. Redistributions in binary form must reproduce the above copyright
;;     notice, this list of conditions and the following disclaimer in the
;;     documentation and/or other materials provided with the distribution.
;;
;; THIS SOFTWARE IS PROVIDED BY THE AUTHOR(S) ``AS IS'' AND ANY EXPRESS OR
;; IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
;; OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
;; IN NO EVENT SHALL THE AUTHOR(S) BE LIABLE FOR ANY DIRECT, INDIRECT,
;; INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
;; NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
;; DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
;; THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
;; (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
;; THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

;;; Commentary:

;; `elpacman' is a command-line package manager for Emacs, modelled
;; after system package managers such as `apt' and `pacman'.  It
;; provides sub-commands for managing the packages installed in a
;; user's Emacs configuration, without having to launch an interactive
;; Emacs session.
;;
;; The following sub-commands are provided.
;;
;;   update      -- Refresh the local package database from the archives
;;   upgrade     -- Upgrade all packages, or the named ones
;;   install     -- Install one or more packages
;;   delete      -- Delete one or more packages
;;   search      -- Search the archives for packages
;;   info        -- Show detailed information about a package
;;   list        -- List installed packages
;;   outdated    -- List packages for which an upgrade is available
;;   check       -- Check for broken packages
;;   recompile   -- Recompile the byte-code of installed packages
;;   autoremove  -- Remove packages that are no longer needed
;;   completions -- Print a shell completion script for bash or zsh
;;   version     -- Show the `elpacman' version
;;   help        -- Show usage information
;;
;; Both archive-based packages (from ELPA, MELPA, etc.) and
;; version-controlled packages (installed via `package-vc') are
;; understood by every sub-command, so that no installed package is
;; ever silently skipped.
;;
;; The commands that change installed packages (install, upgrade,
;; delete and autoremove) first print the list of packages that will
;; change and then ask for confirmation, in the manner of `apt' and
;; `pacman'.  The prompt is skipped when the `-y', `--yes' or
;; `--assume-yes' option is given.  When there is no controlling
;; terminal and no such option was given, the operation is aborted
;; rather than proceeding without consent.
;;
;; Why use `elpacman' instead of the interactive package menu?  Because
;; it makes package management scriptable: it fits naturally into CI/CD
;; pipelines, dotfiles bootstrap scripts, cron-driven upgrade jobs and
;; one-shot installs from the shell, none of which want an interactive
;; Emacs session.
;;
;; This file is meant to be executed by the accompanying `elpacman'
;; shell wrapper, which invokes it in batch mode with a sub-command and
;; its arguments, e.g.
;;
;;   elpacman <sub-command> [args...]
;;
;; but it can also be loaded interactively for development and testing.

;;; Code:

(require 'cl-lib)
(require 'package)
(require 'package-vc)
(require 'subr-x)

;;;; Version and constants

(defconst elpacman-version "0.1.0"
  "The current version of `elpacman'.")

(defconst elpacman--global-options
  '(("-y" . "Do not prompt for confirmation")
    ("--yes" . "Do not prompt for confirmation")
    ("--assume-yes" . "Do not prompt for confirmation"))
  "Association list of options accepted by every command that changes packages.
Each element is a cons of the option string and its description.")

(defconst elpacman--command-info
  '(("update"     nil        "Refresh the local package database from the archives")
    ("upgrade"    :confirm   "Upgrade all packages, or only the named ones")
    ("install"    :confirm   "Install one or more packages" ("--vc" . "Install from a version-control URL"))
    ("delete"     :confirm   "Delete one or more installed packages")
    ("remove"     :confirm   "Alias for `delete'")
    ("search"     nil        "Search the archives for packages")
    ("info"       nil        "Show detailed information about a package")
    ("list"       nil        "List installed packages")
    ("outdated"   nil        "List packages for which an upgrade is available")
    ("check"      nil        "Check for broken packages")
    ("recompile"  :confirm   "Recompile the byte-code of installed packages")
    ("autoremove" :confirm   "Remove unused dependency packages")
    ("completions" nil       "Print a shell completion script")
    ("version"    nil        "Show the elpacman version")
    ("help"       nil        "Show usage information"))
  "Metadata describing the user-facing sub-commands, for help and completion.
Each element has the form (NAME CONFIRM DESCRIPTION OPTION...), where NAME
is the sub-command name, CONFIRM is non-nil when the command accepts the
global confirm-skip options, DESCRIPTION is a one-line summary and each
optional OPTION is a cons of a command-specific option string and its
description.  The option aliases such as `--version' are intentionally
omitted here, as they should not be offered as completions.")

(defconst elpacman--clear-seq "\033[K"
  "ANSI escape sequence to clear from the cursor to the end of the line.")

(defvar elpacman--term-width 0
  "Cached terminal width in columns, or 0 when unknown.")

(defvar elpacman--assume-yes nil
  "When non-nil, assume an affirmative answer to all confirmation prompts.
This is set by the `-y', `--yes' or `--assume-yes' command-line options,
or by a non-empty `ELPACMAN_ASSUME_YES' environment variable.")

;; Capture the original `princ' at load time, before the progress macro
;; shadows it at runtime, so that our own output routines can still
;; reach the terminal even while `princ' is overridden to capture the
;; output of `package.el'.
(defconst elpacman--princ (symbol-function 'princ)
  "The original `princ' function, captured before it is shadowed.")

;;;; Output helpers

(defun elpacman--term-width ()
  "Return the terminal width from the COLUMNS environment variable.
Return nil when COLUMNS is unset or does not hold a positive integer."
  (let ((columns (getenv "COLUMNS")))
    (when (and columns (string-match-p "\\`[0-9]+\\'" columns))
      (let ((n (string-to-number columns)))
        (and (> n 0) n)))))

(defun elpacman--out (fmt &rest args)
  "Print FMT formatted with ARGS to the standard output and flush it."
  (funcall elpacman--princ (apply #'format fmt args))
  (flush-standard-output))

(defun elpacman--err (fmt &rest args)
  "Print FMT formatted with ARGS to the standard error."
  (funcall elpacman--princ (apply #'format fmt args) #'external-debugging-output))

(defun elpacman--trim (str)
  "Truncate STR so that it fits within the cached terminal width.
When the terminal width is unknown STR is returned unchanged."
  (if (or (zerop elpacman--term-width)
          (<= (string-width str) elpacman--term-width))
      str
    (truncate-string-to-width str elpacman--term-width)))

(defmacro elpacman--with-progress (prefix &rest body)
  "Evaluate BODY while rendering captured messages on a single line.

Any message emitted through `message' or `princ' while BODY runs is
prefixed with PREFIX and drawn on the current line, overwriting the
previous message.  The line is cleared once BODY returns.

When BODY signals an error the captured messages are dumped verbatim,
one per line, as they usually point at the cause of the failure."
  (declare (indent 1))
  `(let ((elpacman--progress-prefix ,prefix)
         (elpacman--progress-log nil))
     (cl-letf (((symbol-function 'message)
                (lambda (&rest args)
                  (let ((msg (if (car args) (apply #'format-message args) "")))
                    (push msg elpacman--progress-log)
                    (elpacman--progress-draw elpacman--progress-prefix msg)
                    msg)))
               ((symbol-function 'princ)
                (lambda (obj &optional stream)
                  ;; Only capture output that is genuinely headed for the
                  ;; standard output.  When `princ' is asked to write
                  ;; somewhere specific -- an explicit STREAM, or a
                  ;; non-default `standard-output' such as the buffer that
                  ;; `custom-save-variables' builds -- defer to the
                  ;; original `princ' so the write lands where intended.
                  (if (or stream (not (eq standard-output t)))
                      (funcall elpacman--princ obj stream)
                    (let ((msg (if (stringp obj) obj (prin1-to-string obj))))
                      (push msg elpacman--progress-log)
                      (elpacman--progress-draw elpacman--progress-prefix msg)
                      obj)))))
       (unwind-protect
           (prog1 (progn ,@body)
             ;; Success.  Drop the log so nothing is dumped below.
             (setq elpacman--progress-log nil))
         ;; Always clear the progress line.
         (funcall elpacman--princ
                  (format "%s\r" elpacman--clear-seq))
         (flush-standard-output)
         ;; On failure, dump everything that was captured.
         (when elpacman--progress-log
           (dolist (msg (nreverse elpacman--progress-log))
             (unless (string-empty-p msg)
               (elpacman--err "%s%s\n" elpacman--progress-prefix msg))))))))

(defun elpacman--progress-draw (prefix msg)
  "Draw MSG on the current line, prefixed with PREFIX and trimmed.
MSG may contain newlines, in which case each non-empty line is drawn in
turn.  This is a helper for `elpacman--with-progress'."
  (dolist (line (save-match-data (split-string msg "\n")))
    (unless (string-empty-p line)
      (let ((text (elpacman--trim (concat prefix line))))
        (funcall elpacman--princ
                 (format "%s%s\r" elpacman--clear-seq text))
        (flush-standard-output)))))

;;;; Package system helpers

(defun elpacman--init ()
  "Initialize the package system and load the archive contents.
This must run before any sub-command that inspects or mutates the set
of installed or available packages."
  (setq elpacman--term-width (or (elpacman--term-width) 0))
  (package-initialize)
  (package-read-all-archive-contents))

(defun elpacman--intern-names (names)
  "Return NAMES, a list of strings, as a list of interned symbols."
  (mapcar #'intern names))

(defun elpacman--installed-descs ()
  "Return the `package-desc' objects for all installed packages.
The result is sorted alphabetically by package name."
  (sort (mapcar #'cadr package-alist)
        (lambda (a b)
          (string< (symbol-name (package-desc-name a))
                   (symbol-name (package-desc-name b))))))

(defun elpacman--available-desc (name)
  "Return the newest available `package-desc' for NAME, or nil.
NAME is a symbol.  The description is looked up in the archive
contents, i.e. the local package database."
  (cadr (assq name package-archive-contents)))

(defun elpacman--installed-desc (name)
  "Return the installed `package-desc' for NAME, or nil.
NAME is a symbol."
  (cadr (assq name package-alist)))

(defun elpacman--vc-p (desc)
  "Return non-nil when the package described by DESC is VC-installed."
  (and desc (package-vc-p desc)))

(defun elpacman--version-string (desc)
  "Return the version of the package described by DESC as a string.
VC-installed packages report the string \"vc\", as they are not
versioned through the archives."
  (cond
   ((null desc) "-")
   ((elpacman--vc-p desc) "vc")
   (t (package-version-join (package-desc-version desc)))))

(defun elpacman--upgradeable-names ()
  "Return the names of all packages that can be upgraded, as symbols.
Both archive-based and VC-installed packages are considered, mirroring
the behaviour of the interactive `package-upgrade-all' command."
  (package--upgradeable-packages))

;;;; Confirmation, preview and size helpers

(define-error 'elpacman-aborted "Operation aborted")

(defun elpacman--interactive-p ()
  "Return non-nil when it is safe to prompt the user for confirmation.
Emacs batch mode cannot determine this on its own, so the `elpacman'
wrapper detects it and exports the `ELPACMAN_TTY' environment variable."
  (let ((tty (getenv "ELPACMAN_TTY")))
    (and tty (not (string-empty-p tty)))))

(defun elpacman--confirm (prompt)
  "Ask the user PROMPT and return non-nil when they agree.
Return non-nil immediately when `elpacman--assume-yes' is set.  When
running interactively, read a line from the terminal and, in the manner
of `pacman', treat everything as agreement except an explicit `n' or
`no'; a bare newline therefore proceeds.  When not interactive and no
affirmative was assumed, signal `elpacman-aborted', since proceeding
without consent is unsafe.  The prompt is styled after `pacman', with a
leading blank line, a `:: ' prefix and a `[Y/n]' default."
  (cond
   (elpacman--assume-yes t)
   ((elpacman--interactive-p)
    (let ((answer (downcase (string-trim
                             (read-string (format "\n:: %s [Y/n] " prompt))))))
      (not (member answer '("n" "no")))))
   (t
    (signal 'elpacman-aborted
            (list "not running interactively; pass --yes to proceed")))))

(defun elpacman--preview (descs &optional size-label size-bytes)
  "Print the packages in DESCS as a `pacman'-style transaction preview.
DESCS is a list of `package-desc' objects.  They are printed as a
`Packages (N)' header followed by `name-version' tokens.  When
SIZE-LABEL is given and SIZE-BYTES is a positive number, a total-size
line such as `Total Installed Size:' is printed.  The size line is
skipped when the size is unknown, so no misleading zero is shown (for
example, the on-disk size of a not-yet-installed package is unknown)."
  (let ((tokens (mapcar (lambda (desc)
                          (format "%s-%s"
                                  (package-desc-name desc)
                                  (elpacman--version-string desc)))
                        descs)))
    (elpacman--out "\nPackages (%d) %s\n"
                   (length descs) (string-join tokens "  ")))
  (when (and size-label size-bytes (> size-bytes 0))
    (elpacman--out "\n%s %s\n"
                   size-label (elpacman--human-size size-bytes))))

(defun elpacman--dir-size (dir)
  "Return the total size in bytes of all files under DIR.
Return 0 when DIR is nil or does not exist."
  (if (and dir (file-directory-p dir))
      (let ((total 0))
        (dolist (file (directory-files-recursively dir "" nil))
          (setq total (+ total (or (file-attribute-size (file-attributes file)) 0))))
        total)
    0))

(defun elpacman--human-size (bytes)
  "Return BYTES formatted as a human-readable size string."
  (file-size-human-readable bytes))


;;;; Sub-command: update

(defun elpacman-cmd-update (_args)
  "Refresh the local package database from the configured archives.
ARGS are ignored.  This is the equivalent of `pacman -Sy'.  Return 0 on
success; a failure to reach an archive is signalled and reported by the
caller as a non-zero exit status."
  (elpacman--out ":: Synchronizing package databases...\n")
  (elpacman--with-progress "update: "
    (package-refresh-contents))
  0)

;;;; Sub-command: upgrade

(defun elpacman-cmd-upgrade (args)
  "Upgrade installed packages.
When ARGS is empty every upgradeable package is upgraded.  Otherwise
only the named packages in ARGS are upgraded.  Archive-based and
VC-installed packages are both handled.

The local package database is not refreshed first; run `update' to
synchronize it, in the manner of `pacman -Sy' before `pacman -Su'.

Return 0 when every upgrade succeeded or the user declined, 1 when a
named package is not installed or an upgrade failed."
  (if args
      (elpacman--upgrade-named (elpacman--intern-names args))
    (elpacman--upgrade-all)))

(defun elpacman--upgrade-token (name)
  "Return a `pacman'-style token describing the upgrade of NAME.
For an archive package the token shows the version transition, as in
`magit-1->2'.  For a version-controlled package, whose new version is
not known from the archives, it shows just `NAME-vc'."
  (let ((installed (elpacman--installed-desc name)))
    (if (elpacman--vc-p installed)
        (format "%s-vc" name)
      (format "%s-%s->%s"
              name
              (elpacman--version-string installed)
              (elpacman--version-string (elpacman--available-desc name))))))

(defun elpacman--preview-upgrades (names)
  "Print the packages in NAMES that will be upgraded, `pacman'-style.
NAMES is a list of package symbols.  A `Packages (N)' header lists each
package with its version transition."
  (let ((tokens (mapcar #'elpacman--upgrade-token names)))
    (elpacman--out "\nPackages (%d) %s\n"
                   (length names) (string-join tokens "  "))))

(defun elpacman--upgrade-all ()
  "Upgrade every package for which a newer version is available.
The upgrade transaction is previewed and confirmed first.  Return 0
when all upgrades succeeded or the user declined, 1 when at least one
upgrade failed."
  (elpacman--out ":: Starting package upgrade...\n")
  (let ((names (elpacman--upgradeable-names)))
    (cond
     ((null names)
      (elpacman--out " there is nothing to do\n")
      0)
     (t
      (elpacman--preview-upgrades names)
      (cond
       ((not (elpacman--confirm "Proceed with upgrade?"))
        0)
       (t
        (elpacman--upgrade-each names)))))))

(defun elpacman--upgrade-named (names)
  "Upgrade only the packages in NAMES, a list of symbols.
Names that are not installed are reported as errors, and names that are
already up to date are skipped.  The remaining packages are previewed
and confirmed before being upgraded.  Return 0 when every requested
upgrade succeeded or the user declined, 1 when a package is not
installed or an upgrade failed."
  (let ((status 0)
        (upgradeable (elpacman--upgradeable-names))
        (to-upgrade nil))
    (dolist (name names)
      (cond
       ((null (elpacman--installed-desc name))
        (elpacman--err "error: target not found: %s\n" name)
        (setq status 1))
       ((not (memq name upgradeable))
        (elpacman--out " %s: nothing to do\n" name))
       (t
        (push name to-upgrade))))
    (setq to-upgrade (nreverse to-upgrade))
    (when to-upgrade
      (elpacman--preview-upgrades to-upgrade)
      (when (elpacman--confirm "Proceed with upgrade?")
        (unless (zerop (elpacman--upgrade-each to-upgrade))
          (setq status 1))))
    status))

(defun elpacman--upgrade-each (names)
  "Upgrade every package in NAMES, printing `pacman'-style progress.
Return 0 when all upgrades succeeded, 1 when at least one failed."
  (let ((status 0)
        (total (length names))
        (n 0))
    (dolist (name names)
      (setq n (1+ n))
      (unless (elpacman--upgrade-one name n total)
        (setq status 1)))
    status))

(defun elpacman--upgrade-one (name n total)
  "Upgrade the single package NAME, a symbol.
N and TOTAL position this package in the `(N/TOTAL)' progress line.  The
VC and archive cases are dispatched to `package-upgrade', which knows
how to handle both.  Return non-nil on success, nil on failure."
  (condition-case err
      (progn
        (elpacman--out "(%d/%d) upgrading %s\n" n total name)
        (elpacman--with-progress (format "upgrading %s: " name)
          (package-upgrade name))
        t)
    (error
     (elpacman--err "error: failed to upgrade `%s': %s\n"
                    name (error-message-string err))
     nil)))

;;;; Sub-command: install

(cl-defun elpacman-cmd-install (args)
  "Install the packages named in ARGS.

ARGS is a list of strings.  When the `--vc' option is present the next
argument is treated as a URL or specification for a version-controlled
package to be installed via `package-vc-install'.  All remaining
arguments are treated as archive package names.

Return 0 when every package was installed or was already present, and
1 when at least one package failed to install.

The local package database is not refreshed first; run `update' when it
may be out of date."
  (unless args
    (elpacman--err "error: install requires at least one package name\n")
    (cl-return-from elpacman-cmd-install 1))
  (let ((vc-specs nil)
        (names nil)
        (rest args)
        (status 0))
    ;; Separate `--vc URL' pairs from plain package names.
    (while rest
      (let ((arg (pop rest)))
        (cond
         ((string= arg "--vc")
          (if rest
              (push (pop rest) vc-specs)
            (elpacman--err "error: --vc requires a URL or specification\n")
            (cl-return-from elpacman-cmd-install 1)))
         (t
          (push arg names)))))
    (setq names (nreverse names)
          vc-specs (nreverse vc-specs))
    ;; Validate every named archive package up front.  If any target is
    ;; neither installed nor available in the database, abort the whole
    ;; transaction without prompting or installing anything, in the
    ;; manner of `pacman -S'.
    (let* ((symbols (elpacman--intern-names names))
           (missing (seq-remove (lambda (name)
                                  (or (package-installed-p name)
                                      (elpacman--available-desc name)))
                                symbols)))
      (when missing
        (dolist (name missing)
          (elpacman--err "error: target not found: %s\n" name))
        (cl-return-from elpacman-cmd-install 1))
      ;; Preview the resolved transaction for the archive packages,
      ;; dependencies included, then ask for confirmation before touching
      ;; anything.  Version-controlled packages are listed by their spec.
      ;;
      ;; `package-install-upgrade-built-in' is bound to t for the whole
      ;; operation so that a dependency requiring a newer version of a
      ;; built-in package (such as `transient' or `compat') is satisfied
      ;; by upgrading it, rather than failing.  The binding is dynamic
      ;; and scoped to this command; it does not change the user's
      ;; setting.
      (elpacman--out "resolving dependencies...\n")
      (let* ((package-install-upgrade-built-in t)
             (new (seq-remove #'package-installed-p symbols))
             (txn (elpacman--install-transaction new)))
        (when (or txn vc-specs)
          (elpacman--preview txn "Total Installed Size:"
                             (apply #'+ (mapcar (lambda (d)
                                                  (elpacman--dir-size
                                                   (package-desc-dir d)))
                                                txn)))
          (dolist (spec vc-specs)
            (elpacman--out "  %s (from version control)\n" spec))
          (unless (elpacman--confirm "Proceed with installation?")
            (cl-return-from elpacman-cmd-install 0)))
        ;; Install every package in the resolved transaction -- the named
        ;; packages and their dependencies alike -- so the `(N/TOTAL)'
        ;; progress matches the preview above.
        (let ((total (+ (length vc-specs) (length txn)))
              (n 0))
          (dolist (spec vc-specs)
            (setq n (1+ n))
            (unless (elpacman--install-vc spec n total)
              (setq status 1)))
          (dolist (desc txn)
            (setq n (1+ n))
            (unless (elpacman--install-desc desc n total)
              (setq status 1))))))
    status))

(defun elpacman--install-transaction (names)
  "Return the `package-desc' objects to install to satisfy NAMES.
NAMES is a list of not-yet-installed package symbols.  The result
includes their dependencies, resolved with `package-compute-transaction'
and de-duplicated, so that the preview matches what will be installed."
  (let ((descs (delq nil (mapcar #'elpacman--available-desc names)))
        (seen nil)
        (result nil))
    (dolist (desc descs)
      (dolist (dep (package-compute-transaction (list desc)
                                                (package-desc-reqs desc)))
        (let ((dep-name (package-desc-name dep)))
          (unless (memq dep-name seen)
            (push dep-name seen)
            (push dep result)))))
    (nreverse result)))

(defun elpacman--install-desc (desc n total)
  "Install the archive package described by DESC.
N and TOTAL position the package in the `(N/TOTAL)' progress line.  DESC
is a `package-desc' from the resolved transaction.  A package whose
installed version already satisfies DESC -- for example a dependency
pulled in by an earlier package in the same transaction -- is reported
and skipped.  Return non-nil on success, nil when the package could not
be installed."
  (let ((name (package-desc-name desc)))
    (cond
     ;; Compare against DESC's version, not merely whether the package
     ;; is present: a built-in package (such as `transient') reports as
     ;; installed even when an older version than the transaction
     ;; requires is the one in place.
     ((package-installed-p name (package-desc-version desc))
      (elpacman--out "(%d/%d) %s is up to date -- skipping\n" n total name)
      t)
     (t
      (condition-case err
          (progn
            (elpacman--out "(%d/%d) installing %s\n" n total name)
            (elpacman--with-progress (format "installing %s: " name)
              (package-install-from-archive desc))
            t)
        (error
         (elpacman--err "error: failed to install `%s': %s\n"
                        name (error-message-string err))
         nil))))))

(defun elpacman--install-vc (spec n total)
  "Install a version-controlled package from SPEC.
N and TOTAL position the package in the `(N/TOTAL)' progress line.
SPEC is a URL, or a package name known to the archives with VC
metadata.  Installation is performed via `package-vc-install'.  Return
non-nil on success, nil when the package could not be installed."
  (condition-case err
      (progn
        (elpacman--out "(%d/%d) installing %s (from version control)\n"
                       n total spec)
        (elpacman--with-progress (format "installing %s: " spec)
          (package-vc-install spec))
        t)
    (error
     (elpacman--err "error: failed to install `%s': %s\n"
                    spec (error-message-string err))
     nil)))

;;;; Sub-command: delete

(cl-defun elpacman-cmd-delete (args)
  "Delete the packages named in ARGS.
Packages that are not installed are reported as errors.  The remaining
packages are previewed and confirmed before being deleted, and the disk
space freed by each is reported.  ARGS is a list of package name
strings.  Return 0 on success or when the user declines, 1 when a named
package is not installed."
  (unless args
    (elpacman--err "error: delete requires at least one package name\n")
    (cl-return-from elpacman-cmd-delete 1))
  (let ((status 0)
        (descs nil))
    ;; Resolve names to installed descriptions, reporting any that are
    ;; not installed, before touching anything.
    (elpacman--out "checking dependencies...\n")
    (dolist (name (elpacman--intern-names args))
      (let ((desc (elpacman--installed-desc name)))
        (if desc
            (push desc descs)
          (elpacman--err "error: target not found: %s\n" name)
          (setq status 1))))
    (setq descs (nreverse descs))
    (when descs
      (elpacman--preview descs "Total Removed Size:"
                         (apply #'+ (mapcar (lambda (d)
                                              (elpacman--dir-size
                                               (package-desc-dir d)))
                                            descs)))
      (when (elpacman--confirm "Do you want to remove these packages?")
        (let ((total (length descs))
              (n 0))
          (dolist (desc descs)
            (setq n (1+ n))
            (unless (elpacman--delete-one desc n total)
              (setq status 1))))))
    status))

(defun elpacman--delete-one (desc n total)
  "Delete the package described by DESC.
N and TOTAL position the package in the `(N/TOTAL)' progress line.
Return non-nil on success, nil on failure."
  (let ((name (package-desc-name desc)))
    (condition-case err
        (progn
          (elpacman--out "(%d/%d) removing %s\n" n total name)
          (elpacman--with-progress (format "removing %s: " name)
            ;; Force deletion and do not deselect, so dependencies of
            ;; still-needed packages are handled by `autoremove'.
            (package-delete desc t))
          t)
      (error
       (elpacman--err "error: failed to delete `%s': %s\n"
                      name (error-message-string err))
       nil))))

;;;; Sub-command: search

(cl-defun elpacman-cmd-search (args)
  "Search the package archives for the terms in ARGS.
Every term in ARGS must match, case-insensitively, either the package
name or its summary.  Matching packages are printed together with their
version, installed marker and summary.  Return 0 on success, 2 when no
search term was given."
  (unless args
    (elpacman--err "error: search requires at least one search term\n")
    (cl-return-from elpacman-cmd-search 2))
  (let ((terms (mapcar #'downcase args))
        (matches nil))
    (dolist (entry package-archive-contents)
      (let* ((name (car entry))
             (desc (cadr entry))
             (summary (or (package-desc-summary desc) ""))
             (haystack (downcase (concat (symbol-name name) " " summary))))
        (when (cl-every (lambda (term) (string-search term haystack)) terms)
          (push (cons name desc) matches))))
    (setq matches (sort matches
                        (lambda (a b)
                          (string< (symbol-name (car a))
                                   (symbol-name (car b))))))
    (if (null matches)
        (progn
          (elpacman--out "No packages match: %s\n" (mapconcat #'identity args " "))
          0)
      (dolist (match matches)
        (let* ((name (car match))
               (desc (cdr match))
               (installed (elpacman--installed-desc name))
               (archive (or (package-desc-archive desc) "?")))
          ;; Mirror `pacman -Ss': `repo/name version' with the summary
          ;; indented on the following line, and an installed marker.
          (elpacman--out "%s/%s %s%s\n    %s\n"
                         archive
                         name
                         (elpacman--version-string desc)
                         (if installed " [installed]" "")
                         (or (package-desc-summary desc) ""))))
      0)))

;;;; Sub-command: info

(defun elpacman--source-string (installed available)
  "Return a human-readable source for a package.
INSTALLED and AVAILABLE are the installed and available `package-desc'
objects, either of which may be nil.  Version-controlled packages are
reported as such, archive packages report their archive name."
  (cond
   ((elpacman--vc-p installed) "version control")
   ((and available (package-desc-archive available))
    (package-desc-archive available))
   ((and installed (package-desc-archive installed))
    (package-desc-archive installed))
   (t "-")))

(defun elpacman--extra (desc key)
  "Return the extras value stored under KEY in DESC, or nil.
DESC is a `package-desc'; KEY is a keyword such as `:url'."
  (and desc (cdr (assq key (package-desc-extras desc)))))

(defun elpacman--format-people (people)
  "Format PEOPLE, an alist of (NAME . EMAIL), as a display string.
Return nil when PEOPLE is empty."
  (when people
    (mapconcat (lambda (person)
                 (let ((name (car person))
                       (email (cdr person)))
                   (if (and email (not (string-empty-p email)))
                       (format "%s <%s>" name email)
                     name)))
               people ", ")))

(defun elpacman--required-by (name)
  "Return the names of installed packages that depend on NAME, as symbols.
NAME is a package symbol.  The result is sorted alphabetically."
  (let ((dependents nil))
    (dolist (entry package-alist)
      (when (assq name (package-desc-reqs (cadr entry)))
        (push (car entry) dependents)))
    (sort dependents (lambda (a b) (string< (symbol-name a) (symbol-name b))))))

(cl-defun elpacman-cmd-info (args)
  "Show detailed information about the package named in ARGS.
Only the first element of ARGS is used.  Information is drawn from the
installed description when present, otherwise from the archives.
Return 0 on success, 1 when the package is unknown."
  (unless args
    (elpacman--err "error: info requires a package name\n")
    (cl-return-from elpacman-cmd-info 1))
  (let* ((name (intern (car args)))
         (installed (elpacman--installed-desc name))
         (available (elpacman--available-desc name))
         (desc (or installed available)))
    (unless desc
      (elpacman--err "error: unknown package `%s'\n" name)
      (cl-return-from elpacman-cmd-info 1))
    ;; Field layout mirrors `pacman -Qi'.
    (elpacman--out "Name            : %s\n" name)
    (elpacman--out "Version         : %s\n"
                   (elpacman--version-string (or available installed)))
    (elpacman--out "Description     : %s\n" (or (package-desc-summary desc) "-"))
    (elpacman--out "URL             : %s\n" (or (elpacman--extra desc :url) "-"))
    (let ((keywords (elpacman--extra desc :keywords)))
      (elpacman--out "Keywords        : %s\n"
                     (if keywords (mapconcat #'identity keywords "  ") "None")))
    (let ((people (or (elpacman--format-people (elpacman--extra desc :maintainers))
                      (elpacman--format-people (elpacman--extra desc :authors)))))
      (elpacman--out "Maintainer      : %s\n" (or people "-")))
    (elpacman--out "Repository      : %s\n"
                   (elpacman--source-string installed available))
    ;; A version-controlled package pins a specific commit; show it.
    (when (elpacman--vc-p installed)
      (elpacman--out "Commit          : %s\n"
                     (or (ignore-errors (package-vc-commit installed)) "-")))
    (let ((reqs (package-desc-reqs desc)))
      (elpacman--out "Depends On      : %s\n"
                     (if reqs
                         (mapconcat
                          (lambda (r)
                            (format "%s %s" (car r)
                                    (package-version-join (cadr r))))
                          reqs "  ")
                       "None")))
    ;; Reverse dependencies are only meaningful for an installed package.
    (when installed
      (let ((rdeps (elpacman--required-by name)))
        (elpacman--out "Required By     : %s\n"
                       (if rdeps
                           (mapconcat #'symbol-name rdeps "  ")
                         "None"))))
    (elpacman--out "Installed       : %s\n"
                   (if installed
                       (format "Yes (%s)" (elpacman--version-string installed))
                     "No"))
    (when installed
      (elpacman--out "Installed Size  : %s\n"
                     (elpacman--human-size
                      (elpacman--dir-size (package-desc-dir installed))))
      (elpacman--out "Install Dir     : %s\n"
                     (or (package-desc-dir installed) "-")))
    0))

;;;; Sub-command: list

(defun elpacman-cmd-list (_args)
  "List every installed package with its version and source.
ARGS are ignored.  Return 0."
  (let ((descs (elpacman--installed-descs)))
    (if (null descs)
        (elpacman--out "No packages are installed.\n")
      (dolist (desc descs)
        (elpacman--out "%s %s%s\n"
                       (package-desc-name desc)
                       (elpacman--version-string desc)
                       (if (elpacman--vc-p desc) " (vc)" "")))
      (elpacman--out "\n%d package(s) installed.\n" (length descs)))
    0))

;;;; Sub-command: outdated

(defun elpacman-cmd-outdated (_args)
  "List packages for which an upgrade is available.
ARGS are ignored.  The local package database is not refreshed first;
run `update' when it may be out of date.  Return 0 on success; an error
while consulting the database is signalled and reported by the caller as
a non-zero exit status."
  (let ((names (elpacman--upgradeable-names)))
    (if (null names)
        (elpacman--out "All packages are already up to date.\n")
      (dolist (name (sort (copy-sequence names)
                          (lambda (a b) (string< (symbol-name a)
                                                 (symbol-name b)))))
        (let ((installed (elpacman--installed-desc name)))
          (if (elpacman--vc-p installed)
              ;; A VC package upgrades from its remote, so there is no
              ;; archive version to show as the target.
              (elpacman--out "%s vc (vc)\n" name)
            (elpacman--out "%s %s -> %s\n"
                           name
                           (elpacman--version-string installed)
                           (elpacman--version-string (elpacman--available-desc name))))))
      (elpacman--out "\n%d package(s) can be upgraded.\n" (length names)))
    0))

;;;; Sub-command: check

(defun elpacman-cmd-check (_args)
  "Check installed packages for problems.
ARGS are ignored.  A package is reported as broken when its installation
directory is missing, or when one of its declared dependencies is not
satisfied by an installed package.  Return 0 when no problems are found,
1 otherwise."
  (let ((problems 0))
    (dolist (desc (elpacman--installed-descs))
      (let* ((name (package-desc-name desc))
             (dir (package-desc-dir desc)))
        ;; A missing directory means the package is registered but its
        ;; files are gone.
        (when (and dir (stringp dir) (not (file-directory-p dir)))
          (elpacman--err "broken: `%s' directory is missing: %s\n" name dir)
          (setq problems (1+ problems)))
        ;; Every hard dependency, except the pseudo-package `emacs',
        ;; must resolve to an installed package.
        (dolist (req (package-desc-reqs desc))
          (let ((dep (car req)))
            (unless (or (eq dep 'emacs)
                        (package-installed-p dep (cadr req)))
              (elpacman--err "broken: `%s' requires `%s' %s which is not satisfied\n"
                             name dep (package-version-join (cadr req)))
              (setq problems (1+ problems)))))))
    (if (zerop problems)
        (progn
          (elpacman--out "No broken packages found.\n")
          0)
      (elpacman--err "%d problem(s) found.\n" problems)
      1)))

;;;; Sub-command: recompile

(defun elpacman-cmd-recompile (_args)
  "Recompile the byte-code of all installed packages.
ARGS are ignored.  This is useful after upgrading Emacs itself, when the
existing byte-code may no longer be valid.  Return 0 on success; a
failure during recompilation is signalled and reported by the caller as
a non-zero exit status."
  (elpacman--out ":: Recompiling installed packages...\n")
  (elpacman--with-progress "recompile: "
    (package-recompile-all))
  (elpacman--out "Recompilation finished.\n")
  0)

;;;; Sub-command: autoremove

(defun elpacman-cmd-autoremove (_args)
  "Remove packages installed as dependencies that are no longer required.
The removable packages are computed explicitly, previewed and confirmed
before removal, so that the disk space freed by each can be reported.
ARGS are ignored.  Return 0 on success or when the user declines, 1 when
a removal failed."
  (elpacman--out ":: Searching for unneeded packages...\n")
  (let ((names (package--removable-packages)))
    (cond
     ((null names)
      (elpacman--out " there is nothing to do\n")
      0)
     (t
      (let ((descs (delq nil (mapcar #'elpacman--installed-desc names)))
            (status 0))
        (elpacman--preview descs "Total Removed Size:"
                           (apply #'+ (mapcar (lambda (d)
                                                (elpacman--dir-size
                                                 (package-desc-dir d)))
                                              descs)))
        (when (elpacman--confirm "Do you want to remove these packages?")
          (let ((total (length descs))
                (n 0))
            (dolist (desc descs)
              (setq n (1+ n))
              (unless (elpacman--delete-one desc n total)
                (setq status 1)))))
        status)))))

;;;; Sub-command: version

(defun elpacman-cmd-version (_args)
  "Print the `elpacman' version and the Emacs version.
ARGS are ignored.  Return 0."
  (elpacman--out "elpacman %s (GNU Emacs %s)\n" elpacman-version emacs-version)
  0)

;;;; Sub-command: completions

(defun elpacman--completion-command-names ()
  "Return the list of user-facing sub-command names, for completion."
  (mapcar #'car elpacman--command-info))

(defun elpacman--completions-bash ()
  "Return a Bash completion script for `elpacman' as a string.
The script completes sub-command names in the first position and, once
a sub-command is known, the options that command accepts.  Package names
are intentionally not completed."
  (let ((commands (string-join (elpacman--completion-command-names) " "))
        (cases
         (mapconcat
          (lambda (entry)
            (let* ((name (car entry))
                   (options (elpacman--command-options name)))
              (format "        %s)\n            opts=\"%s\"\n            ;;"
                      name
                      (string-join (mapcar #'car options) " "))))
          elpacman--command-info
          "\n")))
    (concat
     "# Bash completion for elpacman.\n"
     "# Generated by `elpacman completions bash'; do not edit by hand.\n"
     "# shellcheck shell=bash\n"
     "_elpacman() {\n"
     "    local cur cword\n"
     "    _init_completion || return\n"
     "\n"
     "    local commands=\"" commands "\"\n"
     "\n"
     "    if [ \"${cword}\" -eq 1 ]; then\n"
     "        mapfile -t COMPREPLY < <(compgen -W \"${commands}\" -- \"${cur}\")\n"
     "        return\n"
     "    fi\n"
     "\n"
     "    local opts=\"\"\n"
     "    # `words' is populated by bash-completion's `_init_completion'.\n"
     "    # shellcheck disable=SC2154\n"
     "    case \"${words[1]}\" in\n"
     cases "\n"
     "    esac\n"
     "\n"
     "    if [ -n \"${opts}\" ]; then\n"
     "        mapfile -t COMPREPLY < <(compgen -W \"${opts}\" -- \"${cur}\")\n"
     "    fi\n"
     "}\n"
     "complete -F _elpacman elpacman\n")))

(defun elpacman--zsh-quote (str)
  "Return STR made safe to place inside a Zsh single-quoted description.
Single quotes and backticks cannot appear inside a Zsh single-quoted
string, so the backtick-quotes used in the descriptions are removed."
  (replace-regexp-in-string "[`']" "" str))

(defun elpacman--completions-zsh ()
  "Return a Zsh completion script for `elpacman' as a string.
The script offers the sub-commands with their descriptions, and the
options each sub-command accepts.  Package names are not completed."
  (let ((commands
         (mapconcat
          (lambda (entry)
            ;; NAME:DESCRIPTION.  Colons in the description are escaped,
            ;; and quotes removed, so the entry stays a valid Zsh word.
            (format "        '%s:%s'"
                    (car entry)
                    (replace-regexp-in-string
                     ":" "\\\\:" (elpacman--zsh-quote (nth 2 entry)))))
          elpacman--command-info
          "\n"))
        (cases
         (mapconcat
          (lambda (entry)
            (let* ((name (car entry))
                   (options (elpacman--command-options name)))
              (if options
                  (format "                %s)\n                    _arguments %s\n                    ;;"
                          name
                          (mapconcat
                           (lambda (opt)
                             (format "'%s[%s]'"
                                     (car opt)
                                     (elpacman--zsh-quote (cdr opt))))
                           options " "))
                (format "                %s)\n                    ;;" name))))
          elpacman--command-info
          "\n")))
    (concat
     "#compdef elpacman\n"
     "# Zsh completion for elpacman.\n"
     "# Generated by `elpacman completions zsh'; do not edit by hand.\n"
     "_elpacman() {\n"
     "    local curcontext=\"$curcontext\" state line\n"
     "    _arguments -C \\\n"
     "        '1: :->command' \\\n"
     "        '*:: :->args'\n"
     "\n"
     "    case $state in\n"
     "        command)\n"
     "            local -a commands\n"
     "            commands=(\n"
     commands "\n"
     "            )\n"
     "            _describe -t commands 'elpacman command' commands\n"
     "            ;;\n"
     "        args)\n"
     "            case $line[1] in\n"
     cases "\n"
     "            esac\n"
     "            ;;\n"
     "    esac\n"
     "}\n"
     "_elpacman \"$@\"\n")))

(cl-defun elpacman-cmd-completions (args)
  "Print a shell completion script for the shell named in ARGS.
The first element of ARGS must be `bash' or `zsh'.  The script completes
sub-command names and options, but not package names.  Return 0 on
success, 2 when the shell is missing or unsupported."
  (let ((shell (car args)))
    (cond
     ((null shell)
      (elpacman--err "error: completions requires a shell name (bash or zsh)\n")
      (cl-return-from elpacman-cmd-completions 2))
     ((string= shell "bash")
      (elpacman--out "%s" (elpacman--completions-bash))
      0)
     ((string= shell "zsh")
      (elpacman--out "%s" (elpacman--completions-zsh))
      0)
     (t
      (elpacman--err "error: unsupported shell `%s' (expected bash or zsh)\n" shell)
      2))))

;;;; Sub-command: help

(defconst elpacman--usage
  "elpacman -- a command-line package manager for Emacs

Usage:
  elpacman <sub-command> [arguments...]

Sub-commands:
  update             Refresh the local package database from the archives
  upgrade [PKG...]   Upgrade all packages, or only the named ones
  install PKG...     Install one or more packages
  install --vc URL   Install a package from a version-control URL
  delete PKG...      Delete one or more installed packages
  search TERM...     Search the archives for packages
  info PKG           Show detailed information about a package
  list               List installed packages
  outdated           List packages for which an upgrade is available
  check              Check for broken packages
  recompile          Recompile the byte-code of installed packages
  autoremove         Remove unused dependency packages
  completions SHELL  Print a completion script for bash or zsh
  version            Show the elpacman version
  help               Show this help text

Options:
  -y, --yes, --assume-yes   Do not prompt for confirmation
"
  "The usage text printed by the `help' sub-command.")

(defun elpacman-cmd-help (_args)
  "Print the usage information for `elpacman'.
ARGS are ignored.  Return 0."
  (elpacman--out "%s" elpacman--usage)
  0)

;;;; Dispatch

(defconst elpacman--commands
  '(("update"     . elpacman-cmd-update)
    ("upgrade"    . elpacman-cmd-upgrade)
    ("install"    . elpacman-cmd-install)
    ("delete"     . elpacman-cmd-delete)
    ("remove"     . elpacman-cmd-delete)
    ("search"     . elpacman-cmd-search)
    ("info"       . elpacman-cmd-info)
    ("list"       . elpacman-cmd-list)
    ("outdated"   . elpacman-cmd-outdated)
    ("check"      . elpacman-cmd-check)
    ("recompile"  . elpacman-cmd-recompile)
    ("autoremove" . elpacman-cmd-autoremove)
    ("completions" . elpacman-cmd-completions)
    ("version"    . elpacman-cmd-version)
    ("--version"  . elpacman-cmd-version)
    ("help"       . elpacman-cmd-help)
    ("--help"     . elpacman-cmd-help)
    ("-h"         . elpacman-cmd-help))
  "Association list mapping sub-command names to their handler functions.
Each handler receives the remaining arguments as a list of strings and
returns an integer exit status.")

(defun elpacman--command-options (name)
  "Return the options accepted by sub-command NAME as a description alist.
The result combines the global confirm-skip options, when the command
accepts them, with any command-specific options."
  (let ((entry (assoc name elpacman--command-info)))
    (when entry
      (append (when (nth 1 entry) elpacman--global-options)
              (nthcdr 3 entry)))))


(defun elpacman--needs-init-p (command)
  "Return non-nil when COMMAND requires the package system to be ready.
The informational sub-commands do not touch the package system."
  (not (member command '("version" "--version" "help" "--help" "-h"
                         "completions"))))

(defun elpacman--extract-assume-yes (args)
  "Return ARGS with the confirm-skip options removed.
As a side effect, `elpacman--assume-yes' is set when any of `-y',
`--yes' or `--assume-yes' is present in ARGS, or when the
`ELPACMAN_ASSUME_YES' environment variable is non-empty."
  (let ((env (getenv "ELPACMAN_ASSUME_YES")))
    (when (and env (not (string-empty-p env)))
      (setq elpacman--assume-yes t)))
  (let ((options '("-y" "--yes" "--assume-yes")))
    (seq-remove (lambda (arg)
                  (when (member arg options)
                    (setq elpacman--assume-yes t)))
                args)))

(defun elpacman--dispatch (args)
  "Dispatch to the sub-command handler selected by ARGS.
ARGS is the full argument list as received from the command line, with
any leading `--' separator already removed.  The confirm-skip options
are extracted from ARGS before the sub-command is selected.  Return the
integer exit status of the handler."
  (setq args (elpacman--extract-assume-yes args))
  (let* ((command (car args))
         (rest (cdr args))
         (handler (cdr (assoc command elpacman--commands))))
    (cond
     ((null command)
      (elpacman-cmd-help nil)
      1)
     ((null handler)
      (elpacman--err "error: unknown sub-command `%s'\n\n" command)
      (elpacman-cmd-help nil)
      1)
     (t
      (when (elpacman--needs-init-p command)
        (elpacman--init))
      (funcall handler rest)))))

(defun elpacman--strip-separator (args)
  "Return the sub-command arguments found in ARGS.
By convention everything up to and including the first `--' separator
belongs to Emacs itself, and everything after it belongs to `elpacman'.
When no separator is present ARGS is returned unchanged, which is the
case when the file is driven directly, e.g. from the test-suite."
  (let ((tail (member "--" args)))
    (if tail
        (cdr tail)
      args)))

(defun elpacman-main ()
  "Entry point when run as a script.
Parse `command-line-args-left', dispatch to the selected sub-command
and terminate Emacs with the handler's exit status.  Any uncaught error
is reported on the standard error and results in a non-zero status."
  (let ((args (elpacman--strip-separator command-line-args-left))
        (status 0))
    (condition-case err
        (setq status (elpacman--dispatch args))
      (elpacman-aborted
       (elpacman--err "error: %s\n" (cadr err))
       (setq status 1))
      (error
       (elpacman--err "error: %s\n" (error-message-string err))
       (setq status 1)))
    ;; Consume the arguments so Emacs does not try to interpret them.
    (setq command-line-args-left nil)
    (kill-emacs (if (integerp status) status 0))))

;; Only run automatically when executed as a script, not when loaded
;; interactively or by the test-suite.  Emacs records the `--script'
;; option internally as `-scriptload', which is what we look for.  The
;; test-suite loads this file with `require' instead, so the guard does
;; not fire there; it may also set `elpacman-run-as-script' explicitly.
(when (and noninteractive
           (or (member "-scriptload" command-line-args)
               (member "--script" command-line-args)
               (bound-and-true-p elpacman-run-as-script)))
  (elpacman-main))

(provide 'elpacman)

;;; elpacman.el ends here
