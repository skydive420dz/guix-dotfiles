;;; sk-lisp.el --- Lisp family editing setup -*- lexical-binding: t; -*-

;; Emacs Lisp is native to Emacs:
;; Eldoc gives signatures/docs at point.  Rich help/eval/navigation come from
;; Emacs itself, not from lsp-mode.
(defun sk/emacs-lisp-mode-setup ()
  "Configure Emacs Lisp editing buffers."
  (eldoc-mode 1)
  (local-set-key (kbd "C-c C-b") #'eval-buffer))

(add-hook 'emacs-lisp-mode-hook #'sk/emacs-lisp-mode-setup)
(add-hook 'lisp-interaction-mode-hook #'sk/emacs-lisp-mode-setup)

;; Scheme/Guile:
;; Geiser provides the REPL, evaluation, docs, and navigation layer.
(setq scheme-program-name "guile")

(use-package geiser
  :if (locate-library "geiser")
  :demand t
  :commands (geiser geiser-mode geiser-repl-switch)
  :custom
  (geiser-default-implementation 'guile)
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

;; Structural editing:
;; Electric Pair owns delimiter insertion globally.  Puni owns balanced
;; deletion and explicit structural transforms only in Lisp-family buffers;
;; Evil continues to own modal state and ordinary motions.
(use-package puni
  :hook ((emacs-lisp-mode . puni-mode)
         (lisp-interaction-mode . puni-mode)
         (scheme-mode . puni-mode)
         (lisp-mode . puni-mode)))

(defun sk/lisp--dialect ()
  "Return the active Lisp dialect symbol for the current buffer."
  (cond
   ((derived-mode-p 'emacs-lisp-mode 'lisp-interaction-mode)
    'elisp)
   ((derived-mode-p 'scheme-mode)
    'scheme)
   ((derived-mode-p 'lisp-mode 'common-lisp-mode)
    'common-lisp)
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
  "Return non-nil when SLY has an open Common Lisp connection."
  (and (fboundp 'sly-connected-p)
       (sly-connected-p)))

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
  (unless (sk/lisp--common-lisp-repl-active-p)
    (user-error "No Common Lisp REPL is active; run SPC l r first"))
  (if args
      (apply command args)
    (call-interactively command)))

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
     (if (fboundp 'sly)
         (sly)
       (user-error "SLY is not available")))))

(defun sk/lisp-eval-buffer ()
  "Evaluate the current buffer with the current Lisp dialect backend."
  (interactive)
  (pcase (sk/lisp--dialect)
    ('elisp
     (eval-buffer))
    ('scheme
     (sk/lisp--call-scheme #'geiser-eval-buffer))
    ('common-lisp
     (sk/lisp--call-common-lisp #'sly-eval-buffer))))

(defun sk/lisp-eval-defun ()
  "Evaluate the current top-level form with the Lisp dialect backend."
  (interactive)
  (pcase (sk/lisp--dialect)
    ('elisp
     (eval-defun nil))
    ('scheme
     (sk/lisp--call-scheme #'geiser-eval-definition))
    ('common-lisp
     (sk/lisp--call-common-lisp #'sly-eval-defun))))

(defun sk/lisp-eval-last-sexp ()
  "Evaluate the sexp before point with the Lisp dialect backend."
  (interactive)
  (pcase (sk/lisp--dialect)
    ('elisp
     (eval-last-sexp nil))
    ('scheme
     (sk/lisp--call-scheme #'geiser-eval-last-sexp))
    ('common-lisp
     (sk/lisp--call-common-lisp #'sly-eval-last-expression))))

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
       (sk/lisp--call-common-lisp #'sly-describe-symbol symbol)))))

(provide 'sk-lisp)

;;; sk-lisp.el ends here
