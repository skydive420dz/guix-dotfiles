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

(require 'sk-core)

;;; Global entry points

(global-set-key (kbd "C-c e") #'eshell) ; launch eshell
(global-set-key (kbd "C-c t") #'term) ; launch term

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
