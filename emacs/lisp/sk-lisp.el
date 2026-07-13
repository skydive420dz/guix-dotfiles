;;; sk-lisp.el --- Lisp family editing setup -*- lexical-binding: t; -*-

(require 'seq)

(declare-function sk/clojure-debug "sk-clojure")
(declare-function sk/clojure-definition "sk-clojure")
(declare-function sk/clojure-docs "sk-clojure")
(declare-function sk/clojure-eval-buffer "sk-clojure")
(declare-function sk/clojure-eval-defun "sk-clojure")
(declare-function sk/clojure-eval-last-sexp "sk-clojure")
(declare-function sk/clojure-macroexpand "sk-clojure")
(declare-function sk/clojure-project-check "sk-clojure")
(declare-function sk/clojure-references "sk-clojure")
(declare-function sk/clojure-repl "sk-clojure")

;; Emacs Lisp is native to Emacs:
;; Eldoc gives signatures/docs at point.  Rich help/eval/navigation come from
;; Emacs itself, not from lsp-mode.
(defun sk/emacs-lisp-mode-setup ()
  "Configure Emacs Lisp editing buffers."
  (eldoc-mode 1)
  (local-set-key (kbd "C-c C-b") #'eval-buffer))

(add-hook 'emacs-lisp-mode-hook #'sk/emacs-lisp-mode-setup)
(add-hook 'lisp-interaction-mode-hook #'sk/emacs-lisp-mode-setup)

(defun sk/lisp--project-root (&optional required)
  "Return the current Projectile root, or signal when REQUIRED."
  (let ((projectile-require-project-root nil))
    (let ((root (and (fboundp 'projectile-project-root)
                     (ignore-errors (projectile-project-root)))))
      (cond
       (root (file-name-as-directory (file-truename root)))
       (required
        (user-error
         "No Lisp project root; add a .projectile marker to the project"))
       (t nil)))))

;; Scheme/Guile:
;; Geiser provides the REPL, evaluation, docs, and navigation layer.
(setq scheme-program-name "guile")

(use-package geiser
  :if (locate-library "geiser")
  :demand t
  :commands (geiser geiser-mode geiser-repl-switch)
  :custom
  (geiser-default-implementation 'guile)
  ;; Keep every Guile project in its own REPL and add only reviewed project
  ;; paths.  The wrapper returns nil outside Projectile projects, as Geiser's
  ;; project hook requires.
  (geiser-repl-current-project-function #'sk/lisp--project-root)
  (geiser-repl-per-project-p t)
  (geiser-repl-add-project-paths '("." "src"))
  ;; Geiser's own `scheme-mode-hook' entry is the single activation path.
  ;; Enabling the editing mode must not start Guile implicitly.
  (geiser-mode-auto-p t)
  (geiser-mode-start-repl-p nil))

(use-package geiser-guile
  :if (locate-library "geiser-guile")
  :after geiser
  :custom
  (geiser-guile-binary "guile"))

(defun sk/scheme-mode-setup ()
  "Configure Scheme buffers for Guile/Geiser editing."
  (eldoc-mode 1)
  (when (fboundp 'company-mode)
    (company-mode 1)
    ;; Geiser exposes Scheme/Guile symbols through completion-at-point.  Keep
    ;; Scheme local completion direct so Company does not fall through to dabbrev
    ;; before trying the Geiser CAPF source.
    (setq-local company-backends
                '(company-capf
                  company-files
                  company-keywords
                  company-dabbrev-code))))

(add-hook 'scheme-mode-hook #'sk/scheme-mode-setup)

;; Common Lisp:
;; lisp-mode owns Common Lisp syntax and SLY owns its editing and indentation
;; layer.  Loading that layer eagerly keeps every Lisp buffer consistent, but
;; `sly-setup' does not start SBCL; the REPL remains explicitly user-started.
(setq inferior-lisp-program "sbcl")

(dolist (pattern '("\\.lisp\\'" "\\.cl\\'" "\\.asd\\'"))
  (add-to-list 'auto-mode-alist (cons pattern #'lisp-mode)))

(defun sk/common-lisp-mode-setup ()
  "Configure Common Lisp source buffers without starting a REPL."
  ;; Keep a useful native fallback if the declared SLY package is unavailable.
  ;; When SLY is present, its earlier hook owns `lisp-indent-function'.
  (unless (bound-and-true-p sly-editing-mode)
    (setq-local lisp-indent-function #'common-lisp-indent-function))
  (eldoc-mode 1))

(add-hook 'lisp-mode-hook #'sk/common-lisp-mode-setup)

(declare-function sly-setup "sly")

(use-package sly
  :if (locate-library "sly")
  :demand t
  :config
  (sly-setup))

(defun sk/lisp--project-key (root)
  "Return a stable readable cache/connection key for ROOT."
  (let ((project-name
         (file-name-nondirectory (directory-file-name root))))
    (format "%s-%s" project-name (substring (secure-hash 'sha1 root) 0 8))))

(defun sk/lisp--common-lisp-process-environment (root)
  "Return a strict project-local ASDF process environment for ROOT."
  (let* ((project-key (sk/lisp--project-key root))
         (cache-root
          (file-name-as-directory
           (expand-file-name project-key
                             (expand-file-name "asdf" sk/cache-directory))))
         (environment (copy-sequence process-environment)))
    (make-directory cache-root t)
    (let ((process-environment environment))
      (setenv
       "CL_SOURCE_REGISTRY"
       (format
        "(:source-registry (:directory %S) :ignore-inherited-configuration)"
        root))
      (setenv
       "ASDF_OUTPUT_TRANSLATIONS"
       (format
        "(:output-translations (t (%S :implementation)) :ignore-inherited-configuration)"
        cache-root))
      process-environment)))

(defun sk/lisp--common-lisp-project-connection (&optional root)
  "Return the live SLY connection tagged for ROOT.
When ROOT is nil, use the current project or a tagged buffer-local connection."
  (let* ((root (or root (sk/lisp--project-root)))
         (local (and (boundp 'sly-buffer-connection)
                     sly-buffer-connection))
         (local-root
          (and (processp local)
               (process-get local 'sk/lisp-project-root))))
    (cond
     ((and (processp local)
           (process-live-p local)
           local-root
           (or (not root) (equal root local-root)))
      local)
     ((and root (boundp 'sly-net-processes))
      (seq-find
       (lambda (connection)
         (and (processp connection)
              (process-live-p connection)
              (equal root
                     (process-get connection 'sk/lisp-project-root))))
       sly-net-processes)))))

(defun sk/lisp--start-common-lisp-project (root)
  "Start and tag a SLY connection for project ROOT."
  (unless (fboundp 'sly-start)
    (user-error "The SLY start command is not available"))
  (let* ((program
          (or (executable-find inferior-lisp-program)
              (user-error "Common Lisp executable is unavailable: %s"
                          inferior-lisp-program)))
         (project-key (sk/lisp--project-key root))
         (source-buffer (current-buffer))
         (default-directory root)
         (process-environment
          (sk/lisp--common-lisp-process-environment root)))
    (sly-start
     :program program
     :directory root
     :buffer (format "*sly-%s*" project-key)
     :name (intern (format "sbcl-%s" project-key))
     :init-function
     (lambda ()
       (let ((connection (sly-current-connection)))
         (unless (processp connection)
           (error "SLY connected without a network process"))
         (process-put connection 'sk/lisp-project-root root)
         (when (buffer-live-p source-buffer)
           (with-current-buffer source-buffer
             (setq-local sly-buffer-connection connection)
             (when (fboundp 'sly-mrepl)
               (let ((sly-buffer-connection connection))
                 (let ((repl (sly-mrepl)))
                   (when (buffer-live-p repl)
                     (with-current-buffer repl
                       (setq default-directory root)
                       (setq-local sly-buffer-connection connection))
                     (pop-to-buffer repl))))))))))))

;; Structural editing:
;; Electric Pair owns delimiter insertion globally.  Puni owns balanced
;; deletion and explicit structural transforms only in Lisp-family buffers;
;; Evil continues to own modal state and ordinary motions.
(use-package puni
  :hook ((emacs-lisp-mode . puni-mode)
         (lisp-interaction-mode . puni-mode)
         (scheme-mode . puni-mode)
         (lisp-mode . puni-mode)
         (clojure-mode . puni-mode)))

(defun sk/lisp--dialect ()
  "Return the active Lisp dialect symbol for the current buffer."
  (cond
   ((derived-mode-p 'emacs-lisp-mode 'lisp-interaction-mode
                    'inferior-emacs-lisp-mode)
    'elisp)
   ((derived-mode-p 'scheme-mode 'geiser-repl-mode)
    'scheme)
   ((derived-mode-p 'lisp-mode 'common-lisp-mode 'sly-mrepl-mode)
    'common-lisp)
   ((derived-mode-p 'clojure-mode 'sk/clojure-repl-mode)
    'clojure)
   (t
    (user-error "Not in a Lisp-family buffer"))))

(defun sk/lisp--scheme-repl-active-p ()
  "Return non-nil when this buffer has a live Geiser REPL connection."
  ;; Geiser 0.33.1 has no public connected predicate.  Keep its non-signaling
  ;; connection lookup isolated here so package upgrades have one compatibility
  ;; boundary to exercise.
  (and (fboundp 'geiser-repl--connection*)
       (geiser-repl--connection*)))

(defun sk/lisp--common-lisp-repl-active-p ()
  "Return this buffer's live project-tagged SLY connection, or nil."
  (sk/lisp--common-lisp-project-connection))

(defun sk/lisp--call-scheme (command &rest args)
  "Call connected Geiser COMMAND with ARGS."
  (unless (fboundp command)
    (user-error "Geiser command is not available: %s" command))
  (unless (sk/lisp--scheme-repl-active-p)
    (user-error "No Scheme REPL is active; run SPC l r first"))
  (if args
      (apply command args)
    (call-interactively command)))

(defun sk/lisp--call-common-lisp (command &rest args)
  "Call connected SLY COMMAND with ARGS."
  (unless (fboundp command)
    (user-error "SLY command is not available: %s" command))
  (let ((connection (sk/lisp--common-lisp-repl-active-p)))
    (unless connection
      (user-error
       "No project SLY REPL is active; run SPC l r from this project"))
    ;; Never let SLY fall back to an unrelated default connection.
    (let ((sly-buffer-connection connection))
      (if args
          (apply command args)
        (call-interactively command)))))

(defun sk/lisp--symbol-at-point ()
  "Return the Lisp symbol text at point or signal a clear user error."
  (or (thing-at-point 'symbol t)
      (user-error "No symbol at point")))

(defun sk/lisp-repl ()
  "Start or switch to the REPL for the current Lisp dialect."
  (interactive)
  (pcase (sk/lisp--dialect)
    ('elisp
     (ielm))
    ('scheme
     (cond
      ((fboundp 'geiser-repl-switch)
       (geiser-repl-switch))
      ((fboundp 'geiser)
       (geiser 'guile))
      (t
       (user-error "Geiser is not available"))))
    ('common-lisp
     (let* ((root (sk/lisp--project-root t))
            (connection
             (sk/lisp--common-lisp-project-connection root)))
       (cond
        ((not (fboundp 'sly))
         (user-error "SLY is not available"))
        (connection
         (unless (fboundp 'sly-mrepl)
           (user-error "The SLY MREPL command is not available"))
         (setq-local sly-buffer-connection connection)
         (let ((sly-buffer-connection connection))
           (sly-mrepl #'pop-to-buffer)))
        (t
         (sk/lisp--start-common-lisp-project root)))))
    ('clojure
     (sk/clojure-repl))))

(defun sk/lisp-project-check ()
  "Run the current Lisp project's warning-fatal `make check' gate."
  (interactive)
  (if (derived-mode-p 'clojure-mode 'sk/clojure-repl-mode)
      (sk/clojure-project-check)
    (let* ((root (sk/lisp--project-root t))
           (makefile (expand-file-name "Makefile" root))
           (default-directory root))
      (unless (file-readable-p makefile)
        (user-error "Lisp project has no readable Makefile: %s" makefile))
      (compile "make check"))))

(defun sk/lisp-eval-buffer ()
  "Evaluate the current buffer with the current Lisp dialect backend."
  (interactive)
  (pcase (sk/lisp--dialect)
    ('elisp
     (eval-buffer))
    ('scheme
     (sk/lisp--call-scheme #'geiser-eval-buffer))
    ('common-lisp
     (sk/lisp--call-common-lisp #'sly-eval-buffer))
    ('clojure
     (sk/clojure-eval-buffer))))

(defun sk/lisp-eval-defun ()
  "Evaluate the current top-level form with the Lisp dialect backend."
  (interactive)
  (pcase (sk/lisp--dialect)
    ('elisp
     (eval-defun nil))
    ('scheme
     (sk/lisp--call-scheme #'geiser-eval-definition))
    ('common-lisp
     (sk/lisp--call-common-lisp #'sly-eval-defun))
    ('clojure
     (sk/clojure-eval-defun))))

(defun sk/lisp-eval-last-sexp ()
  "Evaluate the sexp before point with the Lisp dialect backend."
  (interactive)
  (pcase (sk/lisp--dialect)
    ('elisp
     (eval-last-sexp nil))
    ('scheme
     (sk/lisp--call-scheme #'geiser-eval-last-sexp))
    ('common-lisp
     (sk/lisp--call-common-lisp #'sly-eval-last-expression))
    ('clojure
     (sk/clojure-eval-last-sexp))))

(defun sk/lisp-docs ()
  "Show docs for the symbol at point using the active Lisp backend."
  (interactive)
  (let ((dialect (sk/lisp--dialect))
        (symbol (sk/lisp--symbol-at-point)))
    (pcase dialect
      ('elisp
       (if (fboundp 'helpful-at-point)
           (helpful-at-point)
         (describe-symbol (intern symbol))))
      ('scheme
       (sk/lisp--call-scheme #'geiser-doc-symbol-at-point))
      ('common-lisp
       (sk/lisp--call-common-lisp #'sly-describe-symbol symbol))
      ('clojure
       (sk/clojure-docs)))))

(defun sk/lisp-definition ()
  "Visit the definition at point through the active Lisp backend."
  (interactive)
  (let ((dialect (sk/lisp--dialect))
        (symbol (sk/lisp--symbol-at-point)))
    (pcase dialect
      ('elisp
       (xref-find-definitions symbol))
      ('scheme
       (sk/lisp--call-scheme #'geiser-edit-symbol-at-point))
      ('common-lisp
       (sk/lisp--call-common-lisp #'sly-edit-definition symbol))
      ('clojure
       (sk/clojure-definition)))))

(defun sk/lisp-references ()
  "Show callers or references at point through the active Lisp backend."
  (interactive)
  (let ((dialect (sk/lisp--dialect))
        (symbol (sk/lisp--symbol-at-point)))
    (pcase dialect
      ('elisp
       (xref-find-references symbol))
      ('scheme
       ;; Guile can return no caller data; Geiser still owns the request and
       ;; reports that limitation without falling through to textual search.
       (sk/lisp--call-scheme #'geiser-xref-callers))
      ('common-lisp
       (sk/lisp--call-common-lisp #'sly-who-calls symbol))
      ('clojure
       (sk/clojure-references)))))

(defun sk/lisp-macroexpand ()
  "Macroexpand the form at point through the active Lisp backend."
  (interactive)
  (pcase (sk/lisp--dialect)
    ('elisp
     (require 'pp)
     (pp-macroexpand-last-sexp nil))
    ('scheme
     (sk/lisp--call-scheme #'geiser-expand-last-sexp))
    ('common-lisp
     (sk/lisp--call-common-lisp #'sly-macroexpand-1))
    ('clojure
     (sk/clojure-macroexpand))))

(defun sk/lisp-debug ()
  "Instrument Elisp or display an active Geiser/SLY debugger."
  (interactive)
  (pcase (sk/lisp--dialect)
    ('elisp
     (edebug-defun))
    ('scheme
     (sk/lisp--call-scheme #'ignore)
     (let ((buffer (get-buffer "*Geiser Debug*")))
       (unless (and buffer
                    (with-current-buffer buffer
                      (and (fboundp 'geiser-debug-active-p)
                           (geiser-debug-active-p))))
         (user-error "No active Geiser debugger"))
       (pop-to-buffer buffer)))
    ('common-lisp
     (let ((connection (sk/lisp--common-lisp-repl-active-p)))
       (unless connection
         (user-error
          "No project SLY REPL is active; run SPC l r from this project"))
       (unless (fboundp 'sly-db-buffers)
         (user-error "The SLY debugger command is not available"))
       (let ((buffer (car (sly-db-buffers connection))))
         (unless buffer
           (user-error "No active SLY debugger"))
         (pop-to-buffer buffer))))
    ('clojure
     (sk/clojure-debug))))

(provide 'sk-lisp)

;;; sk-lisp.el ends here
