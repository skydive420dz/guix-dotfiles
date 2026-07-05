;;; sk-project.el --- Project and Git setup -*- lexical-binding: t; -*-

(require 'sk-window-policy)

(use-package projectile
  :diminish projectile-mode
  :config (projectile-mode)
  :custom ((projectile-completion-system 'ivy))
  :bind-keymap
  ("C-c p" . projectile-command-map)
  :init
  ;; NOTE: Set this to the folder where you keep your Git repos!
  (when (file-directory-p "~/Projects/guix-dotfiles")
    (setq projectile-project-search-path '("~/Projects/guix-dotfiles")))
  (setq projectile-switch-project-action #'projectile-dired))

(use-package counsel-projectile
  :config (counsel-projectile-mode))

(use-package magit
  :custom
  (magit-display-buffer-function #'sk/window-display-magit-buffer))

(provide 'sk-project)

;;; sk-project.el ends here
