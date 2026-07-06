;;; sk-lisp.el --- Lisp family editing setup -*- lexical-binding: t; -*-

;; Emacs Lisp is native to Emacs:
;; Eldoc gives signatures/docs at point.  Rich help/eval/navigation come from
;; Emacs itself, not from lsp-mode.
(add-hook 'emacs-lisp-mode-hook #'eldoc-mode)
(add-hook 'lisp-interaction-mode-hook #'eldoc-mode)

;; Scheme/Guile:
;; Geiser provides the REPL, evaluation, docs, and navigation layer.
(use-package geiser
  :if (locate-library "geiser")
  :commands (geiser geiser-mode run-geiser))

(use-package geiser-guile
  :if (locate-library "geiser-guile")
  :after geiser
  :custom
  (geiser-guile-binary "guile"))

;; Common Lisp:
;; lisp-mode owns Common Lisp source buffers.  SLY talks to SBCL for REPL,
;; evaluation, completion, and inspection when you start it.
(dolist (pattern '("\\.lisp\\'" "\\.cl\\'" "\\.asd\\'"))
  (add-to-list 'auto-mode-alist (cons pattern #'lisp-mode)))

(defun sk/common-lisp-mode-setup ()
  "Configure Common Lisp source buffers without starting a REPL."
  (setq-local lisp-indent-function #'common-lisp-indent-function)
  (eldoc-mode 1))

(add-hook 'lisp-mode-hook #'sk/common-lisp-mode-setup)

(use-package sly
  :if (locate-library "sly")
  :commands sly
  :custom
  (inferior-lisp-program "sbcl"))

(provide 'sk-lisp)

;;; sk-lisp.el ends here
