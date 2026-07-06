;;; sk-keys.el --- Global and leader keys -*- lexical-binding: t; -*-

(global-set-key (kbd "C-c e") #'sk/window-open-eshell)
(global-set-key (kbd "C-c t") #'sk/window-open-term)

(use-package general
  :config
  (general-create-definer rune/leader-keys
    :keymaps '(normal insert visual emacs)
    :prefix "SPC"
    :global-prefix "C-SPC")

  (rune/leader-keys
    "."  '(counsel-fzf :which-key "fuzzy file")
    ","  '(sk/window-open-ibuffer :which-key "buffers")

    "b"  '(:ignore t :which-key "buffers")
    "bb" '(sk/window-open-ibuffer :which-key "buffers")
    "bk" '(sk/kill-current-buffer :which-key "kill")

    "f"  '(:ignore t :which-key "files")
    "ff" '(counsel-find-file :which-key "find")
    "fr" '(recentf-open-files :which-key "recent")
    "fs" '(save-buffer :which-key "save")

    "p"  '(:ignore t :which-key "projects")
    "pp" '(projectile-switch-project :which-key "switch")
    "pf" '(counsel-projectile-find-file :which-key "find file")
    "ps" '(projectile-ripgrep :which-key "ripgrep")
    "pc" '(projectile-compile-project :which-key "compile")

    "g"  '(:ignore t :which-key "git")
    "gg" '(magit-status :which-key "status")

    "s"  '(:ignore t :which-key "search")
    "ss" '(counsel-rg :which-key "ripgrep")
    "sg" '(counsel-git :which-key "git files")
    "sp" '(counsel-projectile-rg :which-key "project")

    "c"  '(:ignore t :which-key "code")
    "ca" '(sk/code-action :which-key "action")
    "cd" '(sk/code-definition :which-key "definition")
    "cD" '(sk/code-references :which-key "references")
    "ci" '(sk/code-implementation :which-key "implementation")
    "cl" '(lsp :which-key "start lsp")
    "cs" '(lsp-ivy-workspace-symbol :which-key "symbols")
    "ct" '(sk/code-type-definition :which-key "type definition")
    "cx" '(sk/code-diagnostics :which-key "diagnostics")

    "h"  '(:ignore t :which-key "help")
    "h." '(helpful-at-point :which-key "at point")
    "hf" '(helpful-callable :which-key "function")
    "hv" '(helpful-variable :which-key "variable")
    "hk" '(helpful-key :which-key "key")

    "w"  '(:ignore t :which-key "windows")
    "wf" '(sk/window-toggle-full-frame :which-key "full frame")
    "wu" '(winner-undo :which-key "undo layout")
    "wr" '(winner-redo :which-key "redo layout")

    "o"  '(:ignore t :which-key "open")
    "od" '(sk/window-open-dired :which-key "dired")
    "oe" '(sk/window-open-eshell :which-key "eshell")
    "ot" '(sk/window-open-treemacs :which-key "treemacs")
    "ov" '(sk/window-open-vterm :which-key "vterm")

    "t"  '(:ignore t :which-key "toggles")
    "tt" '(counsel-load-theme :which-key "choose theme")))

(provide 'sk-keys)

;;; sk-keys.el ends here
