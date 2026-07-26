;;; Package setup

;; Emacs packages are installed by Guix. This file only wires behavior.
(when (fboundp 'sk/startup-trace-mark)
  (sk/startup-trace-mark "init-enter"))

(require 'subr-x)

(require 'use-package)

(defvar sk/user-directory
  (file-name-directory
   (file-truename (or load-file-name buffer-file-name user-init-file)))
  "Root directory of this Emacs configuration.")

(defvar sk/lisp-directory
  (expand-file-name "lisp" sk/user-directory)
  "Directory for personal Emacs modules.")

(add-to-list 'load-path sk/lisp-directory)

(autoload 'sk/status "sk-status"
  "Open the system status view and collect one fresh snapshot." t)

(require 'sk-core)
(require 'sk-ui)
(require 'sk-windows)
(require 'sk-dired)
(require 'sk-terminal)
(require 'sk-bluetooth)
(require 'sk-dashboard)
(require 'sk-completion)
(require 'sk-evil)
(require 'sk-project)
(require 'sk-lsp)
(require 'sk-lisp)
(require 'sk-scheme-studio)
(require 'sk-clojure)
(require 'sk-racket)
(require 'sk-fennel)
(require 'sk-lua)
(require 'sk-python)
(require 'sk-shell)
(require 'sk-json)
(require 'sk-c)
(require 'sk-format)
(require 'sk-keys)

;;; Org and notes

(require 'sk-org)
(require 'sk-notes)
(custom-set-variables
 ;; custom-set-variables was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(package-selected-packages nil))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 )

(when (fboundp 'sk/startup-trace-mark)
  (sk/startup-trace-mark "init-exit"))
