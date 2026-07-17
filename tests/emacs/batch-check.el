;;; batch-check.el --- Isolated ERT checks for GuixPC Emacs -*- lexical-binding: t; -*-

;;; Commentary:

;; These checks run after a copied init has loaded under an isolated HOME and
;; isolated XDG directories.  Fixture buffers run their real major-mode hooks;
;; LSP startup is replaced only while those hooks are observed so no language
;; server can escape the batch process.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'checkdoc)
(require 'server)

(defconst sk/check-source-root
  (file-name-as-directory
   (or (getenv "SK_EMACS_CHECK_SOURCE_ROOT")
       (error "SK_EMACS_CHECK_SOURCE_ROOT is required")))
  "Copied source tree used by the isolated batch check.")

(defconst sk/check-original-repo
  (file-name-as-directory
   (or (getenv "SK_EMACS_CHECK_ORIGINAL_REPO")
       (error "SK_EMACS_CHECK_ORIGINAL_REPO is required")))
  "Read-only original checkout used for validation metadata.")

(defconst sk/check-real-home
  (file-name-as-directory
   (or (getenv "SK_EMACS_CHECK_REAL_HOME")
       (error "SK_EMACS_CHECK_REAL_HOME is required")))
  "Real user home that must not own batch state or package paths.")

(defvar fennel-proto-repl--message-buf)

(defun sk/check-fixture-path (relative)
  "Return the copied fixture path for RELATIVE."
  (expand-file-name (concat "fixtures/" relative) sk/check-source-root))

(defun sk/check-with-fixture (relative function)
  "Visit copied fixture RELATIVE in a temporary buffer and call FUNCTION."
  (let ((file (sk/check-fixture-path relative)))
    (should (file-readable-p file))
    (with-temp-buffer
      ;; Mirror `find-file' closely enough for project-root hooks: a temporary
      ;; buffer does not otherwise update `default-directory' when only
      ;; `buffer-file-name' is assigned.
      (setq buffer-file-name file
            default-directory (file-name-directory file))
      (insert-file-contents file)
      (set-auto-mode)
      (funcall function))))

(defun sk/check-lsp-fixture (relative expected-mode)
  "Assert RELATIVE enters EXPECTED-MODE and runs the real LSP hook."
  (let ((lsp-deferred-called nil))
    (cl-letf (((symbol-function 'lsp-deferred)
               (lambda () (setq lsp-deferred-called t))))
      (sk/check-with-fixture
       relative
       (lambda ()
         (should (eq major-mode expected-mode))
         (should-not (memq #'sk/format-buffer before-save-hook)))))
    (should lsp-deferred-called)))

(defun sk/check-call-mode-without-lsp (mode)
  "Call MODE while observing, but not starting, its deferred LSP hook."
  (cl-letf (((symbol-function 'lsp-deferred) #'ignore))
    (funcall mode)))

(defun sk/check-canonical-directory (directory)
  "Return DIRECTORY as a canonical directory name."
  (file-name-as-directory (file-truename directory)))

(defun sk/check-with-eldoc-fixture (relative function)
  "Run RELATIVE hooks, call FUNCTION, and verify they enable Eldoc."
  (let ((eldoc-calls nil)
        (original-eldoc-mode (symbol-function 'eldoc-mode)))
    (cl-letf (((symbol-function 'eldoc-mode)
               (lambda (&optional argument)
                 (push argument eldoc-calls)
                 (funcall original-eldoc-mode argument))))
      (sk/check-with-fixture relative function))
    (should (memq 1 eldoc-calls))))

(defun sk/check-lisp-runtime-process-p (process)
  "Return non-nil when PROCESS is a configured Lisp runtime or server."
  (seq-some (lambda (argument)
              (string-match-p
               "\\(?:^\\|/\\)\\(?:guile\\|sbcl\\|java\\|clojure-lsp\\|racket\\|raco\\|racket-project\\|fennel\\|fennel-ls\\|fennel-project\\|fnlfmt\\)\\'"
                              argument))
            (or (process-command process) '())))

(defun sk/check-puni-contract-in-mode (mode)
  "Check the reviewed structural-editing contract after enabling MODE."
  (with-temp-buffer
    (insert "(alpha) beta")
    (funcall mode)
    (should (bound-and-true-p puni-mode))
    (goto-char 3)
    (let ((puni-blink-for-sexp-manipulating nil))
      (puni-slurp-forward 1))
    (should (equal (buffer-string) "(alpha beta)"))
    (check-parens)
    (evil-normal-state)
    (should (eq (key-binding (kbd "j")) #'evil-next-visual-line))
    (should (eq (key-binding (kbd "k")) #'evil-previous-visual-line))))

(defun sk/check-puni-org-source-edit (language expected-mode)
  "Check Puni in an Org LANGUAGE editor using EXPECTED-MODE."
  (let ((origin (generate-new-buffer " *sk-org-src-structural*"))
        edit-buffer)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer origin)
          (org-mode)
          (insert (format "#+begin_src %s\n(alpha) beta\n#+end_src\n"
                          language))
          (goto-char (point-min))
          (search-forward "alpha")
          (let ((org-src-window-setup 'current-window))
            (org-edit-special))
          (setq edit-buffer (current-buffer))
          (should (eq major-mode expected-mode))
          (should (bound-and-true-p org-src-mode))
          (should (bound-and-true-p puni-mode))
          (goto-char (point-min))
          (search-forward "alpha")
          (goto-char (match-beginning 0))
          (let ((puni-blink-for-sexp-manipulating nil))
            (puni-slurp-forward 1))
          (check-parens)
          (evil-normal-state)
          (should (eq (key-binding (kbd "j")) #'evil-next-visual-line))
          (org-edit-src-exit)
          (should (eq (current-buffer) origin))
          (goto-char (point-min))
          (should (search-forward "(alpha beta)" nil t)))
      (when (buffer-live-p edit-buffer)
        (kill-buffer edit-buffer))
      (when (buffer-live-p origin)
        (kill-buffer origin)))))

(ert-deftest sk/check-isolated-runtime-state ()
  (should noninteractive)
  (let* ((home-profile
          (file-name-as-directory
           (or (getenv "SK_EMACS_CHECK_HOME_PROFILE")
               (error "SK_EMACS_CHECK_HOME_PROFILE is required"))))
         (system-profile
          (file-name-as-directory
           (or (getenv "SK_EMACS_CHECK_SYSTEM_PROFILE")
               (error "SK_EMACS_CHECK_SYSTEM_PROFILE is required"))))
         (expected-emacs
          (or (getenv "SK_EMACS_CHECK_BATCH_EMACS")
              (error "SK_EMACS_CHECK_BATCH_EMACS is required")))
         (candidate-load-path
          (concat (expand-file-name "share/emacs/site-lisp" home-profile)
                  ":"
                  (expand-file-name "share/emacs/site-lisp" system-profile)
                  ":")))
    (should
     (file-equal-p
      (expand-file-name invocation-name invocation-directory)
      expected-emacs))
    (should (string-prefix-p candidate-load-path
                             (or (getenv "EMACSLOADPATH") ""))))
  (should (file-in-directory-p (file-truename user-emacs-directory)
                               (file-truename (getenv "HOME"))))
  (should (file-in-directory-p (file-truename sk/cache-directory)
                               (file-truename (getenv "XDG_CACHE_HOME"))))
  (should (file-in-directory-p (file-truename sk/org-notes-root)
                               (file-truename (getenv "HOME"))))
  (should-not (bound-and-true-p recentf-mode))
  (should-not (bound-and-true-p savehist-mode))
  (should-not (bound-and-true-p save-place-mode))
  (should-not (and (boundp 'server-process)
                   (processp server-process)
                   (process-live-p server-process)))
  (dolist (file (list recentf-save-file savehist-file save-place-file))
    (should-not (file-exists-p file)))
  (dolist (file (list projectile-known-projects-file
                      projectile-frecency-file))
    (should (file-in-directory-p (file-truename (file-name-directory file))
                                 (file-truename sk/cache-directory))))
  (should-not (file-exists-p sk/org-notes-root))
  (should-not
   (catch 'real-user-package
     (dolist (entry load-path)
       (when (and entry
                  (file-in-directory-p (expand-file-name entry)
                                       sk/check-real-home)
                  (string-match-p "/\\.emacs\\.d/elpa/" entry))
         (throw 'real-user-package entry)))
     nil))
  (should-not (locate-library "breadcrumb"))
  (should-not (and (boundp 'package-alist)
                   (assq 'breadcrumb package-alist)))
  (dolist (entry load-path)
    (when entry
      (let ((canonical (file-truename entry)))
        (should (or (string-prefix-p "/gnu/store/" canonical)
                    (string-prefix-p sk/check-sandbox-root canonical)))))))

(ert-deftest sk/check-preactivation-theme-fallback ()
  "A missing or mutable Home adapter must preserve the legacy source result."
  (should-not (featurep 'sk-theme-generated))
  (should (equal sk/legacy-fixed-font-family "Iosevka Term"))
  (let (default-face-arguments)
    (cl-letf (((symbol-function 'set-face-attribute)
               (lambda (face frame &rest arguments)
                 (when (eq face 'default)
                   (setq default-face-arguments
                         (cons frame arguments)))))
              ((symbol-function 'display-graphic-p)
               (lambda (&optional _display) nil)))
      (sk/setup-fonts))
    (should
     (equal default-face-arguments
            (list nil
                  :family sk/legacy-fixed-font-family
                  :height 120))))
  (should-not (file-readable-p sk/theme-generated-file))
  (let ((mutable-adapter
         (expand-file-name "mutable-theme.el" temporary-file-directory)))
    (unwind-protect
        (progn
          (with-temp-file mutable-adapter
            (insert "(provide 'sk-theme-generated)\n"))
          (should-not (sk/immutable-store-file-p mutable-adapter)))
      (when (file-exists-p mutable-adapter)
        (delete-file mutable-adapter)))))

(ert-deftest sk/check-profile-keyed-native-comp-and-org-generation ()
  (let* ((profile-link
          (expand-file-name ".guix-home/profile" (getenv "HOME")))
         (resolved-profile
          (sk/check-canonical-directory profile-link))
         (expected-key
          (file-name-nondirectory
           (directory-file-name resolved-profile)))
         (expected-cache
          (expand-file-name
           (concat "emacs/eln-cache/" expected-key "/")
           (getenv "XDG_CACHE_HOME")))
         (legacy-cache
          (expand-file-name "eln-cache/" user-emacs-directory))
         (home-site-lisp
          (expand-file-name "share/emacs/site-lisp" profile-link))
         (org-package
          (car (file-expand-wildcards
                (expand-file-name "org-[0-9]*" home-site-lisp) t)))
         (org-library (locate-library "org"))
         (org-source
          (and org-library
               (if (string-suffix-p ".elc" org-library)
                   (string-remove-suffix "c" org-library)
                 org-library)))
         (expected-org-version
          (and org-package
               (string-remove-prefix
                "org-"
                (file-name-nondirectory
                 (directory-file-name org-package))))))
    (should (boundp 'sk/native-comp-profile-key))
    (should (boundp 'sk/native-comp-cache-directory))
    (should (boundp 'sk/native-comp-legacy-cache-directory))
    (should (equal sk/native-comp-profile-key expected-key))
    (should (equal (sk/native-comp--cache-key) expected-key))
    (should (equal
             (sk/check-canonical-directory sk/native-comp-cache-directory)
             (sk/check-canonical-directory expected-cache)))
    (should (equal
             (sk/check-canonical-directory
              sk/native-comp-legacy-cache-directory)
             (sk/check-canonical-directory legacy-cache)))
    (should native-comp-eln-load-path)
    (should (equal
             (sk/check-canonical-directory
              (car native-comp-eln-load-path))
             (sk/check-canonical-directory expected-cache)))
    (should-not
     (seq-some
      (lambda (entry)
        (and entry
             (equal (sk/check-canonical-directory entry)
                    (sk/check-canonical-directory legacy-cache))))
      native-comp-eln-load-path))
    ;; Redirection may add only the selected cache and remove only the legacy
    ;; fallback.  Every immutable native-site entry must survive byte-for-byte
    ;; and in its original order.
    (should
     (equal
      (cdr native-comp-eln-load-path)
      (seq-remove
       (lambda (entry)
         (and entry
              (equal (sk/check-canonical-directory entry)
                     (sk/check-canonical-directory legacy-cache))))
       sk/check-native-comp-eln-load-path-before-early-init)))
    (should
     (seq-some
      (lambda (entry)
        (and entry
             (string-prefix-p
              "/gnu/store/"
              (sk/check-canonical-directory entry))))
      (cdr native-comp-eln-load-path)))
    (should org-package)
    (should org-library)
    (should
     (file-in-directory-p (file-truename org-library)
                          (sk/check-canonical-directory org-package)))
    (should (equal (org-version) expected-org-version))
    (should-not (boundp 'sk/check-stale-org-native-code))
    (require 'comp)
    (let ((native-comp-eln-load-path (list legacy-cache)))
      (should
       (file-equal-p (comp-lookup-eln org-source)
                     sk/check-stale-org-eln)))
    (should-not
     (let ((selected (comp-lookup-eln org-source)))
       (and selected
            (file-equal-p selected sk/check-stale-org-eln))))
    ;; Exercise the real recovery branch against an absent profile without
    ;; disturbing the production-parity profile link used by the rest of the
    ;; suite.
    (let ((missing-profile
           (expand-file-name ".guix-home/missing-profile" (getenv "HOME"))))
      (should-not (sk/native-comp--profile-key missing-profile))
      (should
       (equal (sk/native-comp--cache-key missing-profile)
              (sk/native-comp--running-emacs-key))))
    (should-not
     (seq-some
      (lambda (record)
        (string-match-p "Org version mismatch"
                        (format "%s" (nth 1 record))))
      sk/check-warning-records))))

(ert-deftest sk/check-lsp-hooks-and-shared-policy ()
  (sk/check-lsp-fixture "c/hello.c" 'c-mode)
  (sk/check-lsp-fixture "python/sample.py" 'python-mode)
  (sk/check-lsp-fixture "lua/sample.lua" 'lua-mode)
  (require 'lsp-mode)
  (should (eq lsp-completion-provider :capf))
  (should (eq lsp-diagnostics-provider :auto))
  (should (memq #'flycheck-mode lsp-mode-hook))
  (should (memq #'lsp-ui-mode lsp-mode-hook))
  (should (memq #'lsp-enable-which-key-integration lsp-mode-hook))
  (should (equal lsp-clients-clangd-executable "clangd"))
  (should (equal lsp-pylsp-server-command '("pylsp")))
  (should (equal lsp-pylsp-configuration-sources ["flake8"]))
  (should lsp-pylsp-plugins-jedi-completion-enabled)
  (should lsp-pylsp-plugins-jedi-hover-enabled)
  (should lsp-pylsp-plugins-jedi-references-enabled)
  (should lsp-pylsp-plugins-pyflakes-enabled)
  (should lsp-pylsp-plugins-flake8-enabled)
  (should (equal lsp-clients-lua-language-server-command
                 '("lua-language-server")))
  (should-not lsp-lua-telemetry-enable)
  (let ((expected
         (list (expand-file-name "scripts/guix-lisp-shell"
                                sk/check-source-root)
               "jvm" "--"
               (expand-file-name "scripts/clojure-project"
                                 sk/check-source-root)
               "lsp")))
    (should (equal lsp-clojure-custom-server-command expected))
    (require 'lsp-clojure)
    (should (equal (lsp-clojure--build-command) expected)))
  (sk/check-with-fixture
   "fennel/src/sk/fixture/main.fnl"
   (lambda ()
     (let ((expected
            (list sk/fennel-project-wrapper "--project"
                  (file-name-as-directory
                   (sk/check-fixture-path "fennel"))
                  "lsp")))
       (require 'lsp-fennel)
       (should (equal (sk/fennel--lsp-command) expected))
       (should (equal (lsp-fennel--ls-command) expected)))))
  (should (equal company-backends
                 '((company-capf company-yasnippet)
                   company-files
                   company-keywords
                   company-dabbrev-code))))

(ert-deftest sk/check-flycheck-hooks ()
  (sk/check-with-fixture
   "shell/sample.sh"
   (lambda ()
     (should (eq major-mode 'sh-mode))
     (should (bound-and-true-p flycheck-mode))
     (should (eq (flycheck-get-checker-for-buffer) 'sh-posix-bash))
     (should (equal (flycheck-get-next-checkers 'sh-posix-bash)
                    '(sh-shellcheck)))))
  (sk/check-with-fixture
   "json/sample.json"
   (lambda ()
     (should (memq major-mode '(json-mode js-json-mode)))
     (should (bound-and-true-p flycheck-mode))
     (should (eq flycheck-checker 'json-jq))))
  (sk/check-with-fixture
   "json/sample.jsonc"
   (lambda ()
     (should (eq major-mode 'jsonc-mode))
     (should-not (bound-and-true-p flycheck-mode))
     (should-not flycheck-checker))))

(ert-deftest sk/check-org-lint-flycheck-compatibility ()
  (require 'org-lint)
  (should (equal flycheck-version "36.0"))
  (should (eq (flycheck-checker-get 'org-lint 'error-filter)
              #'sk/flycheck-org-lint-filter))
  (with-temp-buffer
    (insert "* One\n"
            ":PROPERTIES:\n"
            ":CUSTOM_ID: duplicate\n"
            ":END:\n\n"
            "* Two\n"
            ":PROPERTIES:\n"
            ":CUSTOM_ID: duplicate\n"
            ":END:\n")
    (org-mode)
    (let (status errors)
      (funcall
       (flycheck-checker-get 'org-lint 'start)
       'org-lint
       (lambda (new-status new-errors)
         (setq status new-status
               errors new-errors)))
      (should (eq status 'finished))
      (should (= 2 (length errors)))
      (should (equal (mapcar #'flycheck-error-line errors)
                     '("3" "8")))
      (dolist (lint-error errors)
        (let ((line (flycheck-error-line lint-error)))
          (should (stringp line))
          (should (markerp (get-text-property 0 'org-lint-marker line)))))
      (let ((objects (copy-sequence errors))
            (messages (mapcar #'flycheck-error-message errors)))
        (should (eq errors (flycheck-filter-errors errors 'org-lint)))
        (should (equal (mapcar #'flycheck-error-line errors) '(3 8)))
        (should (equal (mapcar #'flycheck-error-message errors) messages))
        (should (equal (mapcar #'flycheck-error-level errors)
                       '(info info)))
        (should (equal (mapcar #'flycheck-error-checker errors)
                       '(org-lint org-lint)))
        (cl-mapc (lambda (before after) (should (eq before after)))
                 objects errors)
        (should (eq errors (flycheck-filter-errors errors 'org-lint)))
        (should (equal (mapcar #'flycheck-error-line errors) '(3 8))))))
  (let* ((valid
          (flycheck-error-new-at
           4 nil 'info "Valid fixture" :checker 'org-lint))
         (zero
          (flycheck-error-new-at
           (propertize "0" 'org-lint-marker 'fixture)
           nil 'info "Zero fixture" :checker 'org-lint))
         (malformed
          (flycheck-error-new-at
           (propertize "oops" 'org-lint-marker 'fixture)
           nil 'info "Malformed fixture" :checker 'org-lint))
         (errors (list valid zero malformed)))
    (should (eq errors (flycheck-filter-errors errors 'org-lint)))
    (should (= 4 (flycheck-error-line valid)))
    (should (eq 'info (flycheck-error-level valid)))
    (dolist (lint-error (list zero malformed))
      (should (= 1 (flycheck-error-line lint-error)))
      (should (eq 'warning (flycheck-error-level lint-error)))
      (should (string-prefix-p "Unexpected org-lint line"
                               (flycheck-error-message lint-error))))
    (let ((messages (mapcar #'flycheck-error-message errors)))
      (should (eq errors (flycheck-filter-errors errors 'org-lint)))
      (should (equal messages (mapcar #'flycheck-error-message errors))))))

(ert-deftest sk/check-lisp-hooks-and-backends ()
  (sk/check-with-eldoc-fixture
   "elisp/sample.el"
   (lambda ()
     (should (eq major-mode 'emacs-lisp-mode))
     (should (eq (local-key-binding (kbd "C-c C-b")) #'eval-buffer))
     (should (bound-and-true-p puni-mode))
     (should (eq (sk/lisp--dialect) 'elisp))))
  (sk/check-with-eldoc-fixture
   "scheme/sample.scm"
   (lambda ()
     (should (eq major-mode 'scheme-mode))
     (should (bound-and-true-p geiser-mode))
     (should (bound-and-true-p puni-mode))
     (should (bound-and-true-p company-mode))
     (should (eq (car company-backends) 'company-capf))
     (dolist (function '(geiser-capf--for-filename
                         geiser-capf--for-module
                         geiser-capf--for-symbol))
       (should (memq function completion-at-point-functions)))
     (should (equal scheme-program-name "guile"))
     (should (eq geiser-repl-current-project-function
                 #'sk/lisp--project-root))
     (should geiser-repl-per-project-p)
     (should (equal geiser-repl-add-project-paths '("." "src")))
     (should (eq (sk/lisp--dialect) 'scheme))))
  (sk/check-with-eldoc-fixture
   "common-lisp/sample.lisp"
   (lambda ()
     (should (eq major-mode 'lisp-mode))
     (should (bound-and-true-p puni-mode))
     (should (bound-and-true-p sly-editing-mode))
     (should (bound-and-true-p sly-mode))
     (should (eq lisp-indent-function #'sly--lisp-indent-function))
     (should (fboundp 'sly-common-lisp-indent-function))
     (should (equal inferior-lisp-program "sbcl"))
     (should (fboundp 'sly))
     (should-not (sly-connected-p))
     (should (eq (sk/lisp--dialect) 'common-lisp))))
  (dolist (extension '("cl" "asd"))
    (sk/check-with-eldoc-fixture
     (concat "common-lisp/sample." extension)
     (lambda () (should (eq major-mode 'lisp-mode)))))
  (sk/check-with-eldoc-fixture
   "racket/src/sk/fixture/main.rkt"
   (lambda ()
     (should (eq major-mode 'racket-mode))
     (should (eq (sk/lisp--dialect) 'racket))
     (should (bound-and-true-p puni-mode))
     (should (bound-and-true-p company-mode))
     (should-not (bound-and-true-p racket-xp-mode))
     (should sk/racket-project-root)
     (let ((configuration
            (sk/racket--backend-configuration sk/racket-project-root)))
       (should configuration)
       (should
        (equal (plist-get configuration :racket-program)
               (sk/racket--backend-command sk/racket-project-root))))))
  (sk/check-with-eldoc-fixture
   "fennel/src/sk/fixture/main.fnl"
   (lambda ()
     (should (eq major-mode 'fennel-mode))
     (should (eq (sk/lisp--dialect) 'fennel))
     (should (bound-and-true-p puni-mode))
     (should (bound-and-true-p company-mode))
     (should-not (bound-and-true-p fennel-proto-repl-minor-mode))
     (should-not (bound-and-true-p lsp-mode))
     (should sk/fennel-project-root)
     (should-not (sk/fennel--live-repl-buffer sk/fennel-project-root))))
  (dolist (case '((inferior-emacs-lisp-mode . elisp)
                  (geiser-repl-mode . scheme)
                  (sly-mrepl-mode . common-lisp)
                  (sk/clojure-repl-mode . clojure)
                  (racket-repl-mode . racket)
                  (fennel-proto-repl-mode . fennel)))
    (with-temp-buffer
      ;; Do not start a runtime merely to verify the global leader dispatcher
      ;; recognizes its already-connected REPL modes.
      (setq major-mode (car case))
      (should (eq (sk/lisp--dialect) (cdr case))))))

(ert-deftest sk/check-clojure-editing-and-static-lint-contract ()
  (let ((lsp-called nil))
    (cl-letf (((symbol-function 'lsp-deferred)
               (lambda () (setq lsp-called t))))
      (sk/check-with-eldoc-fixture
       "clojure/src/sk/fixture/core.clj"
       (lambda ()
         (should (eq major-mode 'clojure-mode))
         (should (eq (sk/lisp--dialect) 'clojure))
         (should (bound-and-true-p puni-mode))
         (should (bound-and-true-p company-mode))
         (should (bound-and-true-p flycheck-mode))
         (should (eq flycheck-checker 'sk-clojure-clj-kondo))
         (should (eq (flycheck-get-checker-for-buffer)
                     'sk-clojure-clj-kondo))
         (should
          (file-equal-p
           (funcall
            (flycheck-checker-get
             'sk-clojure-clj-kondo 'working-directory)
            'sk-clojure-clj-kondo)
           (sk/check-fixture-path "clojure"))))))
    (should-not lsp-called))
  (should-not (memq #'lsp-deferred clojure-mode-hook))
  (should (= 1 (cl-count #'sk/clojure-mode-setup clojure-mode-hook
                          :test #'eq)))
  (should (= 1 (cl-count #'puni-mode clojure-mode-hook :test #'eq)))
  (let ((command
         (flycheck-checker-get 'sk-clojure-clj-kondo 'command)))
    (should (equal (seq-take command 7)
                   '("clj-kondo" "--repro" "--cache" "false"
                     "--lint" "-" "--filename")))
    (should (flycheck-checker-get 'sk-clojure-clj-kondo
                                  'standard-input)))
  (should (file-equal-p sk/clojure-repository-directory
                        sk/check-source-root))
  (should-not (seq-some #'sk/check-lisp-runtime-process-p (process-list))))

(ert-deftest sk/check-racket-editing-and-runtime-detachment-contract ()
  (should (file-equal-p sk/racket-repository-directory
                        sk/check-source-root))
  (should (file-executable-p sk/racket-project-wrapper))
  (should (equal racket-program
                 (list sk/racket-project-wrapper
                       "--project" "." "backend")))
  (should (= 1 (cl-count #'sk/racket-mode-setup racket-mode-hook
                          :test #'eq)))
  (should (= 1 (cl-count #'puni-mode racket-mode-hook :test #'eq)))
  (should-not (memq #'racket-xp-mode racket-mode-hook))
  (dolist (directory (list racket-doc-index-directory
                           racket-repl-history-directory))
    (should (file-in-directory-p (file-truename directory)
                                 (file-truename sk/cache-directory))))
  (should (file-in-directory-p
           (file-truename (file-name-directory racket-repl-command-file))
           (file-truename sk/cache-directory)))
  (sk/check-with-fixture
   "racket/src/sk/fixture/main.rkt"
   (lambda ()
     (should (eq major-mode 'racket-mode))
     (should-not (bound-and-true-p racket-xp-mode))
     (should-not (sk/racket--backend-process sk/racket-project-root))
     (should-not (sk/racket--live-repl-buffer sk/racket-project-root))))
  (should-not (seq-some #'sk/check-lisp-runtime-process-p (process-list))))

(ert-deftest sk/check-fennel-editing-and-runtime-detachment-contract ()
  (should (file-equal-p sk/fennel-repository-directory
                        sk/check-source-root))
  (should (file-executable-p sk/fennel-project-wrapper))
  (should (= 1 (cl-count #'sk/fennel-mode-setup fennel-mode-hook
                          :test #'eq)))
  (should (= 1 (cl-count #'puni-mode fennel-mode-hook :test #'eq)))
  (should (= 1 (cl-count #'puni-mode fennel-proto-repl-mode-hook
                          :test #'eq)))
  (should-not (memq #'lsp-deferred fennel-mode-hook))
  (sk/check-with-fixture
   "fennel/src/sk/fixture/main.fnl"
   (lambda ()
     (should (eq major-mode 'fennel-mode))
     (should sk/fennel-project-root)
     (should-not (bound-and-true-p fennel-proto-repl-minor-mode))
     (should-not (bound-and-true-p lsp-mode))
     (should-not (memq #'fennel--xref-backend xref-backend-functions))
     (should-not (sk/fennel--live-repl-buffer sk/fennel-project-root))))
  (with-temp-buffer
    (setq-local sk/fennel-project-root
                (file-name-as-directory (sk/check-fixture-path "fennel")))
    (should-error (sk/fennel-repl) :type 'user-error))
  (should-not (seq-some #'sk/check-lisp-runtime-process-p (process-list))))

(ert-deftest sk/check-fennel-protocol-splitter-edge-cases ()
  (should
   (advice-member-p #'sk/fennel--buffered-split-string
                    #'fennel-proto-repl--buffered-split-string))
  (let ((advice-count 0))
    (advice-mapc
     (lambda (advice _properties)
       (when (eq advice #'sk/fennel--buffered-split-string)
         (setq advice-count (1+ advice-count))))
     #'fennel-proto-repl--buffered-split-string)
    (should (= advice-count 1)))
  (dolist (case '((nil "" nil nil)
                  (nil "\n" nil nil)
                  (nil "one\n" ("one") nil)
                  (nil "one\ntwo" ("one") "two")
                  ("one" "" nil "one")
                  ("one" " continued" nil "one continued")
                  ("one" "\n" ("one") nil)
                  ("one" "\ntwo\n" ("one" "two") nil)
                  ("one" "\ntwo" ("one") "two")
                  ("one" "\n\ntwo\n" ("one" "two") nil)))
    (pcase-let ((`(,initial ,chunk ,expected-lines ,expected-buffer) case))
      (with-temp-buffer
        (setq-local fennel-proto-repl--message-buf initial)
        (should
         (equal
          (fennel-proto-repl--buffered-split-string chunk)
          expected-lines))
        (should
         (equal fennel-proto-repl--message-buf expected-buffer))))))

