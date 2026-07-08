;;; sk-dired.el --- Dired behavior -*- lexical-binding: t; -*-

(defun sk/dired-ls-supports-group-directories-first-p ()
  "Return non-nil when `insert-directory-program' supports directory grouping."
  (and insert-directory-program
       (executable-find insert-directory-program)
       (with-temp-buffer
         (eq 0 (call-process insert-directory-program nil t nil
                             "--group-directories-first" "-d" ".")))))

(use-package dired
  :ensure nil
  :config
  (setq dired-kill-when-opening-new-dired-buffer t
        dired-listing-switches (if (sk/dired-ls-supports-group-directories-first-p)
                                   "-alh --group-directories-first"
                                 "-alh")
        delete-by-moving-to-trash t)
  (add-hook 'dired-mode-hook #'dired-hide-details-mode)
  (add-hook 'dired-mode-hook #'hl-line-mode)
  (with-eval-after-load 'evil
    (evil-define-key* '(normal motion) dired-mode-map
      (kbd "h") #'dired-up-directory
      (kbd "j") #'dired-next-line
      (kbd "k") #'dired-previous-line
      (kbd "l") #'sk/window-dired-open)))

(provide 'sk-dired)

;;; sk-dired.el ends here
