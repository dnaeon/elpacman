;;; test-elpacman.el --- Tests for elpacman -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Marin Atanasov Nikolov <dnaeon@gmail.com>
;; All rights reserved.
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

;; The test-suite for `elpacman'.  It is split into two groups.
;;
;; The unit tests exercise argument parsing, sub-command dispatch and
;; the various pure helper functions.  They do not touch the network
;; and are always run.
;;
;; The integration tests exercise the full install/upgrade/delete cycle
;; against a real package archive, inside a throw-away package
;; directory.  They require network access and are only run when the
;; `ELPACMAN_INTEGRATION' environment variable is set to a non-empty
;; value, so that the fast unit tests can be run in isolation.
;;
;; Run the whole suite with the accompanying `scripts/run-tests.sh'.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Load the code under test from the same directory as this file.
(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path (expand-file-name ".." here))
  (add-to-list 'load-path here))
(require 'elpacman)

;;;; Helpers

(defmacro elpacman-test-with-output (&rest body)
  "Evaluate BODY and return the text it prints to the standard output.
The standard output routines of `elpacman' are redirected into a
string, so that the printed output can be inspected."
  (declare (indent 0))
  `(let ((buffer (generate-new-buffer " *elpacman-test-out*")))
     (unwind-protect
         (progn
           (cl-letf (((symbol-function 'elpacman--out)
                      (lambda (fmt &rest args)
                        (with-current-buffer buffer
                          (insert (apply #'format fmt args)))))
                     ((symbol-function 'elpacman--err)
                      (lambda (fmt &rest args)
                        (with-current-buffer buffer
                          (insert (apply #'format fmt args))))))
             ,@body)
           (with-current-buffer buffer (buffer-string)))
       (kill-buffer buffer))))

;;;; Unit tests: argument separator handling

(ert-deftest elpacman-test-strip-separator-after ()
  "Arguments after `--' are returned, the separator is dropped."
  (should (equal (elpacman--strip-separator '("--" "install" "magit"))
                 '("install" "magit"))))

(ert-deftest elpacman-test-strip-separator-with-leading-emacs-args ()
  "Everything up to and including the first `--' is discarded."
  (should (equal (elpacman--strip-separator '("-l" "rc.el" "--" "update"))
                 '("update"))))

(ert-deftest elpacman-test-strip-separator-none ()
  "When there is no separator the arguments are returned unchanged."
  (should (equal (elpacman--strip-separator '("update"))
                 '("update"))))

(ert-deftest elpacman-test-strip-separator-empty-tail ()
  "A trailing separator yields an empty argument list."
  (should (equal (elpacman--strip-separator '("--")) nil)))

;;;; Unit tests: dispatch

(ert-deftest elpacman-test-dispatch-unknown-command ()
  "An unknown sub-command reports an error and returns 1."
  (let ((output (elpacman-test-with-output
                  (should (equal (elpacman--dispatch '("bogus")) 1)))))
    (should (string-search "unknown sub-command" output))))

(ert-deftest elpacman-test-dispatch-no-command ()
  "With no sub-command the usage is printed and 1 is returned."
  (let ((output (elpacman-test-with-output
                  (should (equal (elpacman--dispatch nil) 1)))))
    (should (string-search "Usage:" output))))

(ert-deftest elpacman-test-dispatch-version ()
  "The `version' sub-command prints the version and returns 0."
  (let ((output (elpacman-test-with-output
                  (should (equal (elpacman--dispatch '("version")) 0)))))
    (should (string-search elpacman-version output))))

(ert-deftest elpacman-test-dispatch-help ()
  "The `help' sub-command prints the usage and returns 0."
  (let ((output (elpacman-test-with-output
                  (should (equal (elpacman--dispatch '("help")) 0)))))
    (should (string-search "Sub-commands:" output))))

(ert-deftest elpacman-test-command-aliases ()
  "The `remove' alias resolves to the same handler as `delete'."
  (should (eq (cdr (assoc "remove" elpacman--commands))
              (cdr (assoc "delete" elpacman--commands)))))

(ert-deftest elpacman-test-needs-init-p ()
  "Informational commands do not require the package system."
  (should-not (elpacman--needs-init-p "help"))
  (should-not (elpacman--needs-init-p "version"))
  (should (elpacman--needs-init-p "update"))
  (should (elpacman--needs-init-p "install")))

;;;; Unit tests: argument validation without the package system

(ert-deftest elpacman-test-install-requires-argument ()
  "Installing with no package name returns 1 and reports an error."
  (let ((output (elpacman-test-with-output
                  (should (equal (elpacman-cmd-install nil) 1)))))
    (should (string-search "requires at least one package" output))))

(ert-deftest elpacman-test-delete-requires-argument ()
  "Deleting with no package name returns 1 and reports an error."
  (let ((output (elpacman-test-with-output
                  (should (equal (elpacman-cmd-delete nil) 1)))))
    (should (string-search "requires at least one package" output))))

(ert-deftest elpacman-test-search-requires-argument ()
  "Searching with no term returns 2 and reports an error."
  (let ((output (elpacman-test-with-output
                  (should (equal (elpacman-cmd-search nil) 2)))))
    (should (string-search "requires at least one search term" output))))

(ert-deftest elpacman-test-info-requires-argument ()
  "Requesting info with no package name returns 1 and reports an error."
  (let ((output (elpacman-test-with-output
                  (should (equal (elpacman-cmd-info nil) 1)))))
    (should (string-search "requires a package name" output))))

(ert-deftest elpacman-test-install-vc-requires-url ()
  "The `--vc' option without a following URL returns 1.
The error is reported before any package operation, so the test stays
offline."
  (let ((output (elpacman-test-with-output
                  (should (equal (elpacman-cmd-install '("--vc")) 1)))))
    (should (string-search "--vc requires" output))))

;;;; Unit tests: version rendering

(ert-deftest elpacman-test-version-string-nil ()
  "A missing description renders as a dash."
  (should (equal (elpacman--version-string nil) "-")))

(ert-deftest elpacman-test-version-string-archive ()
  "An archive description renders its dotted version."
  (let ((desc (package-desc-create :name 'demo :version '(1 2 3))))
    (should (equal (elpacman--version-string desc) "1.2.3"))))

(ert-deftest elpacman-test-upgrade-token-archive ()
  "The upgrade token of an archive package shows the version transition."
  (cl-letf (((symbol-function 'elpacman--installed-desc)
             (lambda (_) (package-desc-create :name 'demo :version '(1 0))))
            ((symbol-function 'elpacman--available-desc)
             (lambda (_) (package-desc-create :name 'demo :version '(2 0)))))
    (should (equal (elpacman--upgrade-token 'demo) "demo-1.0->2.0"))))

(ert-deftest elpacman-test-upgrade-token-vc ()
  "The upgrade token of a VC package shows `NAME-vc', not a bogus transition.
A version-controlled package has no archive version to upgrade towards,
so it must not render as `demo-vc->-'."
  (cl-letf (((symbol-function 'elpacman--installed-desc)
             (lambda (_) (package-desc-create :name 'demo :version '(1 0))))
            ((symbol-function 'elpacman--vc-p) (lambda (_) t)))
    (should (equal (elpacman--upgrade-token 'demo) "demo-vc"))))

;;;; Unit tests: terminal width parsing

(ert-deftest elpacman-test-term-width-valid ()
  "A positive integer in COLUMNS is parsed."
  (let ((process-environment (cons "COLUMNS=80" process-environment)))
    (should (equal (elpacman--term-width) 80))))

(ert-deftest elpacman-test-term-width-invalid ()
  "A non-numeric or empty COLUMNS yields nil."
  (let ((process-environment (cons "COLUMNS=" process-environment)))
    (should-not (elpacman--term-width)))
  (let ((process-environment (cons "COLUMNS=abc" process-environment)))
    (should-not (elpacman--term-width))))

(ert-deftest elpacman-test-trim-no-width ()
  "With an unknown width strings are returned unchanged."
  (let ((elpacman--term-width 0))
    (should (equal (elpacman--trim "hello world") "hello world"))))

(ert-deftest elpacman-test-trim-truncates ()
  "With a known width long strings are truncated to fit."
  (let ((elpacman--term-width 5))
    (should (equal (elpacman--trim "hello world") "hello"))))

;;;; Unit tests: progress rendering

(defmacro elpacman-test-with-raw-output (&rest body)
  "Evaluate BODY and return everything written to the raw output stream.
The low-level `elpacman--princ' is redirected into a string, so that the
exact bytes rendered by `elpacman--with-progress' can be inspected,
including the prefix and the control sequences."
  (declare (indent 0))
  `(let* ((buffer (generate-new-buffer " *elpacman-test-raw*"))
          ;; `elpacman--princ' holds a function value and is called with
          ;; `funcall', so it is rebound as a variable, not as a
          ;; function cell.
          (elpacman--princ
           (lambda (obj &optional _stream)
             (with-current-buffer buffer (insert obj))
             obj)))
     (unwind-protect
         (progn
           (cl-letf (((symbol-function 'flush-standard-output) #'ignore))
             ,@body)
           (with-current-buffer buffer (buffer-string)))
       (kill-buffer buffer))))

(ert-deftest elpacman-test-progress-shows-prefix ()
  "Messages captured by `elpacman--with-progress' carry the prefix.
This guards against the prefix being dropped when the helper binding is
not visible where the line is drawn."
  (let ((elpacman--term-width 200))
    (let ((output (elpacman-test-with-raw-output
                    (elpacman--with-progress "demo: "
                      (message "working")))))
      (should (string-search "demo: working" output)))))

(ert-deftest elpacman-test-progress-dumps-on-error ()
  "When the body signals, the captured messages are dumped to stderr."
  (let ((elpacman--term-width 200)
        (dumped nil))
    (cl-letf (((symbol-function 'elpacman--err)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) dumped))))
      (should-error
       (elpacman-test-with-raw-output
         (elpacman--with-progress "demo: "
           (message "before the error")
           (error "Boom"))))
      (should (cl-some (lambda (line) (string-search "before the error" line))
                       dumped)))))

(ert-deftest elpacman-test-progress-respects-standard-output ()
  "Output bound to a buffer is not hijacked by the progress capture.
This guards against the regression where `princ' calls made by
`custom-save-variables' -- which bind `standard-output' to a buffer --
were captured and redirected, corrupting the written file."
  (let ((elpacman--term-width 200))
    (with-temp-buffer
      (let ((target (current-buffer)))
        ;; Simulate what `custom-save-variables' does: bind
        ;; `standard-output' to a buffer and `princ' into it, all while
        ;; the progress capture is active.  The writes must land in the
        ;; buffer, not on the progress line.
        (elpacman--with-progress "demo: "
          (let ((standard-output target))
            (princ "(setq x ")
            (prin1 '(1 2 3))
            (princ ")")))
        (should (equal (buffer-string) "(setq x (1 2 3))"))))))

(ert-deftest elpacman-test-progress-respects-explicit-stream ()
  "Output sent to an explicit stream is not hijacked by the capture."
  (let ((elpacman--term-width 200))
    (with-temp-buffer
      (let ((target (current-buffer)))
        (elpacman--with-progress "demo: "
          (princ "hello" target))
        (should (equal (buffer-string) "hello"))))))

;;;; Unit tests: confirm-skip flag parsing

(ert-deftest elpacman-test-extract-assume-yes-short ()
  "The `-y' option sets the assume-yes flag and is removed from ARGS."
  (let ((elpacman--assume-yes nil)
        (process-environment (cons "ELPACMAN_ASSUME_YES=" process-environment)))
    (should (equal (elpacman--extract-assume-yes '("install" "-y" "magit"))
                   '("install" "magit")))
    (should elpacman--assume-yes)))

(ert-deftest elpacman-test-extract-assume-yes-long ()
  "The `--yes' and `--assume-yes' options set the flag and are removed."
  (dolist (opt '("--yes" "--assume-yes"))
    (let ((elpacman--assume-yes nil)
          (process-environment (cons "ELPACMAN_ASSUME_YES=" process-environment)))
      (should (equal (elpacman--extract-assume-yes (list "upgrade" opt))
                     '("upgrade")))
      (should elpacman--assume-yes))))

(ert-deftest elpacman-test-extract-assume-yes-absent ()
  "Without an option or the environment variable, the flag stays nil."
  (let ((elpacman--assume-yes nil)
        (process-environment (cons "ELPACMAN_ASSUME_YES=" process-environment)))
    (should (equal (elpacman--extract-assume-yes '("list")) '("list")))
    (should-not elpacman--assume-yes)))

(ert-deftest elpacman-test-extract-assume-yes-from-env ()
  "A non-empty `ELPACMAN_ASSUME_YES' sets the flag."
  (let ((elpacman--assume-yes nil)
        (process-environment (cons "ELPACMAN_ASSUME_YES=1" process-environment)))
    (elpacman--extract-assume-yes '("upgrade"))
    (should elpacman--assume-yes)))

;;;; Unit tests: confirmation

(ert-deftest elpacman-test-confirm-assume-yes ()
  "With assume-yes set, `elpacman--confirm' agrees without prompting."
  (let ((elpacman--assume-yes t))
    (should (elpacman--confirm "Proceed?"))))

(ert-deftest elpacman-test-confirm-non-interactive-aborts ()
  "Without a terminal and without assume-yes, confirmation aborts."
  (let ((elpacman--assume-yes nil)
        (process-environment (cons "ELPACMAN_TTY=" process-environment)))
    (should-error (elpacman--confirm "Proceed?") :type 'elpacman-aborted)))

(ert-deftest elpacman-test-confirm-interactive-yes ()
  "An interactive `y' answer is treated as agreement."
  (let ((elpacman--assume-yes nil)
        (process-environment (cons "ELPACMAN_TTY=1" process-environment)))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "y")))
      (should (elpacman--confirm "Proceed?")))))

(ert-deftest elpacman-test-confirm-interactive-default-yes ()
  "A bare newline defaults to agreement, in the manner of pacman's [Y/n]."
  (let ((elpacman--assume-yes nil)
        (process-environment (cons "ELPACMAN_TTY=1" process-environment)))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "")))
      (should (elpacman--confirm "Proceed?")))))

(ert-deftest elpacman-test-confirm-interactive-no ()
  "An interactive `n' answer is treated as refusal."
  (let ((elpacman--assume-yes nil)
        (process-environment (cons "ELPACMAN_TTY=1" process-environment)))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "n")))
      (should-not (elpacman--confirm "Proceed?")))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "no")))
      (should-not (elpacman--confirm "Proceed?")))))

;;;; Unit tests: size helpers

(ert-deftest elpacman-test-human-size ()
  "`elpacman--human-size' formats byte counts."
  (should (equal (elpacman--human-size 0) "0"))
  (should (stringp (elpacman--human-size 1536))))

(ert-deftest elpacman-test-dir-size-nil ()
  "A nil or missing directory has size zero."
  (should (equal (elpacman--dir-size nil) 0))
  (should (equal (elpacman--dir-size "/no/such/directory/here") 0)))

(ert-deftest elpacman-test-dir-size-counts-files ()
  "`elpacman--dir-size' sums the sizes of the files under a directory."
  (let ((dir (make-temp-file "elpacman-size-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "a" dir) (insert (make-string 100 ?x)))
          (with-temp-file (expand-file-name "b" dir) (insert (make-string 50 ?y)))
          (should (equal (elpacman--dir-size dir) 150)))
      (delete-directory dir t))))

;;;; Unit tests: preview

(ert-deftest elpacman-test-preview-lists-packages ()
  "`elpacman--preview' prints a pacman-style `Packages (N)' header.
The optional size line is included when a label is supplied."
  (let* ((a (package-desc-create :name 'alpha :version '(1 0)))
         (b (package-desc-create :name 'beta :version '(2 0)))
         (output (elpacman-test-with-output
                   (elpacman--preview (list a b) "Total Installed Size:" 2048))))
    (should (string-search "Packages (2)" output))
    (should (string-search "alpha-1.0" output))
    (should (string-search "beta-2.0" output))
    (should (string-search "Total Installed Size:" output))))

;;;; Unit tests: info helpers

(ert-deftest elpacman-test-format-people ()
  "`elpacman--format-people' renders name and email, or just name."
  (should (equal (elpacman--format-people '(("Ada" . "ada@example.com")))
                 "Ada <ada@example.com>"))
  (should (equal (elpacman--format-people '(("Ada" . "ada@example.com")
                                            ("Bab" . "bab@example.com")))
                 "Ada <ada@example.com>, Bab <bab@example.com>"))
  ;; Missing or empty email falls back to just the name.
  (should (equal (elpacman--format-people '(("Ada" . ""))) "Ada"))
  (should (equal (elpacman--format-people '(("Ada"))) "Ada"))
  ;; Empty input yields nil, so callers can substitute a placeholder.
  (should-not (elpacman--format-people nil)))

(ert-deftest elpacman-test-extra ()
  "`elpacman--extra' reads a keyword from a package's extras alist."
  (let ((desc (package-desc-create :name 'demo :version '(1 0)
                                   :extras '((:url . "https://example.com")))))
    (should (equal (elpacman--extra desc :url) "https://example.com"))
    (should-not (elpacman--extra desc :missing))
    (should-not (elpacman--extra nil :url))))

(ert-deftest elpacman-test-required-by ()
  "`elpacman--required-by' finds installed packages that depend on NAME.
The installed set is stubbed via a let-bound `package-alist'."
  (let ((package-alist
         (list (list 'foo (package-desc-create
                           :name 'foo :version '(1 0)
                           :reqs '((bar (1 0)))))
               (list 'baz (package-desc-create
                           :name 'baz :version '(1 0)
                           :reqs '((bar (1 0)) (qux (1 0)))))
               (list 'lonely (package-desc-create
                              :name 'lonely :version '(1 0) :reqs nil)))))
    (should (equal (elpacman--required-by 'bar) '(baz foo)))
    (should (equal (elpacman--required-by 'qux) '(baz)))
    (should-not (elpacman--required-by 'nobody))))

;;;; Unit tests: completions

(ert-deftest elpacman-test-completions-requires-shell ()
  "Requesting completions with no shell returns 2."
  (let ((output (elpacman-test-with-output
                  (should (equal (elpacman-cmd-completions nil) 2)))))
    (should (string-search "requires a shell" output))))

(ert-deftest elpacman-test-completions-unsupported-shell ()
  "An unsupported shell returns 2 and reports an error."
  (let ((output (elpacman-test-with-output
                  (should (equal (elpacman-cmd-completions '("fish")) 2)))))
    (should (string-search "unsupported shell" output))))

(ert-deftest elpacman-test-completions-bash ()
  "The Bash completion script mentions the commands and options."
  (let ((output (elpacman-test-with-output
                  (should (equal (elpacman-cmd-completions '("bash")) 0)))))
    (should (string-search "complete -F _elpacman elpacman" output))
    (should (string-search "install" output))
    (should (string-search "--vc" output))
    (should (string-search "--yes" output))
    ;; Every user-facing command must appear in the command list.
    (dolist (name (elpacman--completion-command-names))
      (should (string-search name output)))))

(ert-deftest elpacman-test-completions-zsh ()
  "The Zsh completion script is a compdef mentioning the commands."
  (let ((output (elpacman-test-with-output
                  (should (equal (elpacman-cmd-completions '("zsh")) 0)))))
    (should (string-prefix-p "#compdef elpacman" output))
    (should (string-search "_describe" output))
    (should (string-search "install" output))))

(ert-deftest elpacman-test-completions-zsh-quote ()
  "Single quotes and backticks are removed for safe Zsh embedding."
  (should (equal (elpacman--zsh-quote "Alias for `delete'") "Alias for delete"))
  (should (equal (elpacman--zsh-quote "plain") "plain")))

(ert-deftest elpacman-test-command-options ()
  "`elpacman--command-options' combines global and command-specific options."
  ;; A confirming command with a specific option offers both.
  (let ((opts (mapcar #'car (elpacman--command-options "install"))))
    (should (member "--yes" opts))
    (should (member "--vc" opts)))
  ;; A read-only command offers no options.
  (should-not (elpacman--command-options "list"))
  ;; A confirming command with no specific option offers the global ones.
  (let ((opts (mapcar #'car (elpacman--command-options "delete"))))
    (should (member "--yes" opts))
    (should-not (member "--vc" opts))))

;;;; Integration tests

(defvar elpacman-test-archive
  '(("gnu" . "https://elpa.gnu.org/packages/"))
  "The archive used by the integration tests.")

(defvar elpacman-test-package "sml-mode"
  "A small, dependency-light package used by the integration tests.")

(defmacro elpacman-test-with-sandbox (&rest body)
  "Evaluate BODY with a throw-away package directory and archive set.
The package system is re-initialized against a temporary directory, and
`custom-file' is pointed at a file inside it, so that the integration
tests exercise the real customization-saving path without ever touching
the user's configuration."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "elpacman-test-" t))
          (package-user-dir (expand-file-name "elpa" dir))
          (custom-file (expand-file-name "custom.el" dir))
          (package-archives elpacman-test-archive)
          (package-alist nil)
          (package-selected-packages nil)
          (package-archive-contents nil))
     (unwind-protect
         (progn
           (make-directory package-user-dir t)
           (package-initialize)
           ,@body)
       (delete-directory dir t))))

(defun elpacman-test-file-balanced-p (file)
  "Return non-nil when FILE is balanced Emacs Lisp all the way to its end."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (progn (skip-chars-forward " \t\n") (not (eobp)))
          (forward-sexp))
        t)
    (error nil)))

(defun elpacman-test-integration-p ()
  "Return non-nil when the integration suite should run."
  (let ((flag (getenv "ELPACMAN_INTEGRATION")))
    (and flag (not (string-empty-p flag)))))

(ert-deftest elpacman-test-integration-install-and-delete ()
  "Install a real package, confirm it, then delete it again.
Both operations assume yes, so no confirmation prompt is issued."
  (skip-unless (elpacman-test-integration-p))
  (elpacman-test-with-sandbox
    (let ((elpacman--assume-yes t))
      (elpacman-test-with-output
        (package-refresh-contents)
        ;; Install.
        (should (equal (elpacman-cmd-install (list elpacman-test-package)) 0))
        (should (package-installed-p (intern elpacman-test-package)))
        ;; A second install is a no-op that still succeeds.
        (should (equal (elpacman-cmd-install (list elpacman-test-package)) 0))
        ;; Delete.
        (should (equal (elpacman-cmd-delete (list elpacman-test-package)) 0))
        (should-not (package-installed-p (intern elpacman-test-package)))))))

(ert-deftest elpacman-test-integration-delete-keeps-custom-file-valid ()
  "Deleting a package rewrites `custom-file' without corrupting it.
This reproduces the scenario where `package-delete' saves the updated
`package-selected-packages' through `custom-save-all', which writes with
`princ'.  The progress capture must not hijack those writes and leave
the file with unbalanced parentheses."
  (skip-unless (elpacman-test-integration-p))
  (elpacman-test-with-sandbox
    (let ((elpacman--assume-yes t)
          (name (intern elpacman-test-package)))
      ;; Seed a real, valid custom-file that lists the package as
      ;; selected, so that deleting it exercises the save path.  We write
      ;; it by hand because `customize-save-variable' refuses to persist
      ;; under `emacs -Q'.
      (with-temp-file custom-file
        (insert (format "(custom-set-variables\n '(package-selected-packages '(%s)))\n"
                        elpacman-test-package)))
      (load custom-file)
      (should (elpacman-test-file-balanced-p custom-file))
      (elpacman-test-with-output
        (package-refresh-contents)
        (should (equal (elpacman-cmd-install (list elpacman-test-package)) 0))
        ;; Delete, which triggers the customization save path.
        (should (equal (elpacman-cmd-delete (list elpacman-test-package)) 0))
        (should-not (package-installed-p name))
        ;; The custom-file must remain valid, balanced Emacs Lisp.
        (should (elpacman-test-file-balanced-p custom-file))))))

(ert-deftest elpacman-test-integration-install-reports-size ()
  "Install and delete show pacman-style size lines and progress."
  (skip-unless (elpacman-test-integration-p))
  (elpacman-test-with-sandbox
    (let ((elpacman--assume-yes t))
      (let ((output (elpacman-test-with-output
                      (package-refresh-contents)
                      (elpacman-cmd-install (list elpacman-test-package)))))
        (should (string-search "Packages (1)" output))
        (should (string-search "installing sml-mode" output)))
      (let ((output (elpacman-test-with-output
                      (elpacman-cmd-delete (list elpacman-test-package)))))
        (should (string-search "Total Removed Size:" output))
        (should (string-search "removing sml-mode" output))))))

(ert-deftest elpacman-test-integration-install-aborts-without-confirmation ()
  "A non-interactive install without assume-yes aborts and installs nothing."
  (skip-unless (elpacman-test-integration-p))
  (elpacman-test-with-sandbox
    (let ((elpacman--assume-yes nil)
          (process-environment (cons "ELPACMAN_TTY=" process-environment)))
      (elpacman-test-with-output
        (package-refresh-contents)
        (should-error (elpacman-cmd-install (list elpacman-test-package))
                      :type 'elpacman-aborted)
        (should-not (package-installed-p (intern elpacman-test-package)))))))

(ert-deftest elpacman-test-integration-install-aborts-on-missing-target ()
  "If any named target is not found, install nothing and return 1.
A valid package listed alongside an unknown one must not be installed:
the whole transaction is aborted up front, in the manner of `pacman -S'."
  (skip-unless (elpacman-test-integration-p))
  (elpacman-test-with-sandbox
    (let ((elpacman--assume-yes t)
          (valid elpacman-test-package)
          (bogus "elpacman-no-such-package-xyz"))
      (let ((output (elpacman-test-with-output
                      (package-refresh-contents)
                      (should (equal (elpacman-cmd-install (list valid bogus)) 1)))))
        ;; The unknown target is reported ...
        (should (string-search "target not found" output))
        (should (string-search bogus output))
        ;; ... and nothing was installed, not even the valid package.
        (should-not (package-installed-p (intern valid)))))))

(ert-deftest elpacman-test-integration-delete-missing ()
  "Deleting a package that is not installed returns 1."
  (skip-unless (elpacman-test-integration-p))
  (elpacman-test-with-sandbox
    (let ((elpacman--assume-yes t))
      (elpacman-test-with-output
        (should (equal (elpacman-cmd-delete '("definitely-not-installed")) 1))))))

(ert-deftest elpacman-test-integration-search ()
  "Searching the archive for a known package finds it."
  (skip-unless (elpacman-test-integration-p))
  (elpacman-test-with-sandbox
    (package-refresh-contents)
    (let ((output (elpacman-test-with-output
                    (should (equal (elpacman-cmd-search
                                    (list elpacman-test-package))
                                   0)))))
      (should (string-search elpacman-test-package output)))))

(ert-deftest elpacman-test-integration-update ()
  "The `update' sub-command refreshes the database and returns 0."
  (skip-unless (elpacman-test-integration-p))
  (elpacman-test-with-sandbox
    (elpacman-test-with-output
      (should (equal (elpacman-cmd-update nil) 0))
      (should package-archive-contents))))

(ert-deftest elpacman-test-integration-check-clean ()
  "A freshly installed package reports no problems."
  (skip-unless (elpacman-test-integration-p))
  (elpacman-test-with-sandbox
    (let ((elpacman--assume-yes t))
      (elpacman-test-with-output
        (package-refresh-contents)
        (elpacman-cmd-install (list elpacman-test-package))
        (should (equal (elpacman-cmd-check nil) 0))))))

(provide 'test-elpacman)

;;; test-elpacman.el ends here
