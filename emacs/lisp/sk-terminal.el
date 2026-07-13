;;; sk-terminal.el --- Terminal and shell polish -*- lexical-binding: t; -*-

(require 'subr-x)

(defconst sk/eshell-prompt-symbol "λ"
  "Prompt symbol used by the GuixPC Eshell prompt.")

(defface sk/eshell-prompt-directory
  '((t (:inherit eshell-prompt)))
  "Face for the directory segment in the GuixPC Eshell prompt.")

(defface sk/eshell-prompt-symbol
  '((t (:inherit eshell-prompt :weight bold)))
  "Face for the prompt symbol in the GuixPC Eshell prompt.")

(defun sk/eshell-prompt ()
  "Return the GuixPC Eshell prompt."
  (let* ((status (if (and (boundp 'eshell-last-command-status)
                          (numberp eshell-last-command-status)
                          (not (zerop eshell-last-command-status)))
                     (format " %s" eshell-last-command-status)
                   ""))
         (directory (abbreviate-file-name (eshell/pwd))))
    (concat
     (propertize directory 'face 'sk/eshell-prompt-directory)
     (when (not (string-empty-p status))
       (propertize status 'face 'font-lock-warning-face))
     "\n"
     (propertize sk/eshell-prompt-symbol 'face 'sk/eshell-prompt-symbol)
     " ")))

(use-package eshell
  :ensure nil
  :config
  (let ((eshell-directory (expand-file-name "config/eshell/" sk/user-directory)))
    (make-directory eshell-directory t)
    (setq eshell-rc-script (expand-file-name "profile" eshell-directory)
          eshell-aliases-file (expand-file-name "aliases" eshell-directory)))
  (setq eshell-history-size 5000
        eshell-buffer-maximum-lines 5000
        eshell-hist-ignoredups t
        eshell-scroll-to-bottom-on-input t
        eshell-destroy-buffer-when-process-dies t
        eshell-visual-commands '("bash" "btop" "fish" "less" "man" "more"
                                 "nmtui" "ranger" "ssh" "top" "vim" "yazi")
        eshell-prompt-function #'sk/eshell-prompt
        eshell-prompt-regexp (concat "^" (regexp-quote sk/eshell-prompt-symbol) " ")))

(use-package eshell-syntax-highlighting
  :after esh-mode
  :config
  (eshell-syntax-highlighting-global-mode 1))

(use-package vterm
  :if (locate-library "vterm")
  :commands vterm
  :config
  (setq vterm-shell (or (executable-find "fish")
                        (getenv "SHELL")
                        shell-file-name)
        vterm-max-scrollback 10000)
  (add-hook 'vterm-mode-hook #'evil-insert-state))

(dolist (hook '(eshell-mode-hook shell-mode-hook term-mode-hook vterm-mode-hook))
  (add-hook hook (lambda () (hl-line-mode -1))))

(provide 'sk-terminal)

;;; sk-terminal.el ends here
