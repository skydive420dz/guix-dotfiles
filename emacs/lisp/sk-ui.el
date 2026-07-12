;;; sk-ui.el --- Frame and visual defaults -*- lexical-binding: t; -*-

(setq inhibit-startup-message t)

(scroll-bar-mode -1)
(tool-bar-mode -1)
(tooltip-mode -1)
(set-fringe-mode 10)
(menu-bar-mode -1)

(column-number-mode)

(setq display-line-numbers-type 'relative)

(defun sk/enable-line-numbers ()
  "Enable line numbers in the current buffer."
  (display-line-numbers-mode 1))

(defun sk/disable-line-numbers ()
  "Disable line numbers in the current buffer."
  (display-line-numbers-mode -1))

(global-display-line-numbers-mode -1)
(add-hook 'prog-mode-hook #'sk/enable-line-numbers)
(add-hook 'conf-mode-hook #'sk/enable-line-numbers)

(dolist (hook '(org-mode-hook
                dired-mode-hook
                ibuffer-mode-hook
                help-mode-hook
                helpful-mode-hook
                special-mode-hook
                compilation-mode-hook
                term-mode-hook
                vterm-mode-hook
                shell-mode-hook
                eshell-mode-hook))
  (add-hook hook #'sk/disable-line-numbers))

(defconst sk/icon-font-fallbacks
  '("Symbols Nerd Font Mono"
    "Noto Color Emoji"
    "Font Awesome"
    "Material Icons")
  "GUI font fallbacks used for icon and symbol glyphs.
Terminal clients use the terminal emulator's font configuration instead.")

(defun sk/font-available-p (font)
  "Return non-nil when FONT is available to the current graphical frame."
  (and (display-graphic-p)
       (find-font (font-spec :name font))))

(defun sk/setup-fonts ()
  "Set the default editing font and GUI icon font fallbacks."
  (set-face-attribute 'default nil :family "Iosevka Term" :height 120)
  (when (display-graphic-p)
    (dolist (font sk/icon-font-fallbacks)
      (when (sk/font-available-p font)
        (set-fontset-font t 'symbol font nil 'append)))))

(sk/setup-fonts)

(load-theme 'modus-vivendi-tinted)

(use-package all-the-icons
  :if (locate-library "all-the-icons"))

(use-package all-the-icons-dired
  :if (and (locate-library "all-the-icons")
           (locate-library "all-the-icons-dired"))
  :hook (dired-mode . all-the-icons-dired-mode))

(use-package all-the-icons-ibuffer
  :if (and (locate-library "all-the-icons")
           (locate-library "all-the-icons-ibuffer"))
  :hook (ibuffer-mode . all-the-icons-ibuffer-mode))

(use-package doom-modeline
  :config
  (setq system-time-locale "en_US.UTF-8"
        display-time-format "%a %b %-d  %H:%M"
        display-time-default-load-average nil
        doom-modeline-time t)
  (unless noninteractive
    (display-time-mode 1)
    (doom-modeline-mode 1)))

(provide 'sk-ui)

;;; sk-ui.el ends here
