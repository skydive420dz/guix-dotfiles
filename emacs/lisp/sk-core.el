;;; sk-core.el --- Core Emacs state and editing defaults -*- lexical-binding: t; -*-

(require 'project)

(defvar sk/cache-directory
  (expand-file-name "emacs/" (or (getenv "XDG_CACHE_HOME") "~/.cache/"))
  "Directory for generated Emacs state.")

(make-directory sk/cache-directory t)
(dolist (directory '("backups" "auto-save" "auto-save-list"))
  (make-directory (expand-file-name directory sk/cache-directory) t))

(setq recentf-save-file
      (expand-file-name "recentf" sk/cache-directory)
      savehist-file
      (expand-file-name "savehist" sk/cache-directory)
      save-place-file
      (expand-file-name "saveplace" sk/cache-directory))

(recentf-mode 1)
(savehist-mode 1)
(save-place-mode 1)

(setq backup-directory-alist
      `(("." . ,(expand-file-name "backups/" sk/cache-directory)))
      auto-save-file-name-transforms
      `((".*" ,(expand-file-name "auto-save/" sk/cache-directory) t))
      auto-save-list-file-prefix
      (expand-file-name "auto-save-list/.saves-" sk/cache-directory)
      create-lockfiles nil)

(setq ring-bell-function 'ignore
      visible-bell nil
      use-dialog-box nil
      confirm-kill-emacs #'y-or-n-p
      font-lock-maximum-decoration t
      read-process-output-max (* 1024 1024)
      require-final-newline t)

(fset #'yes-or-no-p #'y-or-n-p)

(require 'server)
(unless (server-running-p)
  (server-start))

(delete-selection-mode 1)
(global-auto-revert-mode 1)
(show-paren-mode 1)
(setq show-paren-delay 0)
(setq-default indent-tabs-mode nil)
(setq-default tab-width 4)
(setq-default fill-column 100)

(electric-pair-mode 1)
(electric-indent-mode 1)

(use-package rainbow-delimiters
  :hook (prog-mode . rainbow-delimiters-mode))

(winner-mode 1)

(defun sk/current-file ()
  "Return the current buffer file or raise a user error."
  (or (buffer-file-name)
      (user-error "Current buffer is not visiting a file")))

(defun sk/current-file-path (&optional relative)
  "Return the current file path, optionally RELATIVE to project root."
  (let ((file (sk/current-file)))
    (if (not relative)
        file
      (if-let ((project (project-current nil)))
          (file-relative-name file (project-root project))
        (file-name-nondirectory file)))))

(defun sk/yank-current-file-path ()
  "Copy the current file path to the kill ring."
  (interactive)
  (let ((path (sk/current-file-path)))
    (kill-new path)
    (message "Copied %s" path)))

(defun sk/yank-current-file-path-relative ()
  "Copy the project-relative current file path to the kill ring."
  (interactive)
  (let ((path (sk/current-file-path t)))
    (kill-new path)
    (message "Copied %s" path)))

(defun sk/yank-buffer-contents ()
  "Copy the current buffer contents to the kill ring."
  (interactive)
  (kill-new (buffer-substring-no-properties (point-min) (point-max)))
  (message "Copied buffer contents"))

(defun sk/copy-current-file (target)
  "Copy the current file to TARGET."
  (interactive
   (let ((file (sk/current-file)))
     (list (read-file-name "Copy current file to: "
                           (file-name-directory file)
                           nil nil
                           (file-name-nondirectory file)))))
  (copy-file (sk/current-file) target 1)
  (message "Copied file to %s" target))

(defun sk/rename-current-file (target)
  "Rename or move the current file to TARGET."
  (interactive
   (let ((file (sk/current-file)))
     (list (read-file-name "Rename/move current file to: "
                           (file-name-directory file)
                           nil nil
                           (file-name-nondirectory file)))))
  (rename-file (sk/current-file) target 1)
  (set-visited-file-name target t t))

(defun sk/delete-current-file ()
  "Move the current file to trash, then kill its buffer."
  (interactive)
  (let ((file (sk/current-file)))
    (when (y-or-n-p (format "Move %s to trash? " file))
      (delete-file file t)
      (kill-buffer (current-buffer))
      (when (fboundp 'sk/show-dashboard-if-no-ordinary-buffers)
        (sk/show-dashboard-if-no-ordinary-buffers))
      (message "Moved file to trash: %s" file))))

(defun sk/sudo-file-name (file)
  "Return a TRAMP sudo path for FILE."
  (concat "/sudo:root@localhost:" (expand-file-name file)))

(defun sk/sudo-find-file (file)
  "Open FILE through sudo."
  (interactive "FSudo find file: ")
  (find-file (sk/sudo-file-name file)))

(defun sk/sudo-current-file ()
  "Reopen the current file through sudo."
  (interactive)
  (find-alternate-file (sk/sudo-file-name (sk/current-file))))

(defun sk/save-buffer-and-quit ()
  "Save the current file buffer, then quit this client/session."
  (interactive)
  (when (buffer-file-name)
    (save-buffer))
  (save-buffers-kill-terminal))

(defconst sk/reload-module-files
  '("sk-core"
    "sk-ui"
    "sk-window-policy"
    "sk-windows"
    "sk-dired"
    "sk-terminal"
    "sk-dashboard"
    "sk-completion"
    "sk-evil"
    "sk-project"
    "sk-lsp"
    "sk-lisp"
    "sk-lua"
    "sk-python"
    "sk-shell"
    "sk-json"
    "sk-c"
    "sk-format"
    "sk-keys"
    "sk-org"
    "sk-notes")
  "GuixPC Emacs modules to reload with `sk/reload-config'.")

(defun sk/reload-config ()
  "Reload the GuixPC Emacs modules without restarting EXWM."
  (interactive)
  (dolist (file sk/reload-module-files)
    (load (expand-file-name file sk/lisp-directory) nil 'nomessage))
  (message "GuixPC Emacs config reloaded"))

(when (and (fboundp 'native-comp-available-p)
           (native-comp-available-p))
  (setq native-comp-async-report-warnings-errors 'silent
        native-comp-speed 2))

(provide 'sk-core)

;;; sk-core.el ends here
