(setq inhibit-startup-message t)

(scroll-bar-mode -1) ; hides the scrollbar
(tool-bar-mode -1) ; disable the toolbar
(tooltip-mode -1) ; disable tooltips
(set-fringe-mode 10) ; gives some breathing room

(menu-bar-mode -1) ; disable menu bar

(global-set-key (kbd "C-c e") #'eshell) ; launch eshell
(global-set-key (kbd "C-c t") #'term) ; launch term

(setq visible-bell t) ; setup visual bell


(set-face-attribute 'default nil :family "Iosevka Term" :height 120) ; setup font face
(set-fontset-font t 'symbol "Symbols Nerd Font Mono" nil 'append)

(load-theme 'modus-vivendi) ; setup theme

;; Emacs packages are installed by Guix. This file only wires behavior.
(require 'use-package)

(use-package ivy
  :diminish
  :bind (("C-s" . swiper)
	 :map ivy-minibuffer-map
	 ("TAB" . ivy-alt-done)
	 ("C-l" . ivy-alt-done)
	 ("C-j" . ivy-next-line)
	 ("C-k" . ivy-previous-line)
	 :map ivy-switch-buffer-map
	 ("C-k" . ivy-previous-line)
	 ("C-l" . ivy-done)
	 ("C-d" . ivy-switch-buffer-kill)
	 :map ivy-reverse-i-search-map
	 ("C-k" . ivy-previous-line)
	 ("C-d" . ivy-reverse-i-search-kill))
  
  :config
  (ivy-mode 1))

(use-package doom-modeline
  :init (doom-modeline-mode 1))
