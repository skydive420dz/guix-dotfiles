;;; sk-ui.el --- Frame and visual defaults -*- lexical-binding: t; -*-

(setq inhibit-startup-message t)

(scroll-bar-mode -1)
(tool-bar-mode -1)
(tooltip-mode -1)
(set-fringe-mode 10)
(menu-bar-mode -1)

(column-number-mode)
(global-display-line-numbers-mode t)

(dolist (mode '(org-mode-hook
                term-mode-hook
                vterm-mode-hook
                shell-mode-hook
                eshell-mode-hook))
  (add-hook mode (lambda () (display-line-numbers-mode 0))))

(set-face-attribute 'default nil :family "Iosevka Term" :height 120)
(set-fontset-font t 'symbol "Symbols Nerd Font Mono" nil 'append)

(load-theme 'modus-vivendi-tinted)

(use-package all-the-icons

(use-package all-the-icons-dired
  :hook (dired-mode . all-the-icons-dired-mode))

(use-package all-the-icons-ibuffer
  :hook (ibuffer-mode . all-the-icons-ibuffer-mode))

(use-package all-the-icons-ivy
  :after ivy
  :config
  (all-the-icons-ivy-setup))

(use-package all-the-icons-ivy-rich
  :after (ivy-rich all-the-icons-ivy)
  :init
  (all-the-icons-ivy-rich-mode 1))


(use-package doom-modeline
  :config
  (setq system-time-locale "en_US.UTF-8"
        display-time-format "%a %b %-d  %H:%M"
        display-time-default-load-average nil
        doom-modeline-time t)
  (display-time-mode 1)
  (doom-modeline-mode 1))

(provide 'sk-ui)

;;; sk-ui.el ends here
