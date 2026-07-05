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
    "."  '(counsel-find-file :which-key "find file")
    ","  '(counsel-ibuffer :which-key "buffers")

    "b"  '(:ignore t :which-key "buffers")
    "bb" '(counsel-ibuffer :which-key "buffers")
    "bk" '(sk/kill-current-buffer :which-key "kill")

    "f"  '(:ignore t :which-key "files")
    "ff" '(counsel-find-file :which-key "find")
    "fr" '(recentf-open-files :which-key "recent")
    "fs" '(save-buffer :which-key "save")

    "p"  '(:ignore t :which-key "projects")
    "pp" '(projectile-switch-project :which-key "switch")
    "pf" '(projectile-find-file :which-key "find file")
    "ps" '(projectile-ripgrep :which-key "ripgrep")
    "pc" '(projectile-compile-project :which-key "compile")

    "g"  '(:ignore t :which-key "git")
    "gg" '(magit-status :which-key "status")

    "s"  '(:ignore t :which-key "search")
    "ss" '(counsel-rg :which-key "ripgrep")
    "sg" '(counsel-git :which-key "git files")
    "sp" '(counsel-projectile-rg :which-key "project")

    "c"  '(:ignore t :which-key "code")
    "cl" '(lsp :which-key "start lsp")
    "cs" '(lsp-ivy-workspace-symbol :which-key "symbols")
    "cx" '(lsp-treemacs-errors-list :which-key "diagnostics")

    "h"  '(:ignore t :which-key "help")
    "h." '(helpful-at-point :which-key "at point")
    "hf" '(helpful-callable :which-key "function")
    "hv" '(helpful-variable :which-key "variable")
    "hk" '(helpful-key :which-key "key")

    "w"  '(:ignore t :which-key "windows")
    "wu" '(winner-undo :which-key "undo layout")
    "wr" '(winner-redo :which-key "redo layout")

    "o"  '(:ignore t :which-key "open")
    "od" '(dired :which-key "dired")
    "oe" '(eshell :which-key "eshell")
    "ot" '(term :which-key "term")

    "t"  '(:ignore t :which-key "toggles")
    "tt" '(counsel-load-theme :which-key "choose theme")))

(provide 'sk-keys)

;;; sk-keys.el ends here
