;;; sk-keys.el --- Global and leader keys -*- lexical-binding: t; -*-

(global-set-key (kbd "C-c e") #'eshell)
(global-set-key (kbd "C-c t") #'term)

(use-package general
  :config
  (general-create-definer rune/leader-keys
    :keymaps '(normal insert visual emacs)
    :prefix "SPC"
    :global-prefix "C-SPC")

  (rune/leader-keys
    "t"  '(:ignore t :which-key "toggles")
    "tt" '(counsel-load-theme :which-key "choose theme")))

(provide 'sk-keys)

;;; sk-keys.el ends here
