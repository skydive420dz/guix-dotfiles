;;; sk-lisp.el --- Lisp family editing setup -*- lexical-binding: t; -*-

(add-hook 'emacs-lisp-mode-hook #'eldoc-mode)
(add-hook 'lisp-interaction-mode-hook #'eldoc-mode)

(use-package geiser
  :if (locate-library "geiser")
  :commands (geiser geiser-mode run-geiser))

(use-package geiser-guile
  :if (locate-library "geiser-guile")
  :after geiser
  :custom
  (geiser-guile-binary "guile"))

(use-package sly
  :if (locate-library "sly")
  :commands sly
  :mode ("\\.lisp\\'" "\\.cl\\'" "\\.asd\\'")
  :custom
  (inferior-lisp-program "sbcl"))

(provide 'sk-lisp)

;;; sk-lisp.el ends here
