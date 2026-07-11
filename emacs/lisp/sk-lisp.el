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

(provide 'sk-lisp)

;;; sk-lisp.el ends here
