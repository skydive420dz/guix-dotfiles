;;; sk-evil.el --- Evil editing setup -*- lexical-binding: t; -*-

(use-package evil
  :init
  (setq evil-undo-system 'undo-redo)
  (setq evil-want-integration t)
  (setq evil-want-keybinding nil)
  (setq evil-want-C-u-scroll t)
  (setq evil-want-C-i-jump nil)
  :config
  (evil-mode 1)
  (dolist (map (list evil-normal-state-map
                     evil-motion-state-map
                     evil-insert-state-map
                     evil-replace-state-map
                     evil-visual-state-map
                     evil-operator-state-map))
    (define-key map (kbd "C-g") #'sk/keyboard-quit-dwim)
    (define-key map (kbd "<escape>") #'sk/keyboard-quit-dwim))
  (define-key evil-insert-state-map (kbd "C-h") 'evil-delete-backward-char-and-join)

  ;; Use visual line motions even outside of visual-line-mode buffers.
  (evil-global-set-key 'motion "j" 'evil-next-visual-line)
  (evil-global-set-key 'motion "k" 'evil-previous-visual-line)

  (evil-set-initial-state 'messages-buffer-mode 'normal)
  (evil-set-initial-state 'dashboard-mode 'normal))

(use-package evil-collection
  :after evil
  :config
  (evil-collection-init))

(provide 'sk-evil)

;;; sk-evil.el ends here
