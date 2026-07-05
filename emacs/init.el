;;; Generated state

(defvar sk/cache-directory
  (expand-file-name "emacs/" (or (getenv "XDG_CACHE_HOME") "~/.cache/"))
  "Directory for generated Emacs state.")

(make-directory sk/cache-directory t)
(dolist (directory '("backups" "auto-save" "auto-save-list"))
  (make-directory (expand-file-name directory sk/cache-directory) t))

;;; History

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

;;; Global entry points

(global-set-key (kbd "C-c e") #'eshell) ; launch eshell
(global-set-key (kbd "C-c t") #'term) ; launch term

;;; Server

(require 'server)
(unless (server-running-p)
  (server-start))

;;; Editing defaults

(delete-selection-mode 1)
(global-auto-revert-mode 1)
(show-paren-mode 1)
(setq show-paren-delay 0)
(setq-default indent-tabs-mode nil)
(setq-default tab-width 4)
(setq require-final-newline t)

(setq visible-bell t) ; setup visual bell
(electric-pair-mode 1) ; automatically insert matching parens, brackets, and quotes

(use-package rainbow-delimiters
  :hook (prog-mode . rainbow-delimiters-mode))

;;; Package setup

;; Emacs packages are installed by Guix. This file only wires behavior.
(require 'use-package)

(defvar sk/user-directory
  (file-name-directory
   (file-truename (or load-file-name buffer-file-name user-init-file)))
  "Root directory of this Emacs configuration.")

(defvar sk/lisp-directory
  (expand-file-name "lisp" sk/user-directory)
  "Directory for personal Emacs modules.")

(add-to-list 'load-path sk/lisp-directory)

(require 'sk-ui)
(require 'sk-completion)
(require 'sk-evil)
(require 'sk-project)
(require 'sk-lsp)

;;; Leader keys

(use-package general
  :config
  (general-create-definer rune/leader-keys
    :keymaps '(normal insert visual emacs)
    :prefix "SPC"
    :global-prefix "C-SPC")

  (rune/leader-keys
    "t"  '(:ignore t :which-key "toggles")
    "tt" '(counsel-load-theme :which-key "choose theme")))

;;; Window management

(winner-mode 1)

;;; Org and notes

(require 'sk-org)
(require 'sk-notes)
