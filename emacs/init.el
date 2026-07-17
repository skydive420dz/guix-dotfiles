;;; Package setup

;; Emacs packages are installed by Guix. This file only wires behavior.
(when (fboundp 'sk/startup-trace-mark)
  (sk/startup-trace-mark "init-enter"))

(require 'subr-x)

(defconst sk/theme-generated-file
  (expand-file-name
   "emacs/sk-theme-generated.el"
   (or (getenv "XDG_CONFIG_HOME")
       (expand-file-name ".config" "~")))
  "Guix Home's immutable generated Emacs theme adapter.")

(defun sk/immutable-store-file-p (file)
  "Return non-nil when readable FILE resolves below /gnu/store."
  (and (file-readable-p file)
       (condition-case nil
           (string-prefix-p "/gnu/store/" (file-truename file))
         (file-error nil))))

;; Before P3.4 activation this file is absent and sk-ui retains the exact
;; legacy Iosevka/Modus behavior.  Never load a mutable lookalike from ~/.config.
(when (sk/immutable-store-file-p sk/theme-generated-file)
  (load sk/theme-generated-file nil 'nomessage))

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
(require 'sk-dired)
(require 'sk-terminal)
(require 'sk-dashboard)
(require 'sk-completion)
(require 'sk-evil)
(require 'sk-project)
(require 'sk-lsp)
(require 'sk-lisp)
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