(ert-deftest sk/check-fennel-protocol-splitter-is-chunking-invariant ()
  (dolist (case '(("(:id 1)\n(:id 2)\n(:id 3)\n"
                   ("(:id 1)" "(:id 2)" "(:id 3)") nil)
                  ("(:id 1)\n(:id 2)\n(:id 3)"
                   ("(:id 1)" "(:id 2)") "(:id 3)")))
    (pcase-let ((`(,payload ,expected-lines ,expected-buffer) case))
      (dotimes (split (1+ (length payload)))
        (with-temp-buffer
          (setq-local fennel-proto-repl--message-buf nil)
          (let ((lines
                 (append
                  (fennel-proto-repl--buffered-split-string
                   (substring payload 0 split))
                  (fennel-proto-repl--buffered-split-string
                   (substring payload split)))))
            (should (equal lines expected-lines))
            (should
             (equal fennel-proto-repl--message-buf expected-buffer))))))))

(ert-deftest sk/check-fennel-keymaps-preserve-project-boundaries ()
  (dolist (binding
           '(("C-c C-z" . sk/fennel-repl)
             ("C-c C-b" . sk/fennel-eval-buffer)
             ("C-c C-e" . sk/fennel-eval-defun)
             ("C-M-x" . sk/fennel-eval-defun)
             ("C-x C-e" . sk/fennel-eval-last-sexp)
             ("C-c C-p" . sk/fennel-macroexpand)
             ("C-c C-t" . sk/fennel-format-buffer)
             ("C-c C-l" . sk/fennel-project-check)
             ("C-c C-f" . sk/fennel-docs)
             ("C-c C-d" . sk/fennel-docs)
             ("C-c C-v" . sk/fennel-docs)
             ("C-c C-q" . sk/fennel-stop)))
    (should (eq (lookup-key fennel-mode-map (kbd (car binding)))
                (cdr binding))))
  (dolist (key '("C-c C-k" "C-c C-n" "C-c C-r"))
    (should-not (lookup-key fennel-mode-map (kbd key))))

  (dolist (binding
           '(("C-c C-z" . sk/fennel-repl)
             ("C-c C-b" . sk/fennel-eval-buffer)
             ("C-c C-e" . sk/fennel-eval-defun)
             ("C-M-x" . sk/fennel-eval-defun)
             ("C-x C-e" . sk/fennel-eval-last-sexp)
             ("C-c C-p" . sk/fennel-macroexpand)
             ("C-c C-t" . sk/fennel-format-buffer)
             ("C-c C-l" . sk/fennel-project-check)
             ("C-c C-f" . sk/fennel-docs)
             ("C-c C-d" . sk/fennel-docs)
             ("C-c C-v" . sk/fennel-docs)
             ("C-c C-a" . sk/fennel-docs)
             ("C-c C-q" . sk/fennel-stop)))
    (should
     (eq (lookup-key fennel-proto-repl-minor-mode-map
                     (kbd (car binding)))
         (cdr binding))))
  (dolist (key '("C-c C-k" "C-c C-n" "C-c C-S-p" "C-c C-r"
                 "C-c C-S-l"))
    (should-not
     (lookup-key fennel-proto-repl-minor-mode-map (kbd key))))

  (should (eq (lookup-key fennel-proto-repl-mode-map (kbd "C-c C-z"))
              #'sk/fennel-repl))
  (should (eq (lookup-key fennel-proto-repl-mode-map (kbd "C-c C-q"))
              #'sk/fennel-stop))

  ;; The protocol minor map has precedence after a project REPL is linked.
  ;; Assert the effective bindings too, so a safe major-map binding cannot hide
  ;; a higher-priority upstream formatter/linker/reload route.
  (sk/check-with-fixture
   "fennel/src/sk/fixture/main.fnl"
   (lambda ()
     (fennel-proto-repl-minor-mode 1)
     (dolist (binding
              '(("C-c C-t" . sk/fennel-format-buffer)
                ("C-c C-l" . sk/fennel-project-check)
                ("C-c C-q" . sk/fennel-stop)
                ("C-c C-z" . sk/fennel-repl)))
       (should (eq (key-binding (kbd (car binding))) (cdr binding))))
     (dolist (key '("C-c C-k" "C-c C-n" "C-c C-S-p" "C-c C-r"
                    "C-c C-S-l"))
       (should-not (key-binding (kbd key)))))))

(ert-deftest sk/check-dialect-modules-participate-in-config-reload ()
  (let ((lisp-position (seq-position sk/reload-module-files "sk-lisp"))
        (clojure-position (seq-position sk/reload-module-files "sk-clojure"))
        (racket-position (seq-position sk/reload-module-files "sk-racket"))
        (fennel-position (seq-position sk/reload-module-files "sk-fennel"))
        (format-position (seq-position sk/reload-module-files "sk-format")))
    (should lisp-position)
    (should clojure-position)
    (should racket-position)
    (should fennel-position)
    (should format-position)
    (should (< lisp-position clojure-position))
    (should (< clojure-position racket-position))
    (should (< racket-position fennel-position))
    (should (< fennel-position format-position))))

(ert-deftest sk/check-lisp-activation-and-indent-ownership ()
  (should (= 1 (cl-count #'geiser-mode--maybe-activate scheme-mode-hook
                          :test #'eq)))
  (should (= 1 (cl-count #'sk/scheme-mode-setup scheme-mode-hook
                          :test #'eq)))
  (let ((calls 0)
        (original-geiser-mode (symbol-function 'geiser-mode)))
    (cl-letf (((symbol-function 'geiser-mode)
               (lambda (&optional argument)
                 (cl-incf calls)
                 (funcall original-geiser-mode argument))))
      (with-temp-buffer (scheme-mode)))
    (should (= calls 1)))
  (should (= 1 (cl-count #'sly-editing-mode lisp-mode-hook :test #'eq)))
  (let ((first (generate-new-buffer " *sk-sly-indent-first*"))
        (second (generate-new-buffer " *sk-sly-indent-second*")))
    (unwind-protect
        (progn
          (with-current-buffer first (lisp-mode))
          (sly-setup)
          (with-current-buffer second (lisp-mode))
          (dolist (buffer (list first second))
            (with-current-buffer buffer
              (should (bound-and-true-p sly-editing-mode))
              (should (eq lisp-indent-function
                          #'sly--lisp-indent-function))))
          (should (= 1 (cl-count #'sly-editing-mode lisp-mode-hook
                                  :test #'eq))))
      (kill-buffer first)
      (kill-buffer second)))
  (should-not (seq-some #'sk/check-lisp-runtime-process-p (process-list))))

(ert-deftest sk/check-lisp-backend-guards-and-errors ()
  (dolist (mode '(emacs-lisp-mode scheme-mode lisp-mode))
    (with-temp-buffer
      (insert "   \n")
      (funcall mode)
      (goto-char (point-min))
      (let ((condition (should-error (sk/lisp-docs) :type 'user-error)))
        (should (equal (cadr condition) "No symbol at point")))))
  (dolist (case '((sk/lisp--call-scheme
                   sk/lisp--scheme-repl-active-p
                   "No Scheme REPL is active; run SPC l r first")
                  (sk/lisp--call-common-lisp
                   sk/lisp--common-lisp-repl-active-p
                   "No project SLY REPL is active; run SPC l r from this project")))
    (pcase-let ((`(,dispatcher ,predicate ,message) case))
      (let (called)
        (cl-letf (((symbol-function predicate) (lambda () nil))
                  ((symbol-function 'sk/check-backend-command)
                   (lambda () (interactive) (setq called t))))
          (let ((condition
                 (should-error
                  (funcall dispatcher #'sk/check-backend-command)
                  :type 'user-error)))
            (should (equal (cadr condition) message))
            (should-not called))))
      (cl-letf (((symbol-function predicate) (lambda () t))
                ((symbol-function 'sk/check-backend-command)
                 (lambda (&rest arguments) arguments)))
        (should (equal (funcall dispatcher #'sk/check-backend-command
                                'left 'right)
                       '(left right))))))
  (dolist (case '((sk/lisp--call-scheme
                   sk/lisp--scheme-repl-active-p
                   "No Geiser REPL synthetic backend failure")
                  (sk/lisp--call-common-lisp
                   sk/lisp--common-lisp-repl-active-p
                   "No current SLY connection synthetic backend failure")))
    (pcase-let ((`(,dispatcher ,predicate ,message) case))
      (cl-letf (((symbol-function predicate) (lambda () t))
                ((symbol-function 'sk/check-backend-command)
                 (lambda () (interactive) (signal 'file-error (list message)))))
        (let ((condition
               (should-error
                (funcall dispatcher #'sk/check-backend-command)
                :type 'file-error)))
          (should (equal (cadr condition) message))))))
  (let ((missing-command (make-symbol "missing-lisp-backend-command")))
    (should-error (sk/lisp--call-scheme missing-command) :type 'user-error)
    (should-error (sk/lisp--call-common-lisp missing-command)
                  :type 'user-error)))

(ert-deftest sk/check-lisp-trailing-whitespace-evaluation ()
  (dolist (case '((scheme-mode sk/lisp--scheme-repl-active-p
                   geiser-eval-last-sexp geiser-eval-buffer)
                  (lisp-mode sk/lisp--common-lisp-repl-active-p
                   sly-eval-last-expression sly-eval-buffer)))
    (pcase-let ((`(,mode ,predicate ,last-command ,buffer-command) case))
      (with-temp-buffer
        (insert "(alpha)\n   ")
        (funcall mode)
        (goto-char (point-max))
        (let (last-called buffer-called)
          (cl-letf (((symbol-function predicate) (lambda () t))
                    ((symbol-function last-command)
                     (lambda () (interactive) (setq last-called t)))
                    ((symbol-function buffer-command)
                     (lambda () (interactive) (setq buffer-called t))))
            (sk/lisp-eval-last-sexp)
            (erase-buffer)
            (sk/lisp-eval-buffer))
          (should last-called)
          (should buffer-called))))))

(ert-deftest sk/check-lisp-project-discovery-and-check-command ()
  (dolist (case '(("elisp/sk-example/test/sk-example-test.el"
                   . "elisp/sk-example")
                  ("guile/src/sk/fixture/math.scm" . "guile")
                  ("common-lisp/tests/core.lisp" . "common-lisp")
                  ("clojure/src/sk/fixture/core.clj" . "clojure")
                  ("racket/src/sk/fixture/main.rkt" . "racket")
                  ("fennel/src/sk/fixture/main.fnl" . "fennel")))
    (let* ((file (sk/check-fixture-path (car case)))
           (expected (file-name-as-directory
                      (sk/check-fixture-path (cdr case))))
           (default-directory (file-name-directory file)))
      (with-temp-buffer
        (setq buffer-file-name file)
        (should (file-equal-p (sk/lisp--project-root t) expected)))))
  (let* ((file (sk/check-fixture-path "guile/src/sk/fixture/math.scm"))
         (expected (file-name-as-directory (sk/check-fixture-path "guile")))
         (default-directory (file-name-directory file))
         command
         command-directory)
    (with-temp-buffer
      (setq buffer-file-name file)
      (scheme-mode)
      (cl-letf (((symbol-function 'compile)
                 (lambda (value)
                   (setq command value
                         command-directory default-directory)
                   'fixture-compilation)))
        (should (eq (sk/lisp-project-check) 'fixture-compilation))))
    (should (equal command "make check"))
    (should (file-equal-p command-directory expected)))
  (let ((root (make-temp-file "sk-lisp-no-makefile." t)))
    (unwind-protect
        (cl-letf (((symbol-function 'sk/lisp--project-root)
                   (lambda (&optional _required)
                     (file-name-as-directory root))))
          (should-error (sk/lisp-project-check) :type 'user-error))
      (delete-directory root t))))

(ert-deftest sk/check-clojure-wrapper-and-project-check-command ()
  (let ((base
         (list (expand-file-name "scripts/guix-lisp-shell"
                                sk/check-source-root)
               "jvm" "--"
               (expand-file-name "scripts/clojure-project"
                                 sk/check-source-root))))
    (should (equal (sk/clojure--command "lsp")
                   (append base '("lsp"))))
    (should (equal (sk/clojure--command "repl")
                   (append base '("repl"))))
    (let (command command-directory)
      (sk/check-with-fixture
       "clojure/src/sk/fixture/core.clj"
       (lambda ()
         (cl-letf (((symbol-function 'compile)
                    (lambda (value)
                      (setq command value
                            command-directory default-directory)
                      'fixture-compilation)))
           (should (eq (sk/lisp-project-check) 'fixture-compilation)))))
      (should
       (equal
        command
        (mapconcat
         #'shell-quote-argument
         (list (car base) "jvm" "--" "make" "--no-print-directory"
               "-C" (file-name-as-directory
                      (sk/check-fixture-path "clojure"))
               "check")
         " ")))
      (should (file-equal-p command-directory
                            (sk/check-fixture-path "clojure"))))))

(ert-deftest sk/check-fennel-wrapper-format-and-project-check-command ()
  (let* ((root (file-name-as-directory (sk/check-fixture-path "fennel")))
         (base (list sk/fennel-project-wrapper "--project" root)))
    (should (equal (sk/fennel--command root "repl")
                   (append base '("repl"))))
    (should (equal (sk/fennel--command root "lsp")
                   (append base '("lsp"))))
    (sk/check-with-fixture
     "fennel/src/sk/fixture/main.fnl"
     (lambda ()
       (let (format-route format-directory check-command check-directory)
         (cl-letf (((symbol-function 'sk/format--external)
                    (lambda (&rest arguments)
                      (setq format-route arguments
                            format-directory default-directory)))
                   ((symbol-function 'compile)
                    (lambda (command)
                      (setq check-command command
                            check-directory default-directory)
                      'fixture-compilation)))
           (sk/format-buffer)
           (should (eq (sk/lisp-project-check) 'fixture-compilation)))
         (should (equal format-route
                        (append base '("format" "-"))))
         (should (file-equal-p format-directory root))
         (should (equal check-command
                        (mapconcat #'shell-quote-argument
                                   (append base '("check")) " ")))
         (should (file-equal-p check-directory root)))))))

(ert-deftest sk/check-clojure-repl-command-and-project-isolation ()
  (let* ((root-a (file-name-as-directory
                  (sk/check-fixture-path "clojure")))
         (root-b (file-name-as-directory
                  (make-temp-file "sk-clojure-project-b." t)))
         (current-root root-a)
         starts displayed buffers processes)
    (unwind-protect
        (cl-letf (((symbol-function 'sk/lisp--project-root)
                   (lambda (&optional _required) current-root))
                  ((symbol-function 'file-executable-p) (lambda (_path) t))
                  ((symbol-function 'make-comint-in-buffer)
                   (lambda (name buffer program startfile &rest switches)
                     (push (list name buffer program startfile switches) starts)
                     (let ((process
                            (make-pipe-process
                             :name (format "sk-clojure-test-%s"
                                           (length starts))
                             :buffer buffer :noquery t)))
                       (push process processes)
                       buffer)))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (buffer &rest _arguments)
                     (setq displayed buffer)
                     buffer)))
          (with-temp-buffer
            (clojure-mode)
            (sk/clojure-repl)
            (push displayed buffers)
            (setq current-root root-b)
            (sk/clojure-repl)
            (push displayed buffers)
            (should (= (length starts) 2))
            (should-not (eq (car buffers) (cadr buffers)))
            (setq current-root root-a)
            (sk/clojure-repl)
            (should (= (length starts) 2))
            (should (eq displayed (cadr buffers))))
          (dolist (start starts)
            (pcase-let ((`(,_name ,buffer ,program ,startfile ,switches)
                         start))
              (should (equal program sk/clojure-guix-shell))
              (should-not startfile)
              (should (equal switches
                             (list "jvm" "--"
                                   sk/clojure-project-wrapper "repl")))
              (with-current-buffer buffer
                (should (eq major-mode 'sk/clojure-repl-mode))
                (let ((process (get-buffer-process buffer)))
                  (should (equal
                           (process-get process 'sk/clojure-project-root)
                           sk/clojure-project-root)))))))
      (dolist (process processes)
        (when (process-live-p process) (delete-process process)))
      (dolist (buffer buffers)
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (delete-directory root-b t))))

(ert-deftest sk/check-clojure-repl-graceful-stop-and-fallback ()
  (let* ((root (file-name-as-directory
                (sk/check-fixture-path "clojure")))
         (buffer (get-buffer-create (sk/clojure--repl-buffer-name root)))
         (process (make-pipe-process :name "sk-clojure-stop-test"
                                     :buffer buffer :noquery t))
         sent waited)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (sk/clojure-repl-mode)
            (setq-local sk/clojure-project-root root))
          (process-put process 'sk/clojure-project-root root)
          (cl-letf (((symbol-function 'sk/lisp--project-root)
                     (lambda (&optional _required) root))
                    ((symbol-function 'comint-send-string)
                     (lambda (target string)
                       (should (eq target process))
                       (setq sent string)))
                    ((symbol-function 'accept-process-output)
                     (lambda (target &rest _arguments)
                       (should (eq target process))
                       (setq waited t)
                       (delete-process process))))
            (sk/clojure-stop))
          (should (equal sent "(System/exit 0)\n"))
          (should waited)
          (should-not (buffer-live-p buffer)))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p buffer) (kill-buffer buffer))))
  (let* ((root (file-name-as-directory
                (sk/check-fixture-path "clojure")))
         (buffer (get-buffer-create (sk/clojure--repl-buffer-name root)))
         (process (make-pipe-process :name "sk-clojure-stop-fallback"
                                     :buffer buffer :noquery t))
         (original-delete (symbol-function 'delete-process))
         forced)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (sk/clojure-repl-mode)
            (setq-local sk/clojure-project-root root))
          (process-put process 'sk/clojure-project-root root)
          (let ((sk/clojure-stop-timeout 0))
            (cl-letf (((symbol-function 'sk/lisp--project-root)
                       (lambda (&optional _required) root))
                      ((symbol-function 'comint-send-string) #'ignore)
                      ((symbol-function 'delete-process)
                       (lambda (target)
                         (setq forced t)
                         (funcall original-delete target))))
              (sk/clojure-stop)))
          (should forced)
          (should-not (buffer-live-p buffer)))
      (when (process-live-p process) (funcall original-delete process))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest sk/check-common-lisp-project-environment-policy ()
  (let* ((root (file-name-as-directory
                (sk/check-fixture-path "common-lisp")))
         (environment (sk/lisp--common-lisp-process-environment root))
         (source-registry
          (let ((process-environment environment))
            (getenv "CL_SOURCE_REGISTRY")))
         (output-translations
          (let ((process-environment environment))
            (getenv "ASDF_OUTPUT_TRANSLATIONS"))))
    (should (string-match-p (regexp-quote root) source-registry))
    (should (string-match-p ":ignore-inherited-configuration"
                            source-registry))
    (should (string-match-p ":ignore-inherited-configuration"
                            output-translations))
    (should (string-match-p
             (regexp-quote
              (file-name-as-directory
               (expand-file-name "asdf" sk/cache-directory)))
             output-translations))
    (should-not (equal source-registry (getenv "CL_SOURCE_REGISTRY")))
    (should-not (equal output-translations
                       (getenv "ASDF_OUTPUT_TRANSLATIONS"))))
  ;; `ob-lisp' uses an independent inferior-lisp/comint path, not the accepted
  ;; SLY connection and strict ASDF environment, so Common Lisp Babel stays off.
  (should-not (alist-get 'lisp org-babel-load-languages))
  ;; Racket Babel would be a second, unwrapped runtime path.  Source editing is
  ;; enabled through `org-src-lang-modes' while execution stays disabled.
  (should (equal (cdr (assoc "racket" org-src-lang-modes)) 'racket))
  (should-not (alist-get 'racket org-babel-load-languages))
  ;; Fennel is likewise edit-only in Org; ob-fennel would bypass the manifest.
  (should (equal (cdr (assoc "fennel" org-src-lang-modes)) 'fennel))
  (should-not (alist-get 'fennel org-babel-load-languages)))

(ert-deftest sk/check-common-lisp-project-connection-isolation ()
  (let* ((root-a (file-name-as-directory
                  (sk/check-fixture-path "common-lisp")))
         (root-b (make-temp-file "sk-cl-project-b." t))
         (root-c (make-temp-file "sk-cl-project-c." t))
         (connection-a
          (make-pipe-process :name "sk-sly-project-a" :noquery t))
         (connection-b
          (make-pipe-process :name "sk-sly-project-b" :noquery t)))
    (unwind-protect
        (progn
          (dolist (root (list root-b root-c))
            (with-temp-file (expand-file-name ".projectile" root)))
          (setq root-b (file-name-as-directory (file-truename root-b))
                root-c (file-name-as-directory (file-truename root-c)))
          (process-put connection-a 'sk/lisp-project-root root-a)
          (process-put connection-b 'sk/lisp-project-root root-b)
          (let ((sly-net-processes (list connection-a connection-b))
                (sly-default-connection connection-a)
                (sly-buffer-connection nil)
                (default-directory root-b)
                observed)
            (with-temp-buffer
              (setq default-directory root-b)
              (cl-letf (((symbol-function 'sk/check-sly-project-command)
                         (lambda ()
                           (interactive)
                           (setq observed (sly-current-connection)))))
                (sk/lisp--call-common-lisp
                 #'sk/check-sly-project-command))
              (should (eq observed connection-b))
              (should-not (eq observed sly-default-connection))))
          (let ((sly-net-processes (list connection-a connection-b))
                (sly-default-connection connection-a)
                (sly-buffer-connection nil)
                (default-directory root-c)
                started-root)
            (with-temp-buffer
              (setq major-mode 'lisp-mode
                    default-directory root-c)
              (cl-letf (((symbol-function 'sk/lisp--start-common-lisp-project)
                         (lambda (root) (setq started-root root))))
                (sk/lisp-repl))
              (should (equal started-root root-c))))
          (let ((sly-net-processes (list connection-a connection-b))
                (sly-default-connection connection-a)
                (sly-buffer-connection nil)
                (default-directory root-b)
                switched-connection)
            (with-temp-buffer
              (setq major-mode 'lisp-mode
                    default-directory root-b)
              (cl-letf (((symbol-function 'sly-mrepl)
                         (lambda (&optional _display-action)
                           (setq switched-connection
                                 (sly-current-connection)))))
                (sk/lisp-repl))
              (should (eq switched-connection connection-b))
              (should (eq sly-buffer-connection connection-b)))))
      (dolist (connection (list connection-a connection-b))
        (when (process-live-p connection)
          (delete-process connection)))
      (delete-directory root-b t)
      (delete-directory root-c t))))

(ert-deftest sk/check-common-lisp-project-start-tags-connection ()
  (let* ((root (file-name-as-directory
                (sk/check-fixture-path "common-lisp")))
         (source (generate-new-buffer " *sk-sly-project-source*"))
         (connection
          (make-pipe-process :name "sk-sly-project-start" :noquery t))
         (repl (generate-new-buffer " *sk-sly-project-repl*"))
         start-arguments
         mrepl-connection
         displayed-repl)
    (unwind-protect
        (with-current-buffer source
          (setq default-directory root)
          (cl-letf (((symbol-function 'executable-find)
                     (lambda (_program) "/gnu/store/fake-sbcl/bin/sbcl"))
                    ((symbol-function 'sly-start)
                     (lambda (&rest arguments)
                       (setq start-arguments arguments)
                       (let ((callback (plist-get arguments :init-function)))
                         (cl-letf (((symbol-function 'sly-current-connection)
                                    (lambda () connection)))
                           (funcall callback)))
                       'fixture-inferior-buffer))
                    ((symbol-function 'sly-mrepl)
                     (lambda (&optional _display-action)
                       (setq mrepl-connection sly-buffer-connection)
                       repl))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (buffer &rest _arguments)
                       (setq displayed-repl buffer))))
            (should (eq (sk/lisp--start-common-lisp-project root)
                        'fixture-inferior-buffer)))
          (should (equal (plist-get start-arguments :program)
                         "/gnu/store/fake-sbcl/bin/sbcl"))
          (should (equal (plist-get start-arguments :directory) root))
          (should (equal (process-get connection 'sk/lisp-project-root)
                         root))
          (should (eq sly-buffer-connection connection))
          (should (eq mrepl-connection connection))
          (should (eq displayed-repl repl))
          (with-current-buffer repl
            (should (equal default-directory root))
            (should (eq sly-buffer-connection connection))))
      (when (process-live-p connection)
        (delete-process connection))
      (kill-buffer repl)
      (kill-buffer source))))

(ert-deftest sk/check-lisp-definition-reference-and-macro-dispatch ()
  (with-temp-buffer
    (insert "sk-example-add")
    (goto-char (point-min))
    (emacs-lisp-mode)
    (let (definition references macroexpand)
      (cl-letf (((symbol-function 'xref-find-definitions)
                 (lambda (symbol) (setq definition symbol)))
                ((symbol-function 'xref-find-references)
                 (lambda (symbol) (setq references symbol)))
                ((symbol-function 'pp-macroexpand-last-sexp)
                 (lambda (&optional argument) (setq macroexpand argument))))
        (sk/lisp-definition)
        (sk/lisp-references)
        (sk/lisp-macroexpand))
      (should (equal definition "sk-example-add"))
      (should (equal references "sk-example-add"))
      (should-not macroexpand)))
  (with-temp-buffer
    (insert "fixture-add")
    (goto-char (point-min))
    (scheme-mode)
    (let (definition references macroexpand)
      (cl-letf (((symbol-function 'sk/lisp--scheme-repl-active-p)
                 (lambda () t))
                ((symbol-function 'geiser-edit-symbol-at-point)
                 (lambda () (interactive) (setq definition t)))
                ((symbol-function 'geiser-xref-callers)
                 (lambda () (interactive) (setq references t)))
                ((symbol-function 'geiser-expand-last-sexp)
                 (lambda () (interactive) (setq macroexpand t))))
        (sk/lisp-definition)
        (sk/lisp-references)
        (sk/lisp-macroexpand))
      (should definition)
      (should references)
      (should macroexpand)))
  (with-temp-buffer
    (insert "twice")
    (goto-char (point-min))
    (lisp-mode)
    (let (definition references macroexpand)
      (cl-letf (((symbol-function 'sk/lisp--common-lisp-repl-active-p)
                 (lambda () t))
                ((symbol-function 'sly-edit-definition)
                 (lambda (symbol) (setq definition symbol)))
                ((symbol-function 'sly-who-calls)
                 (lambda (symbol) (setq references symbol)))
                ((symbol-function 'sly-macroexpand-1)
                 (lambda () (interactive) (setq macroexpand t))))
        (sk/lisp-definition)
        (sk/lisp-references)
        (sk/lisp-macroexpand))
      (should (equal definition "twice"))
      (should (equal references "twice"))
      (should macroexpand))))

(ert-deftest sk/check-clojure-evaluation-and-namespace-commands ()
  (with-temp-buffer
    (insert "(ns demo.core)\n\n"
            "(defn twice [value]\n  (* 2 value))\n\n"
            "(twice 21)\n")
    (clojure-mode)
    (let (sent)
      (cl-letf (((symbol-function 'sk/clojure--require-repl)
                 (lambda () t))
                ((symbol-function 'sk/clojure--send-string)
                 (lambda (expression) (push expression sent))))
        (sk/lisp-eval-buffer)
        (should (string-prefix-p "(load-string " (car sent)))
        (goto-char (point-min))
        (search-forward "twice [value]")
        (sk/lisp-eval-defun)
        (should (string-match-p
                 (regexp-quote "(defn twice [value]") (car sent)))
        (goto-char (point-max))
        (sk/lisp-eval-last-sexp)
        (should (string-match-p (regexp-quote "(twice 21)") (car sent)))
        (sk/lisp-macroexpand)
        (should (string-match-p "macroexpand-1" (car sent)))
        (sk/clojure-reload-namespace)
        (should (equal (car sent) "(require 'demo.core :reload)"))))))

(ert-deftest sk/check-clojure-lsp-dispatch-and-cold-guards ()
  (with-temp-buffer
    (insert "fixture-add")
    (goto-char (point-min))
    (setq major-mode 'clojure-mode)
    (setq-local lsp-mode t)
    (let (docs definition references)
      (cl-letf (((symbol-function 'lsp-workspaces)
                 (lambda () '(fixture-workspace)))
                ((symbol-function 'sk/code-docs)
                 (lambda () (setq docs t)))
                ((symbol-function 'sk/code-definition)
                 (lambda () (setq definition t)))
                ((symbol-function 'sk/code-references)
                 (lambda () (setq references t))))
        (sk/lisp-docs)
        (sk/lisp-definition)
        (sk/lisp-references))
      (should docs)
      (should definition)
      (should references)))
  (with-temp-buffer
    (insert "fixture-add")
    (goto-char (point-min))
    (setq major-mode 'clojure-mode)
    (setq-local lsp-mode t)
    (cl-letf (((symbol-function 'lsp-workspaces) (lambda () nil)))
      (dolist (command '(sk/lisp-docs sk/lisp-definition
                         sk/lisp-references))
        (let ((condition (should-error (funcall command)
                                       :type 'user-error)))
          (should (string-match-p "start it with SPC c l"
                                  (cadr condition)))))))
  (with-temp-buffer
    (insert "(ns demo.core)\n(fixture-add 20 22)\n")
    (goto-char (point-min))
    (search-forward "fixture-add")
    (setq major-mode 'clojure-mode)
    (setq-local lsp-mode nil)
    (dolist (command '(sk/lisp-docs sk/lisp-definition sk/lisp-references))
      (let ((condition (should-error (funcall command) :type 'user-error)))
        (should (string-match-p "start it with SPC c l"
                                (cadr condition)))))
    (let ((condition (should-error (sk/lisp-debug) :type 'user-error)))
      (should
       (equal (cadr condition)
              "Clojure debugging is unsupported in the Guix-only comint workflow")))
    (goto-char (point-max))
    (cl-letf (((symbol-function 'sk/clojure--live-repl-buffer)
               (lambda (&optional _root) nil)))
      (dolist (command '(sk/lisp-eval-buffer sk/lisp-eval-defun
                         sk/lisp-eval-last-sexp sk/lisp-macroexpand
                         sk/clojure-reload-namespace))
        (let ((condition (should-error (funcall command) :type 'user-error)))
          (should
           (equal (cadr condition)
                  "No project Clojure REPL is active; run SPC l r first")))))))

(ert-deftest sk/check-lisp-debug-dispatch-and-cold-guards ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (let (called)
      (cl-letf (((symbol-function 'edebug-defun)
                 (lambda () (interactive) (setq called t))))
        (sk/lisp-debug))
      (should called)))
  (let ((source (generate-new-buffer " *sk-geiser-source*"))
        (debug (get-buffer-create "*Geiser Debug*"))
        selected)
    (unwind-protect
        (progn
          (with-current-buffer debug
            (setq-local geiser-debug--debugger-active t
                        geiser-debug--sender-buffer source))
          (with-current-buffer source
            (scheme-mode)
            (cl-letf (((symbol-function 'sk/lisp--scheme-repl-active-p)
                       (lambda () t))
                      ((symbol-function 'pop-to-buffer)
                       (lambda (buffer &rest _arguments)
                         (setq selected buffer))))
              (sk/lisp-debug)))
          (should (eq selected debug)))
      (kill-buffer source)
      (kill-buffer debug)))
  (let ((debug (generate-new-buffer " *sk-sly-db*"))
        selected)
    (unwind-protect
        (with-temp-buffer
          (lisp-mode)
          (cl-letf (((symbol-function 'sk/lisp--common-lisp-repl-active-p)
                     (lambda () t))
                    ((symbol-function 'sly-db-buffers)
                     (lambda (&optional _connection) (list debug)))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (buffer &rest _arguments)
                       (setq selected buffer))))
            (sk/lisp-debug))
          (should (eq selected debug)))
      (kill-buffer debug)))
  (dolist (case '((scheme-mode . sk/lisp--scheme-repl-active-p)
                  (lisp-mode . sk/lisp--common-lisp-repl-active-p)))
    (with-temp-buffer
      (insert "fixture-symbol")
      (goto-char (point-min))
      (funcall (car case))
      (cl-letf (((symbol-function (cdr case)) (lambda () nil)))
        (dolist (command '(sk/lisp-definition sk/lisp-references
                           sk/lisp-macroexpand sk/lisp-debug))
          (should-error (funcall command) :type 'user-error))))))

(ert-deftest sk/check-puni-lisp-and-org-source-editors ()
  (dolist (mode '(emacs-lisp-mode lisp-interaction-mode scheme-mode lisp-mode
                  clojure-mode racket-mode fennel-mode
                  fennel-proto-repl-mode))
    (sk/check-puni-contract-in-mode mode))
  (dolist (case '(("emacs-lisp" . emacs-lisp-mode)
                  ("scheme" . scheme-mode)
                  ("lisp" . lisp-mode)
                  ("racket" . racket-mode)
                  ("fennel" . fennel-mode)))
    (sk/check-puni-org-source-edit (car case) (cdr case)))
  (with-temp-buffer
    (org-mode)
    (should-not (bound-and-true-p puni-mode)))
  (dolist (hook '(emacs-lisp-mode-hook lisp-interaction-mode-hook
                  scheme-mode-hook lisp-mode-hook clojure-mode-hook
                  racket-mode-hook fennel-mode-hook
                  fennel-proto-repl-mode-hook))
    (should (= 1 (cl-count #'puni-mode (symbol-value hook) :test #'eq)))))

(ert-deftest sk/check-authored-snippets-and-eshell-highlighting ()
  (should (equal yas-snippet-dirs (list sk/snippets-directory)))
  (should (file-equal-p sk/snippets-directory
                        (expand-file-name "snippets" sk/user-directory)))
  (dolist (contract sk/authored-snippet-contract)
    (pcase-let ((`(,mode ,name ,key) contract))
      (should (yas-lookup-snippet name mode t))
      ;; Globalized minor modes intentionally skip hidden temporary buffers,
      ;; so use a normally named ephemeral buffer to exercise startup.
      (let ((buffer (generate-new-buffer "sk-yas-contract-")))
        (unwind-protect
            (with-current-buffer buffer
              (funcall mode)
              (insert key)
              (should (bound-and-true-p yas-minor-mode))
              (should (yas-expand))
              (should-not (equal (buffer-string) key)))
          (kill-buffer buffer)))))
  (require 'esh-mode)
  (should (featurep 'eshell-syntax-highlighting))
  (should (bound-and-true-p eshell-syntax-highlighting-global-mode))
  (with-temp-buffer
    (eshell-mode)
    (should (bound-and-true-p eshell-syntax-highlighting-mode))))

(ert-deftest sk/check-org-hooks-without-personal-notes ()
  (sk/check-with-fixture
   "org/sample.org"
   (lambda ()
     (should (eq major-mode 'org-mode))
     (should (bound-and-true-p visual-line-mode))
     (should (bound-and-true-p org-bullets-mode))
     (should (bound-and-true-p visual-fill-column-mode))))
  (should-not (file-exists-p sk/org-notes-root)))

(ert-deftest sk/check-key-surface ()
  (dolist (binding '(("SPC c f" . sk/format-buffer)
                     ("SPC ," . counsel-switch-buffer)
                     ("SPC b b" . counsel-ibuffer)
                     ("SPC l r" . sk/lisp-repl)
                     ("SPC l b" . sk/lisp-eval-buffer)
                     ("SPC l d" . sk/lisp-eval-defun)
                     ("SPC l e" . sk/lisp-eval-last-sexp)
                     ("SPC l D" . sk/lisp-debug)
                     ("SPC l g" . sk/lisp-definition)
                     ("SPC l k" . sk/lisp-docs)
                     ("SPC l m" . sk/lisp-macroexpand)
                     ("SPC l n" . sk/clojure-reload-namespace)
                     ("SPC l p" . sk/lisp-project-check)
                     ("SPC l q" . sk/lisp-stop)
                     ("SPC l x" . sk/lisp-references)
                     ("SPC l [" . puni-slurp-backward)
                     ("SPC l ]" . puni-slurp-forward)
                     ("SPC l {" . puni-barf-backward)
                     ("SPC l }" . puni-barf-forward)
                     ("SPC l (" . puni-wrap-round)
                     ("SPC l u" . puni-splice)
                     ("SPC l R" . puni-raise)
                     ("SPC l t" . puni-transpose)))
    (should (eq (lookup-key evil-normal-state-map (kbd (car binding)))
                (cdr binding)))))

(ert-deftest sk/check-code-action-delegates-interactively ()
  (with-temp-buffer
    (setq-local lsp-mode t)
    (let (received-action)
      (cl-letf (((symbol-function 'lsp-execute-code-action)
                 (lambda (action)
                   (interactive (list 'fixture-action))
                   (setq received-action action))))
        (sk/code-action))
      (should (eq received-action 'fixture-action)))))

(ert-deftest sk/check-diagnostics-dispatch ()
  (with-temp-buffer
    (setq-local lsp-mode t)
    (setq-local flycheck-mode t)
    (let (backend)
      (cl-letf (((symbol-function 'lsp-treemacs-errors-list)
                 (lambda () (setq backend 'lsp)))
                ((symbol-function 'flycheck-buffer)
                 (lambda () (setq backend 'flycheck-buffer)))
                ((symbol-function 'flycheck-list-errors)
                 (lambda () (setq backend 'flycheck-list))))
        (sk/code-diagnostics))
      (should (eq backend 'lsp))))
  (with-temp-buffer
    (setq-local lsp-mode nil)
    (setq-local flycheck-mode t)
    (let (calls)
      (cl-letf (((symbol-function 'flycheck-buffer)
                 (lambda () (push 'buffer calls)))
                ((symbol-function 'flycheck-list-errors)
                 (lambda () (push 'list calls))))
        (sk/code-diagnostics))
      (should (equal (reverse calls) '(buffer list)))))
  (with-temp-buffer
    (setq-local lsp-mode nil)
    (setq-local flycheck-mode nil)
    (should-error (sk/code-diagnostics) :type 'user-error)))

(ert-deftest sk/check-formatters ()
  (with-temp-buffer
    (insert "int main(){return 0;}\n")
    (sk/check-call-mode-without-lsp #'c-mode)
    (sk/format-buffer)
    (should (string-match-p "int main()" (buffer-string))))
  (with-temp-buffer
    (insert "if true; then\necho ok\nfi\n")
    (sh-mode)
    (sk/format-buffer)
    (should (string-match-p "  echo ok" (buffer-string))))
  (with-temp-buffer
    (insert "{\"b\":1,\"a\":[2,3]}\n")
    (if (fboundp 'json-mode) (json-mode) (js-json-mode))
    (sk/format-buffer)
    (should (string-match-p "\n  \"b\"" (buffer-string))))
  (sk/check-with-fixture
   "json/sample.jsonc"
   (lambda ()
     (should (eq major-mode 'jsonc-mode))
     (sk/format-buffer)
     (should (string-match-p "// JSONC keeps comments" (buffer-string)))
     (should (string-match-p "3[ \t\n\r]*],[ \t\n\r]*}" (buffer-string)))))
  (with-temp-buffer
    (insert "def add(left,right):\n    return left+right\n")
    (sk/check-call-mode-without-lsp #'python-mode)
    (sk/format-buffer)
    (should (string-match-p "def add(left, right):" (buffer-string))))
  (with-temp-buffer
    (insert "local function add(left, right)\nreturn left + right\nend\n")
    (sk/check-call-mode-without-lsp #'lua-mode)
    (sk/format-buffer)
    (should (string-match-p "\n  return left" (buffer-string))))
  (with-temp-buffer
    (insert "(progn\n(message \"x\"))\n")
    (emacs-lisp-mode)
    (sk/format-buffer)
    (should (string-match-p "  (message" (buffer-string)))))

(ert-deftest sk/check-formatter-dispatch-contract ()
  (dolist (case `((c-mode . ("clang-format"
                             ,(concat "--assume-filename="
                                      (expand-file-name "buffer.c"))))
                  (sh-mode . ("shfmt" "--filename"
                              ,(expand-file-name "buffer.sh") "-i" "2"))
                  (json-mode . ("jq" "."))
                  (js-json-mode . ("jq" "."))
                  (jsonc-mode . ("clang-format"
                                 ,(concat "--assume-filename="
                                          (expand-file-name "buffer.json"))))
                  (python-mode . ("ruff" "format" "--stdin-filename"
                                      ,(expand-file-name "buffer.py") "-"))))
    (with-temp-buffer
      (let (route)
        (cl-letf (((symbol-function 'lsp-deferred) #'ignore)
                  ((symbol-function 'sk/format--external)
                   (lambda (&rest arguments) (setq route arguments)))
                  ((symbol-function 'sk/format--indent-buffer)
                   (lambda () (setq route 'indent))))
          (funcall (car case))
          (sk/format-buffer))
        (should (equal route (cdr case))))))
  (dolist (mode '(lua-mode emacs-lisp-mode scheme-mode lisp-mode racket-mode
                  org-mode))
    (with-temp-buffer
      (let (route)
        (cl-letf (((symbol-function 'lsp-deferred) #'ignore)
                  ((symbol-function 'sk/format--external)
                   (lambda (&rest arguments) (setq route arguments)))
                  ((symbol-function 'sk/format--indent-buffer)
                   (lambda () (setq route 'indent))))
          (funcall mode)
          (sk/format-buffer))
        (should (eq route 'indent)))))
  (sk/check-with-fixture
   "clojure/src/sk/fixture/core.clj"
   (lambda ()
     (let (route route-directory)
       (cl-letf (((symbol-function 'sk/format--external)
                  (lambda (&rest arguments)
                    (setq route arguments
                          route-directory default-directory))))
         (sk/format-buffer))
       (let* ((root (file-name-as-directory
                     (sk/check-fixture-path "clojure")))
              (config (expand-file-name ".cljfmt.edn" root)))
         (should (equal route
                        (list "cljfmt" "fix" "--quiet" "--config" config
                              "--project-root" root "-")))
         (should (file-equal-p route-directory root))))))
  (with-temp-buffer
    (fundamental-mode)
    (should-error (sk/format-buffer) :type 'user-error)))

(ert-deftest sk/check-clojure-formatter-failure-preserves-buffer ()
  (sk/check-with-fixture
   "clojure/src/sk/fixture/core.clj"
   (lambda ()
     (let ((before (buffer-string)))
       (cl-letf (((symbol-function 'executable-find)
                  (lambda (_program) "/gnu/store/fake-cljfmt/bin/cljfmt"))
                 ((symbol-function 'call-process-region)
                  (lambda (&rest _arguments) 1)))
         (should-error (sk/format-buffer) :type 'user-error))
       (should (equal (buffer-string) before)))))
  (let ((root (file-name-as-directory
               (make-temp-file "sk-clojure-no-format-config." t))))
    (unwind-protect
        (with-temp-buffer
          (setq major-mode 'clojure-mode)
          (cl-letf (((symbol-function 'sk/lisp--project-root)
                     (lambda (&optional _required) root)))
            (let ((condition
                   (should-error (sk/format-buffer) :type 'user-error)))
              (should (string-match-p "no readable cljfmt config"
                                      (cadr condition))))))
      (delete-directory root t))))

(ert-deftest sk/check-formatter-visited-filenames-and-config ()
  (dolist (case '(("formatter-config/sample.c" . c)
                  ("shell/sample.sh" . shell)
                  ("python/sample.py" . python)
                  ("json/sample.jsonc" . jsonc)))
    (sk/check-with-fixture
     (car case)
     (lambda ()
       (let* ((source (expand-file-name buffer-file-name))
              (expected
               (pcase (cdr case)
                 ('c `("clang-format"
                       ,(concat "--assume-filename=" source)))
                 ('shell `("shfmt" "--filename" ,source "-i" "2"))
                 ('python `("ruff" "format" "--stdin-filename" ,source "-"))
                 ('jsonc `("clang-format"
                           ,(concat "--assume-filename="
                                    (concat (file-name-sans-extension source)
                                            ".json"))))))
              route)
         (cl-letf (((symbol-function 'sk/format--external)
                    (lambda (&rest arguments) (setq route arguments))))
           (sk/format-buffer))
         (should (equal route expected))))))
  ;; The visited filename must let clang-format find the fixture-local style.
  (sk/check-with-fixture
   "formatter-config/sample.c"
   (lambda ()
     (sk/format-buffer)
     (should (string-match-p "\n      if (1)" (buffer-string)))
     (should (string-match-p "\n            return 0;" (buffer-string))))))

(ert-deftest sk/check-lockfile-and-project-collection-policy ()
  (should create-lockfiles)
  (should (equal sk/projects-directory
                 (file-name-as-directory
                  (expand-file-name "Projects" (getenv "HOME")))))
  (should (equal projectile-project-search-path
                 `((,sk/projects-directory . 1))))
  (dolist (name '("alpha" "beta"))
    (make-directory
     (expand-file-name ".git" (expand-file-name name sk/projects-directory))
     t))
  (let ((projectile-known-projects nil)
        discovered)
    (cl-letf (((symbol-function 'projectile-add-known-project)
               (lambda (project) (push project discovered))))
      (projectile-discover-projects-in-search-path))
    (dolist (name '("alpha" "beta"))
      (let ((expected
             (directory-file-name
              (file-truename (expand-file-name name sk/projects-directory)))))
        (should
         (seq-some
          (lambda (project)
            (string= expected
                     (directory-file-name (file-truename project))))
          discovered))))))

(ert-deftest sk/check-elisp-test-foundation ()
  (let* ((fixture (sk/check-fixture-path "elisp/sample.el"))
         (compiled (byte-compile-dest-file fixture))
         (warnings-before (length sk/check-warning-records)))
    (should (byte-compile-file fixture))
    (should (file-exists-p compiled))
    (checkdoc-file fixture)
    (should (= warnings-before (length sk/check-warning-records)))
    (load fixture nil 'nomessage)
    (should (= (sk-fixture-add 20 22) 42)))
  (let ((project (sk/check-fixture-path "elisp/sk-example")))
    (should (file-readable-p (expand-file-name ".projectile" project)))
    (should (file-readable-p (expand-file-name "Makefile" project)))
    (should (file-readable-p (expand-file-name "sk-example.el" project)))
    (should (file-readable-p
             (expand-file-name "test/sk-example-test.el" project)))
    (should (locate-library "package-lint"))))

(ert-deftest sk/check-lisp-shared-window-routing ()
  (save-window-excursion
    (delete-other-windows)
    (dolist (case '(("*sk-geiser-doc*" geiser-doc-mode nil right 1)
                    ("*sk-clojure-doc*" help-mode nil right 1)
                    ("*sk-racket-doc*" racket-describe-mode nil right 1)
                    ("*sk-racket-stepper*" racket-stepper-mode nil right 1)
                    ("*sly-description fixture*" lisp-mode nil right 1)
                    ("*sk-geiser-result*" geiser-debug-mode nil right 1)
                    ("*sk-geiser-xref*" geiser-xref-mode nil right 0)
                    ("*sk-clojure-xref*" xref--xref-buffer-mode nil right 0)
                    ("*sk-clojure-repl*" sk/clojure-repl-mode nil right 0)
                    ("*sk-racket-repl*" racket-repl-mode nil right 0)
                    ("*sk-fennel-repl*" fennel-proto-repl-mode nil right 0)
                    ("*Fennel Error*" fennel-proto-repl-compilation-mode
                     nil bottom 0)
                    ("*sk-sly-mrepl*" sly-mrepl-mode nil right 0)
                    ("*sk-geiser-debug*" geiser-debug-mode t bottom 0)
                    ("*compilation*" compilation-mode nil bottom 0)
                    ("*sk-sly-db*" sly-db-mode nil bottom 0)))
      (pcase-let ((`(,name ,mode ,debugger-active ,side ,slot) case))
        (let ((buffer (generate-new-buffer name)))
          (unwind-protect
              (progn
                (with-current-buffer buffer
                  ;; The modes are already defined by the eager Geiser/SLY
                  ;; setup.  Setting `major-mode' avoids starting a comint REPL.
                  (setq major-mode mode)
                  (when (eq mode 'geiser-debug-mode)
                    (setq-local geiser-debug--debugger-active debugger-active)))
                (let ((window (display-buffer buffer)))
                  (should (window-live-p window))
                  (should (eq (window-parameter window 'window-side) side))
                  (should (= (window-parameter window 'window-slot) slot))))
            (kill-buffer buffer)))))))

(ert-deftest sk/check-display-policy-preserves-foreign-rules ()
  (let* ((foreign-rule '("\\*Package-owned\\*" display-buffer-pop-up-window))
         (display-buffer-alist
          (append sk/window-owned-display-buffer-rules (list foreign-rule)))
         (sk/window-owned-display-buffer-rules
          sk/window-owned-display-buffer-rules)
         (policy (expand-file-name "emacs/lisp/sk-window-policy.el"
                                   sk/check-source-root)))
    (load policy nil 'nomessage)
    (load policy nil 'nomessage)
    (should (= 1 (cl-count foreign-rule display-buffer-alist :test #'eq)))
    (should (= (length sk/window-owned-display-buffer-rules)
               (cl-count-if
                (lambda (rule)
                  (memq rule sk/window-owned-display-buffer-rules))
                display-buffer-alist)))
    (should (= (length display-buffer-alist)
               (1+ (length sk/window-owned-display-buffer-rules))))
    (should (equal (last display-buffer-alist) (list foreign-rule))))
  (let* ((legacy-rule (car sk/window-legacy-display-buffer-rules))
         (collision-rule
          (list (car legacy-rule) 'display-buffer-same-window))
         (display-buffer-alist (list legacy-rule collision-rule))
         (sk/window-owned-display-buffer-rules nil)
         (sk/window-display-policy-migrated nil))
    (sk/window-install-display-buffer-rules sk/window-display-buffer-rules)
    (should-not (memq legacy-rule display-buffer-alist))
    (should (memq collision-rule display-buffer-alist))))

(defun sk/check-write-reload-module (directory name contents)
  "Write test module NAME with CONTENTS below DIRECTORY."
  (let ((file (expand-file-name (concat name ".el") directory)))
    (with-temp-file file
      (insert contents))
    file))

(defvar sk/check-reload-marker nil
  "Dynamically bound marker used by isolated reload failure tests.")

(ert-deftest sk/check-reload-preflight-and-partial-failure-reporting ()
  (let* ((directory (make-temp-file "sk-reload-modules." t))
         (sk/lisp-directory (file-name-as-directory directory))
         (foreign-rule '("\\*Reload sentinel\\*" display-buffer-same-window))
         (display-buffer-alist (list foreign-rule))
         (sk/window-owned-display-buffer-rules nil)
         (current-rules-before (copy-sequence sk/window-display-buffer-rules))
         (sk/check-reload-marker nil))
    (unwind-protect
        (progn
          (sk/check-write-reload-module
           directory "good"
           "; valid Lisp comment with unmatched (\n(setq sk/check-reload-marker '(good)\n      sk/window-display-buffer-rules '((mutated)))\n")
          (sk/check-write-reload-module directory "syntax-broken" "(setq broken\n")
          (let* ((failure (should-error
                           (sk/reload-modules
                            "Test syntax" '("good" "syntax-broken"))))
                 (message (error-message-string failure)))
            (should-not sk/check-reload-marker)
            (should (string-match-p "syntax-broken after 0/2 modules" message))
            (should (equal display-buffer-alist (list foreign-rule))))
          (sk/check-write-reload-module
           directory "runtime-broken" "(error \"deliberate runtime failure\")\n")
          (let* ((failure (should-error
                           (sk/reload-modules
                            "Test runtime" '("good" "runtime-broken"))))
                 (message (error-message-string failure)))
            (should (equal sk/check-reload-marker '(good)))
            (should (string-match-p "runtime-broken after 1/2 modules" message))
            (should (string-match-p "earlier definitions may have changed" message))
            (should (equal display-buffer-alist (list foreign-rule)))
            (should (equal sk/window-display-buffer-rules
                           current-rules-before))))
      (delete-directory directory t))))

(ert-deftest sk/check-xref-navigation-uses-public-jump ()
  (require 'xref)
  (let ((source (get-buffer-create "sk-xref-source-fixture"))
        xref-buffer)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (with-current-buffer source
            (erase-buffer)
            (insert "fixture target\n"))
          (switch-to-buffer source)
          (let* ((main-window (selected-window))
                 (item (xref-make
                        "fixture target"
                        (xref-make-buffer-location source 2)))
                 (xref-auto-jump-to-first-xref nil))
            (setq xref-buffer
                  (xref-show-xrefs (lambda () (list item)) nil))
            (should (buffer-live-p xref-buffer))
            (with-current-buffer xref-buffer
              (should sk/window-xref-navigation-mode))
            (let ((xref-window (get-buffer-window xref-buffer)))
              (should (window-live-p xref-window))
              (select-window xref-window)
              (with-current-buffer xref-buffer
                (let ((position (point-min)))
                  (while (and (< position (point-max))
                              (not (get-text-property position 'xref-item)))
                    (setq position
                          (next-single-property-change
                           position 'xref-item nil (point-max))))
                  (should (< position (point-max)))
                  (goto-char position)))
              (should (eq (key-binding (kbd "RET"))
                          #'sk/window-xref-goto-xref))
              (call-interactively (key-binding (kbd "RET")))
              (should (eq (selected-window) main-window))
              (should (eq (current-buffer) source))
              (should (= (point) 2)))))
      (when (buffer-live-p xref-buffer)
        (kill-buffer xref-buffer))
      (kill-buffer source))))

(ert-deftest sk/check-exwm-reviewed-client-contracts ()
  (require 'sk-exwm)
  (should (equal (sk/exwm-installed-version) sk/exwm-reviewed-version))
  (should (fboundp 'exwm-manage-get-pid))
  (should (fboundp 'exwm-workspace-move-window))
  (should-not (string-match-p
               "exwm--buffer->id"
               (with-temp-buffer
                 (insert-file-contents
                  (expand-file-name "emacs/lisp/sk-exwm.el"
                                    sk/check-source-root))
                 (buffer-string)))))

(ert-deftest sk/check-exwm-terminal-entry-validates-payload-first ()
  (require 'sk-exwm)
  (let ((desktop-file (make-temp-file "sk-missing-terminal." nil ".desktop"))
        (sk/exwm-launch-intents nil)
        (windows-before (length (window-list))))
    (unwind-protect
        (progn
          (with-temp-file desktop-file
            (insert "[Desktop Entry]\n"
                    "Name=Missing Terminal Fixture\n"
                    "Exec=sk-command-that-does-not-exist --flag\n"
                    "Terminal=true\n"))
          (cl-letf (((symbol-function 'counsel-linux-apps-list-desktop-files)
                     (lambda () (list (cons "missing.desktop" desktop-file)))))
            (should-error (sk/exwm-desktop-launch-spec "missing.desktop")))
          (should-not sk/exwm-launch-intents)
          (should (= windows-before (length (window-list)))))
      (delete-file desktop-file))))

(ert-deftest sk/check-exwm-rejects-hidden-and-complex-entries ()
  (require 'sk-exwm)
  (dolist (fixture
           '(("hidden.desktop"
              "[Desktop Entry]\nName=Hidden\nExec=picom\nNoDisplay=true\n")
             ("complex.desktop"
              "[Desktop Entry]\nName=Complex\nExec=sh -c \"echo \\\"$DISPLAY\\\"\" sh %F\n")))
    (let ((desktop-file (make-temp-file "sk-desktop-entry." nil ".desktop")))
      (unwind-protect
          (progn
            (with-temp-file desktop-file
              (insert (cadr fixture)))
            (cl-letf (((symbol-function 'counsel-linux-apps-list-desktop-files)
                       (lambda () (list (cons (car fixture) desktop-file)))))
              (should-error (sk/exwm-desktop-launch-spec (car fixture)))))
        (delete-file desktop-file)))))

(ert-deftest sk/check-exwm-launch-intent-matching ()
  (require 'sk-exwm)
  (let* ((slow (list :token 1 :pid 101 :process nil :matchers '("slowapp")))
         (fast (list :token 2 :pid 202 :process nil :matchers '("fastapp")))
         (sk/exwm-launch-intents (list slow fast)))
    (should (eq fast (sk/exwm-unique-matching-intent
                      202 "FastApp" "fastapp")))
    (should (eq slow (sk/exwm-unique-matching-intent
                      101 "SlowApp" "slowapp"))))
  (let* ((first (list :token 1 :pid nil :process nil :matchers '("sameapp")))
         (second (list :token 2 :pid nil :process nil :matchers '("sameapp")))
         (sk/exwm-launch-intents (list first second)))
    (should-not (sk/exwm-unique-matching-intent
                 999 "SameApp" "sameapp")))
  (let* ((proxy (make-pipe-process :name "sk-live-proxy" :noquery t))
         (single (list :token 1 :pid 500 :process proxy
                       :matchers '("singleinstance")
                       :allow-live-name-fallback t))
         (sk/exwm-launch-intents (list single)))
    (unwind-protect
        (should (eq single (sk/exwm-unique-matching-intent
                            900 "SingleInstance" "single-instance")))
      (delete-process proxy)))
  (let* ((proxy (make-pipe-process :name "sk-direct-proxy" :noquery t))
         (ordinary (list :token 1 :pid 500 :process proxy
                         :matchers '("ordinary")))
         (sk/exwm-launch-intents (list ordinary)))
    (unwind-protect
        (should-not (sk/exwm-unique-matching-intent
                     900 "Ordinary" "ordinary"))
      (delete-process proxy)))
  (let* ((first (list :token 1 :pid 500 :process nil
                      :matchers '("singleinstance")))
         (second (list :token 2 :pid 600 :process nil
                       :matchers '("singleinstance")))
         (sk/exwm-launch-intents (list first second)))
    (should-not (sk/exwm-unique-matching-intent
                 900 "SingleInstance" "single-instance")))
  (cl-letf (((symbol-value 'xcb:Atom:_NET_WM_WINDOW_TYPE_NORMAL) 1)
            ((symbol-value 'xcb:Atom:_NET_WM_WINDOW_TYPE_DIALOG) 2))
    (cl-labels
        ((placeable-p (transient fixed floating type)
           (with-temp-buffer
             (setq-local exwm-transient-for transient
                         window-size-fixed fixed
                         exwm--floating-frame floating
                         exwm-window-type (list type))
             (not (null (sk/exwm-main-client-p))))))
      (should-not (placeable-p 42 nil nil 1))
      (should-not (placeable-p nil nil nil 2))
      (should-not (placeable-p nil t nil 1))
      (should-not (placeable-p nil nil 'floating 1))
      (should (placeable-p nil nil nil 1)))))

(ert-deftest sk/check-exwm-launch-cleanup-has-no-layout-side-effect ()
  (require 'sk-exwm)
  (let ((sk/exwm-launch-intents nil)
        (sk/exwm-launch-sequence 0)
        (exwm-manage-finish-hook nil)
        (window-count-before (length (window-list)))
        (process (make-pipe-process :name "sk-intent-test" :noquery t)))
    (unwind-protect
        (let* ((intent (sk/exwm-register-launch-intent
                        process '("fixture") (selected-frame)))
               (token (plist-get intent :token)))
          (should (memq #'sk/exwm-dispatch-managed-client
                        exwm-manage-finish-hook))
          (should (equal token (process-get process 'sk/exwm-launch-token)))
          (cl-letf (((symbol-function 'process-status)
                     (lambda (_process) 'exit))
                    ((symbol-function 'process-exit-status)
                     (lambda (_process) 7)))
            (sk/exwm-launch-process-sentinel process "failed"))
          (should-not sk/exwm-launch-intents)
          (should-not (memq #'sk/exwm-dispatch-managed-client
                            exwm-manage-finish-hook))
          (should (= window-count-before (length (window-list)))))
      (when (process-live-p process)
        (delete-process process)))))

(ert-deftest sk/check-exwm-matched-client-creates-one-stack-copy ()
  (require 'sk-exwm)
  (save-window-excursion
    (delete-other-windows)
    (let ((original (get-buffer-create "sk-exwm-original-fixture"))
          (client (get-buffer-create "sk-exwm-client-fixture")))
      (unwind-protect
          (progn
            (switch-to-buffer original)
            (switch-to-buffer client)
            (let ((target (sk/exwm-display-client-in-stack
                           client (selected-frame))))
              (should (= 2 (length (sk/window-list))))
              (should (= 1 (cl-count client (sk/window-buffer-list) :test #'eq)))
              (should (eq (window-buffer target) client))
              (should (memq original (sk/window-buffer-list)))))
        (kill-buffer original)
        (kill-buffer client)))))

(ert-deftest sk/check-start-picom-isolates-ambient-config ()
  (require 'sk-exwm)
  (let ((pkill-count 0)
        (start-count 0)
        (wait-count 0)
        (picom-active t)
        (selection-owned t)
        (window-system 'x)
        (default-directory "/ssh:fixture.invalid:/")
        inspection-directories
        pkill-call
        start-call
        events)
    (cl-letf (((symbol-function 'executable-find)
               (lambda (program)
                 (and (member program '("picom" "pkill"))
                      (concat "/mock/" program))))
              ((symbol-function 'call-process)
               (lambda (program &optional infile destination display &rest args)
                 (setq pkill-count (1+ pkill-count))
                 (setq events (append events '(pkill)))
                 (setq pkill-call
                       (list program infile destination display args))
                 0))
              ((symbol-function 'list-system-processes)
               (lambda ()
                 (push default-directory inspection-directories)
                 '(101 102 103 104)))
              ((symbol-function 'process-attributes)
               (lambda (pid)
                 (push default-directory inspection-directories)
                 (pcase pid
                   (101 (list (cons 'comm "picom")
                              (cons 'euid (user-uid))
                              (cons 'state (if picom-active "S" "Z"))))
                   (102 (list (cons 'comm "picom")
                              (cons 'euid (user-uid))
                              (cons 'state "Z")))
                   (103 (list (cons 'comm "picom")
                              (cons 'euid (1+ (user-uid)))
                              (cons 'state "S")))
                   (104 (list (cons 'comm "other")
                              (cons 'euid (user-uid))
                              (cons 'state "S"))))))
              ((symbol-function 'gui-backend-selection-exists-p)
               (lambda (selection)
                 (should (eq selection '_NET_WM_CM_S0))
                 selection-owned))
              ((symbol-function 'accept-process-output)
               (lambda (&optional _process _seconds _millisec _just-this-one)
                 (setq wait-count (1+ wait-count))
                 (if picom-active
                     (progn
                       (setq picom-active nil)
                       (setq events (append events '(wait-process))))
                   (setq selection-owned nil)
                   (setq events (append events '(wait-selection))))
                 nil))
              ((symbol-function 'start-process)
               (lambda (name buffer program &rest args)
                 (should-not picom-active)
                 (should-not selection-owned)
                 (setq start-count (1+ start-count))
                 (setq events (append events '(start)))
                 (setq start-call (list name buffer program args))
                 'mock-picom-process)))
      (sk/start-picom))
    (should (= pkill-count 1))
    (should (= wait-count 2))
    (should (= start-count 1))
    (should (equal events '(pkill wait-process wait-selection start)))
    (should inspection-directories)
    (should (seq-every-p (lambda (directory) (equal directory "/"))
                         inspection-directories))
    (should (equal pkill-call
                   (list "pkill" nil nil nil
                         (list "-u" (number-to-string (user-uid))
                               "-x" "picom"))))
    (should
     (equal start-call
            (list "picom" nil "picom"
                  (list "--config" "/dev/null"
                        "--backend" "glx"
                        "--vsync"
                        "--opacity-rule" "85:class_g = \"Emacs\""))))))

(ert-deftest sk/check-start-picom-fails-closed-on-selection-timeout ()
  (require 'sk-exwm)
  (let ((sk/picom-stop-timeout 0)
        (window-system 'x)
        (start-count 0))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (program)
                 (and (member program '("picom" "pkill"))
                      (concat "/mock/" program))))
              ((symbol-function 'call-process)
               (lambda (&rest _arguments) 0))
              ((symbol-function 'list-system-processes)
               (lambda () '(101)))
              ((symbol-function 'process-attributes)
               (lambda (_pid)
                 (list (cons 'comm "picom")
                       (cons 'euid (user-uid))
                       (cons 'state "Z"))))
              ((symbol-function 'gui-backend-selection-exists-p)
               (lambda (_selection) t))
              ((symbol-function 'accept-process-output)
               (lambda (&rest _arguments)
                 (error "timeout fixture must not wait")))
              ((symbol-function 'start-process)
               (lambda (&rest _arguments)
                 (setq start-count (1+ start-count)))))
      (let ((failure (should-error (sk/start-picom) :type 'user-error)))
        (should (string-match-p "X compositor selection did not clear"
                                (error-message-string failure)))))
    (should (= start-count 0))))

(ert-deftest sk/check-exwm-start-has-single-visual-owner ()
  (require 'sk-exwm)
  (let ((exwm-update-class-hook nil)
        (exwm-update-title-hook nil)
        (exwm-wm-mode t))
    (cl-letf (((symbol-function 'sk/set-wallpaper)
               (lambda () (error "wallpaper must remain Xinit-owned")))
              ((symbol-function 'sk/start-picom)
               (lambda () (error "Picom must remain Xinit-owned")))
              ((symbol-function 'sk/exwm-bind-keys) #'ignore)
              ((symbol-function 'sk/set-keyboard-repeat) #'ignore))
      (sk/exwm-start)
      (sk/exwm-start))
    (should (= 1 (cl-count #'sk/exwm-update-title
                           exwm-update-class-hook :test #'eq)))
    (should (= 1 (cl-count #'sk/exwm-update-title
                           exwm-update-title-hook :test #'eq)))))

(ert-deftest sk/check-racket-shared-dispatch-and-cold-guards ()
  (with-temp-buffer
    (setq major-mode 'racket-mode)
    (insert "fixture-answer")
    (let (calls)
      (cl-letf (((symbol-function 'sk/racket-repl)
                 (lambda () (interactive) (push 'repl calls)))
                ((symbol-function 'sk/racket-eval-buffer)
                 (lambda () (interactive) (push 'buffer calls)))
                ((symbol-function 'sk/racket-eval-defun)
                 (lambda () (interactive) (push 'defun calls)))
                ((symbol-function 'sk/racket-eval-last-sexp)
                 (lambda () (interactive) (push 'sexp calls)))
                ((symbol-function 'sk/racket-docs)
                 (lambda () (interactive) (push 'docs calls)))
                ((symbol-function 'sk/racket-definition)
                 (lambda () (interactive) (push 'definition calls)))
                ((symbol-function 'sk/racket-references)
                 (lambda () (interactive) (push 'references calls)))
                ((symbol-function 'sk/racket-macroexpand)
                 (lambda () (interactive) (push 'macroexpand calls)))
                ((symbol-function 'sk/racket-debug)
                 (lambda () (interactive) (push 'debug calls)))
                ((symbol-function 'sk/racket-project-check)
                 (lambda () (interactive) (push 'project calls)))
                ((symbol-function 'sk/racket-stop)
                 (lambda () (interactive) (push 'stop calls))))
        (sk/lisp-repl)
        (sk/lisp-eval-buffer)
        (sk/lisp-eval-defun)
        (sk/lisp-eval-last-sexp)
        (sk/lisp-docs)
        (sk/lisp-definition)
        (sk/lisp-references)
        (sk/lisp-macroexpand)
        (sk/lisp-debug)
        (sk/lisp-project-check)
        (sk/lisp-stop))
      (should
       (equal (reverse calls)
              '(repl buffer defun sexp docs definition references
                     macroexpand debug project stop)))))
  (sk/check-with-fixture
   "racket/src/sk/fixture/main.rkt"
   (lambda ()
     (dolist (command '(sk/lisp-eval-buffer
                        sk/lisp-eval-defun
                        sk/lisp-eval-last-sexp
                        sk/lisp-docs
                        sk/lisp-definition
                        sk/lisp-references
                        sk/lisp-macroexpand
                        sk/lisp-debug
                        sk/lisp-stop))
       (should-error (funcall command) :type 'user-error)))))

(ert-deftest sk/check-fennel-shared-dispatch-and-cold-guards ()
  (with-temp-buffer
    (setq major-mode 'fennel-mode)
    (insert "fixture-answer")
    (let (calls)
      (cl-letf (((symbol-function 'sk/fennel-repl)
                 (lambda () (interactive) (push 'repl calls)))
                ((symbol-function 'sk/fennel-eval-buffer)
                 (lambda () (interactive) (push 'buffer calls)))
                ((symbol-function 'sk/fennel-eval-defun)
                 (lambda () (interactive) (push 'defun calls)))
                ((symbol-function 'sk/fennel-eval-last-sexp)
                 (lambda () (interactive) (push 'sexp calls)))
                ((symbol-function 'sk/fennel-docs)
                 (lambda () (interactive) (push 'docs calls)))
                ((symbol-function 'sk/fennel-definition)
                 (lambda () (interactive) (push 'definition calls)))
                ((symbol-function 'sk/fennel-references)
                 (lambda () (interactive) (push 'references calls)))
                ((symbol-function 'sk/fennel-macroexpand)
                 (lambda () (interactive) (push 'macroexpand calls)))
                ((symbol-function 'sk/fennel-debug)
                 (lambda () (interactive) (push 'debug calls)))
                ((symbol-function 'sk/fennel-project-check)
                 (lambda () (interactive) (push 'project calls)))
                ((symbol-function 'sk/fennel-stop)
                 (lambda () (interactive) (push 'stop calls))))
        (sk/lisp-repl)
        (sk/lisp-eval-buffer)
        (sk/lisp-eval-defun)
        (sk/lisp-eval-last-sexp)
        (sk/lisp-docs)
        (sk/lisp-definition)
        (sk/lisp-references)
        (sk/lisp-macroexpand)
        (sk/lisp-debug)
        (sk/lisp-project-check)
        (sk/lisp-stop))
      (should
       (equal (reverse calls)
              '(repl buffer defun sexp docs definition references
                     macroexpand debug project stop)))))
  (sk/check-with-fixture
   "fennel/src/sk/fixture/main.fnl"
   (lambda ()
     (dolist (command '(sk/lisp-eval-buffer
                        sk/lisp-eval-defun
                        sk/lisp-eval-last-sexp
                        sk/lisp-docs
                        sk/lisp-definition
                        sk/lisp-references
                        sk/lisp-macroexpand
                        sk/lisp-debug
                        sk/lisp-stop))
       (should-error (funcall command) :type 'user-error)))))

(ert-deftest sk/check-racket-stop-cleans-stale-repl-after-backend-crash ()
  (let* ((root "/tmp/sk-racket-stale/")
         (repl (get-buffer-create "*sk-racket-stale-repl*"))
         (logger (get-buffer-create (sk/racket--logger-buffer-name root)))
         (exit-calls 0))
    (unwind-protect
        (progn
          (with-current-buffer repl
            (setq-local racket--repl-session-id 'stale-session))
          (cl-letf (((symbol-function 'sk/racket--canonical-root)
                     (lambda (&optional _required) root))
                    ((symbol-function 'sk/racket--live-repl-buffer)
                     (lambda (&optional _root) repl))
                    ((symbol-function 'sk/racket--backend-process)
                     (lambda (&optional _root) nil))
                    ((symbol-function 'sk/racket--disable-project-xp) #'ignore)
                    ((symbol-function 'racket-repl-exit)
                     (lambda () (setq exit-calls (1+ exit-calls)))))
            (should (sk/racket-stop)))
          (should (= exit-calls 0))
          (should-not (buffer-live-p repl))
          (should-not (buffer-live-p logger)))
      (dolist (buffer (list repl logger))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest sk/check-racket-stop-public-fallback-completes-cleanly ()
  (let* ((root "/tmp/sk-racket-fallback/")
         (process (make-pipe-process
                   :name "sk-racket-fallback-process" :noquery t))
         (public-stop-calls 0))
    (unwind-protect
        (cl-letf (((symbol-function 'sk/racket--canonical-root)
                   (lambda (&optional _required) root))
                  ((symbol-function 'sk/racket--live-repl-buffer)
                   (lambda (&optional _root) nil))
                  ((symbol-function 'sk/racket--backend-process)
                   (lambda (&optional _root) process))
                  ((symbol-function 'sk/racket--disable-project-xp) #'ignore)
                  ((symbol-function 'sk/racket--terminate-backend-group)
                   (lambda (_process) nil))
                  ((symbol-function 'racket-stop-back-end)
                   (lambda ()
                     (setq public-stop-calls (1+ public-stop-calls))
                     (delete-process process))))
          (should (sk/racket-stop))
          (should (= public-stop-calls 1))
          (should-not (process-live-p process)))
      (when (process-live-p process)
        (delete-process process)))))

(ert-deftest sk/check-live-expression-is-one-form ()
  (let ((file (expand-file-name "tests/emacs/live-check.el"
                                sk/check-original-repo)))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (should (listp (read (current-buffer))))
      (should-error (read (current-buffer)) :type 'end-of-file))))

(ert-deftest sk/check-deliberate-batch-negative-control ()
  (should-not (equal (getenv "SK_EMACS_CHECK_BREAK_BATCH") "1")))

(let* ((stats (ert-run-tests-batch t))
       (unexpected (ert-stats-completed-unexpected stats)))
  (when sk/check-warning-records
    (message "unexpected batch warnings: %S"
             (reverse sk/check-warning-records)))
  (kill-emacs (if (or (> unexpected 0) sk/check-warning-records) 1 0)))

;;; batch-check.el ends here
