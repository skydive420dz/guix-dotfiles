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
  :commands (geiser geiser-mode run-geiser)
  :custom
  (geiser-default-implementation 'guile))

(use-package geiser-guile
  :if (locate-library "geiser-guile")
  :after geiser
  :custom
  (geiser-guile-binary "guile"))

(defun sk/scheme-mode-setup ()
  "Configure Scheme buffers for Guile/Geiser editing."
  (eldoc-mode 1)
  (when (fboundp 'geiser-mode)
    (geiser-mode 1))
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
;; lisp-mode owns Common Lisp source buffers.  SLY talks to SBCL for REPL,
;; evaluation, completion, and inspection when you start it.
(setq inferior-lisp-program "sbcl")

(dolist (pattern '("\\.lisp\\'" "\\.cl\\'" "\\.asd\\'"))
  (add-to-list 'auto-mode-alist (cons pattern #'lisp-mode)))

(defun sk/common-lisp-mode-setup ()
  "Configure Common Lisp source buffers without starting a REPL."
  (setq-local lisp-indent-function #'common-lisp-indent-function)
  (eldoc-mode 1))

(add-hook 'lisp-mode-hook #'sk/common-lisp-mode-setup)

(use-package sly
  :if (locate-library "sly")
  :commands sly)

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

(defun sk/lisp-repl ()
  "Start or switch to the REPL for the current Lisp dialect."
  (interactive)
  (pcase (sk/lisp--dialect)
    ('elisp
     (ielm))
    ('scheme
     (if (fboundp 'geiser-repl-switch)
         (geiser-repl-switch)
       (run-geiser 'guile)))
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
     (if (fboundp 'geiser-eval-buffer)
         (geiser-eval-buffer)
       (user-error "Geiser eval is not available")))
    ('common-lisp
     (if (fboundp 'sly-eval-buffer)
         (sly-eval-buffer)
       (user-error "SLY eval is not available")))))

(defun sk/lisp-eval-defun ()
  "Evaluate the current top-level form with the Lisp dialect backend."
  (interactive)
  (pcase (sk/lisp--dialect)
    ('elisp
     (eval-defun nil))
    ('scheme
     (if (fboundp 'geiser-eval-definition)
         (geiser-eval-definition)
       (user-error "Geiser definition eval is not available")))
    ('common-lisp
     (cond
      ((fboundp 'sly-eval-defun)
       (sly-eval-defun))
      ((fboundp 'lisp-eval-defun)
       (lisp-eval-defun))
      (t
       (user-error "Common Lisp defun eval is not available"))))))

(defun sk/lisp-eval-last-sexp ()
  "Evaluate the sexp before point with the Lisp dialect backend."
  (interactive)
  (pcase (sk/lisp--dialect)
    ('elisp
     (eval-last-sexp nil))
    ('scheme
     (if (fboundp 'geiser-eval-last-sexp)
         (geiser-eval-last-sexp)
       (user-error "Geiser last-sexp eval is not available")))
    ('common-lisp
     (cond
      ((fboundp 'sly-eval-last-expression)
       (sly-eval-last-expression))
      ((fboundp 'lisp-eval-last-sexp)
       (lisp-eval-last-sexp))
      (t
       (user-error "Common Lisp last-sexp eval is not available"))))))

(defun sk/lisp-docs ()
  "Show docs for the symbol at point using the active Lisp backend."
  (interactive)
  (pcase (sk/lisp--dialect)
    ('elisp
     (if (fboundp 'helpful-at-point)
         (helpful-at-point)
       (describe-symbol (symbol-at-point))))
    ('scheme
     (if (fboundp 'geiser-doc-symbol-at-point)
         (geiser-doc-symbol-at-point)
       (eldoc-print-current-symbol-info)))
    ('common-lisp
     (if (fboundp 'sly-describe-symbol)
         (sly-describe-symbol (symbol-name (symbol-at-point)))
       (user-error "SLY describe is not available")))))

(provide 'sk-lisp)

;;; sk-lisp.el ends here
