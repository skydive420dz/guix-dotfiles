;;; sk-project.el --- Project and Git setup -*- lexical-binding: t; -*-

(require 'sk-window-policy)

(defconst sk/projects-directory
  (file-name-as-directory (expand-file-name "~/Projects"))
  "Top-level collection containing this user's project repositories.")

(use-package projectile
  :diminish projectile-mode
  :config (projectile-mode)
  :custom
  ((projectile-completion-system 'ivy)
   (projectile-known-projects-file
    (expand-file-name "projectile-bookmarks.eld" sk/cache-directory))
   (projectile-frecency-file
    (expand-file-name "projectile-frecency.eld" sk/cache-directory)))
  :bind-keymap
  ("C-c p" . projectile-command-map)
  :init
  ;; Discover direct children such as guix-dotfiles and sk-guix, not the
  ;; dotfiles repository alone.
  (setq projectile-project-search-path `((,sk/projects-directory . 1))
        projectile-switch-project-action #'projectile-dired))

(use-package counsel-projectile
  :config (counsel-projectile-mode))

(use-package magit
  :custom
  (magit-display-buffer-function #'sk/window-display-magit-buffer))

(provide 'sk-project)

;;; sk-project.el ends here
