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
(require 'sk-ui)
(require 'sk-windows)
(require 'sk-dashboard)
(require 'sk-completion)
(require 'sk-evil)
(require 'sk-project)
(require 'sk-lsp)
(require 'sk-lisp)
(require 'sk-lua)
(require 'sk-python)
(require 'sk-shell)
(require 'sk-json)
(require 'sk-c)
(require 'sk-keys)

;;; Org and notes

(require 'sk-org)
(require 'sk-notes)
