;;; sk-core.el --- Core Emacs state and editing defaults -*- lexical-binding: t; -*-

(defvar sk/cache-directory
  (expand-file-name "emacs/" (or (getenv "XDG_CACHE_HOME") "~/.cache/"))
  "Directory for generated Emacs state.")

(make-directory sk/cache-directory t)
(dolist (directory '("backups" "auto-save" "auto-save-list"))
  (make-directory (expand-file-name directory sk/cache-directory) t))

(setq recentf-save-file
      (expand-file-name "recentf" sk/cache-directory)
      savehist-file
      (expand-file-name "savehist" sk/cache-directory)
      save-place-file
      (expand-file-name "saveplace" sk/cache-directory))

(recentf-mode 1)
(savehist-mode 1)
(save-place-mode 1)

(setq backup-directory-alist
      `(("." . ,(expand-file-name "backups/" sk/cache-directory)))
      auto-save-file-name-transforms
      `((".*" ,(expand-file-name "auto-save/" sk/cache-directory) t))
      auto-save-list-file-prefix
      (expand-file-name "auto-save-list/.saves-" sk/cache-directory)
      create-lockfiles nil)

(require 'server)
(unless (server-running-p)
  (server-start))

(delete-selection-mode 1)
(global-auto-revert-mode 1)
(show-paren-mode 1)
(setq show-paren-delay 0)
(setq-default indent-tabs-mode nil)
(setq-default tab-width 4)
(setq require-final-newline t)

(setq visible-bell t)
(electric-pair-mode 1)

(use-package rainbow-delimiters
  :hook (prog-mode . rainbow-delimiters-mode))

(provide 'sk-core)

;;; sk-core.el ends here
