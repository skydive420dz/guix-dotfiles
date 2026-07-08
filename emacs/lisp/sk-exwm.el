(require 'exwm)
(require 'sk-window-policy)
(require 'subr-x)

(setq exwm-workspace-number 5)

(autoload 'counsel-linux-apps-list "counsel")

(defun sk/exwm-launch-app ()
  (interactive)
  (require 'counsel)
  (ivy-read "Run application: " (counsel-linux-apps-list)
            :require-match t
            :action #'sk/exwm-launch-desktop-entry
            :caller 'sk/exwm-launch-app))

(defun sk/exwm-launch-desktop-entry (desktop-shortcut)
  (let* ((desktop-id (cdr desktop-shortcut))
         (launcher (or (executable-find "gtk-launch")
                       (executable-find "gtk4-launch"))))
    (sk/exwm-prepare-stack-placement)
    (if launcher
        (call-process launcher nil 0 nil desktop-id)
      (sk/exwm-launch-desktop-entry-direct desktop-id))))

(defun sk/exwm-launch-desktop-entry-direct (desktop-id)
  (let* ((desktop-file (cdr (assoc desktop-id (counsel-linux-apps-list-desktop-files))))
         (exec (and desktop-file (sk/desktop-entry-value desktop-file "Exec")))
         (terminal (string-equal
                    (downcase (or (and desktop-file
                                       (sk/desktop-entry-value desktop-file "Terminal"))
                                  "false"))
                    "true"))
         (args (and exec (split-string-and-unquote
                          (sk/desktop-entry-clean-exec exec)))))
    (unless args
      (user-error "No Exec line found for %s" desktop-id))
    (if terminal
        (unless (executable-find "kitty")
          (user-error "Terminal app needs kitty: %s" desktop-id))
      (unless (executable-find (car args))
        (user-error "Executable not found: %s" (car args))))
    (if terminal
        (apply #'start-process desktop-id nil "kitty" "--" args)
      (apply #'start-process desktop-id nil args))))

(defun sk/desktop-entry-value (desktop-file key)
  (with-temp-buffer
    (insert-file-contents desktop-file)
    (goto-char (point-min))
    (when (re-search-forward "^\\[Desktop Entry\\]$" nil t)
      (let ((limit (save-excursion
                     (or (and (re-search-forward "^\\[" nil t)
                              (match-beginning 0))
                         (point-max)))))
        (when (re-search-forward
               (format "^%s *= *\\(.+\\)$" (regexp-quote key))
               limit t)
          (match-string 1))))))

(defun sk/desktop-entry-clean-exec (exec)
  (let ((clean (replace-regexp-in-string "%%" "__SK_PERCENT__" exec t t)))
    (setq clean (replace-regexp-in-string "%[fFuUdDnNickvm]" "" clean t t))
    (string-trim
     (replace-regexp-in-string "__SK_PERCENT__" "%" clean t t))))

(defun sk/exwm-switch-buffer ()
  (interactive)
  (if (fboundp 'counsel-switch-buffer)
      (counsel-switch-buffer)
    (call-interactively #'switch-to-buffer)))

(defun sk/exwm-close-current ()
  (interactive)
  (if (derived-mode-p 'exwm-mode)
      (let ((window (selected-window)))
        (kill-current-buffer)
        (when (and (window-live-p window)
                   (not (one-window-p t)))
          (delete-window window)))
    (delete-window)))

(defun sk/exwm-toggle-fullscreen ()
  (interactive)
  (if (derived-mode-p 'exwm-mode)
      (exwm-layout-toggle-fullscreen)
    (message "Fullscreen toggle is only available in EXWM app buffers")))

(defvar sk/exwm-pending-stack-window nil
  "Window that should receive the next managed EXWM buffer.")

(defvar sk/exwm-pending-stack-timer nil
  "Timer used to clear stale pending EXWM stack placement.")

(defun sk/exwm-clear-pending-stack-window ()
  "Clear stale pending EXWM stack placement."
  (when sk/exwm-pending-stack-timer
    (cancel-timer sk/exwm-pending-stack-timer)
    (setq sk/exwm-pending-stack-timer nil))
  (setq sk/exwm-pending-stack-window nil)
  (remove-hook 'exwm-manage-finish-hook #'sk/exwm-place-managed-window-in-stack))

(defun sk/exwm-place-managed-window-in-stack ()
  "Place the newly managed EXWM buffer into the pending stack window."
  (when sk/exwm-pending-stack-window
    (let ((window sk/exwm-pending-stack-window)
          (buffer (current-buffer)))
      (sk/exwm-clear-pending-stack-window)
      (when (and (window-live-p window)
                 (buffer-live-p buffer))
        (sk/window-clear-side-state window)
        (set-window-buffer window buffer)
        (select-window window)))))

(defun sk/exwm-prepare-stack-placement ()
  "Prepare the next managed EXWM buffer to appear in the stack."
  (sk/exwm-clear-pending-stack-window)
  (setq sk/exwm-pending-stack-window (sk/window-new-stack-window))
  (add-hook 'exwm-manage-finish-hook #'sk/exwm-place-managed-window-in-stack)
  (setq sk/exwm-pending-stack-timer
        (run-at-time 8 nil #'sk/exwm-clear-pending-stack-window)))

(defun sk/exwm-workspace-index (number)
  (1- number))

(defun sk/exwm-switch-workspace (number)
  (exwm-workspace-switch-create (sk/exwm-workspace-index number)))

(defun sk/exwm-move-window-to-workspace (number)
  (let* ((id (exwm--buffer->id (window-buffer)))
         (buffer (current-buffer))
         (target-index (sk/exwm-workspace-index number))
         (target-frame (nth target-index exwm-workspace--list))
         (target-buffers (and target-frame
                              (delq buffer (sk/window-buffer-list target-frame))))
         (target-master (car target-buffers))
         (target-stack (append (cdr target-buffers) (list buffer))))
    (unless id
      (user-error "Current buffer is not an EXWM window"))
    (exwm-workspace-move-window target-index id)
    (exwm-workspace-switch-create target-index)
    (if target-master
        (sk/window-display-master-stack target-master target-stack)
      (sk/window-display-master-stack buffer nil))))

(defun sk/exwm-switch-workspace-1 () (interactive) (sk/exwm-switch-workspace 1))
(defun sk/exwm-switch-workspace-2 () (interactive) (sk/exwm-switch-workspace 2))
(defun sk/exwm-switch-workspace-3 () (interactive) (sk/exwm-switch-workspace 3))
(defun sk/exwm-switch-workspace-4 () (interactive) (sk/exwm-switch-workspace 4))
(defun sk/exwm-switch-workspace-5 () (interactive) (sk/exwm-switch-workspace 5))

(defun sk/exwm-move-window-to-workspace-1 () (interactive) (sk/exwm-move-window-to-workspace 1))
(defun sk/exwm-move-window-to-workspace-2 () (interactive) (sk/exwm-move-window-to-workspace 2))
(defun sk/exwm-move-window-to-workspace-3 () (interactive) (sk/exwm-move-window-to-workspace 3))
(defun sk/exwm-move-window-to-workspace-4 () (interactive) (sk/exwm-move-window-to-workspace 4))
(defun sk/exwm-move-window-to-workspace-5 () (interactive) (sk/exwm-move-window-to-workspace 5))

(defun sk/set-keyboard-repeat ()
  (interactive)
  (when (executable-find "xset")
    (start-process "xset-repeat" nil
                   "xset" "r" "rate" "210" "67")))

(defvar sk/picom-opacity-rule "85:class_g = \"Emacs\""
  "Picom opacity rule for Emacs frame transparency.")

(defun sk/start-picom ()
  "Start the session compositor with the managed EXWM opacity rule."
  (interactive)
  (when (executable-find "picom")
    (when (executable-find "pkill")
      (call-process "pkill" nil nil nil "-x" "picom"))
    (start-process "picom" nil
                   "picom"
                   "--backend" "glx"
                   "--opacity-rule" sk/picom-opacity-rule)))

(defvar sk/wallpaper-file
  (expand-file-name "~/Projects/guix-dotfiles/assets/wallpapers/waifu-cyberpunk.png"))

(defun sk/set-wallpaper ()
  (interactive)
  (when (and (executable-find "xwallpaper")
             (file-exists-p sk/wallpaper-file))
    (start-process "xwallpaper" nil
                   "xwallpaper" "--zoom" sk/wallpaper-file)))

(defun sk/exwm-launch-kitty ()
  (interactive)
  (unless (executable-find "kitty")
    (user-error "kitty is not available"))
  (sk/exwm-prepare-stack-placement)
  (start-process "kitty" nil "kitty")
  (message "Launching kitty in stack"))

(defun sk/exwm-launch-browser ()
  (interactive)
  (sk/exwm-prepare-stack-placement)
  (start-process-shell-command "browser" nil "chromium")
  (message "Launching chromium"))

(defun sk/exwm-reload ()
  (interactive)
  (load "sk-window-policy" nil t)
  (load "sk-exwm" nil t)
  (sk/exwm-start)
  (message "EXWM config reloaded"))

(defun sk/exwm-update-title ()
  (exwm-workspace-rename-buffer
   (string-trim
    (format "%s%s%s"
            (or exwm-class-name "EXWM")
            (if (and exwm-title (not (string-empty-p exwm-title))) ": " "")
            (or exwm-title "")))))

(defun sk/exwm-focus-left ()
  "Focus the window to the left, falling back to Treemacs.
Treemacs is a left side window, so plain `windmove-left' does not always see it
from regular EXWM/Emacs windows."
  (interactive)
  (if-let ((window (windmove-find-other-window 'left nil (selected-window))))
      (select-window window)
    (if-let ((treemacs-window (and (fboundp 'treemacs-get-local-window)
                                   (treemacs-get-local-window))))
        (select-window treemacs-window)
      (user-error "No window left from selected window"))))

(defun sk/exwm-bind-keys ()
  (exwm-input-set-key (kbd "s-SPC") #'sk/exwm-launch-app)
  (exwm-input-set-key (kbd "s-h") #'sk/exwm-focus-left)
  (exwm-input-set-key (kbd "s-j") #'windmove-down)
  (exwm-input-set-key (kbd "s-k") #'windmove-up)
  (exwm-input-set-key (kbd "s-l") #'windmove-right)
  (exwm-input-set-key (kbd "s-H") #'windmove-swap-states-left)
  (exwm-input-set-key (kbd "s-J") #'windmove-swap-states-down)
  (exwm-input-set-key (kbd "s-K") #'windmove-swap-states-up)
  (exwm-input-set-key (kbd "s-L") #'windmove-swap-states-right)
  (exwm-input-set-key (kbd "s-q") #'sk/exwm-close-current)
  (exwm-input-set-key (kbd "s-b") #'sk/exwm-switch-buffer)
  (exwm-input-set-key (kbd "s-f") #'sk/exwm-toggle-fullscreen)
  (exwm-input-set-key (kbd "s-m") #'sk/window-promote-to-master)
  (exwm-input-set-key (kbd "s-M") #'sk/window-normalize-master-stack)
  (exwm-input-set-key (kbd "s-1") #'sk/exwm-switch-workspace-1)
  (exwm-input-set-key (kbd "s-2") #'sk/exwm-switch-workspace-2)
  (exwm-input-set-key (kbd "s-3") #'sk/exwm-switch-workspace-3)
  (exwm-input-set-key (kbd "s-4") #'sk/exwm-switch-workspace-4)
  (exwm-input-set-key (kbd "s-5") #'sk/exwm-switch-workspace-5)
  (exwm-input-set-key (kbd "s-!") #'sk/exwm-move-window-to-workspace-1)
  (exwm-input-set-key (kbd "s-@") #'sk/exwm-move-window-to-workspace-2)
  (exwm-input-set-key (kbd "s-#") #'sk/exwm-move-window-to-workspace-3)
  (exwm-input-set-key (kbd "s-$") #'sk/exwm-move-window-to-workspace-4)
  (exwm-input-set-key (kbd "s-%") #'sk/exwm-move-window-to-workspace-5)
  (exwm-input-set-key (kbd "s-<return>") #'sk/exwm-launch-kitty)
  (exwm-input-set-key (kbd "s-w") #'sk/exwm-launch-browser)
  (exwm-input-set-key (kbd "s-r") #'sk/exwm-reload)
  (exwm-input-set-key (kbd "<XF86AudioRaiseVolume>") #'sk/volume-raise)
  (exwm-input-set-key (kbd "<XF86AudioLowerVolume>") #'sk/volume-lower))

(defun sk/volume-raise ()
  (interactive)
  (start-process "wpctl-volume-up" nil
                 "wpctl" "set-volume" "-l" "1.0"
                 "@DEFAULT_AUDIO_SINK@" "5%+"))

(defun sk/volume-lower ()
  (interactive)
  (start-process "wpctl-volume-down" nil
                 "wpctl" "set-volume"
                 "@DEFAULT_AUDIO_SINK@" "5%-"))

(defun sk/exwm-start ()
  (add-hook 'exwm-update-class-hook #'sk/exwm-update-title)
  (add-hook 'exwm-update-title-hook #'sk/exwm-update-title)
  (sk/exwm-bind-keys)
  (sk/set-wallpaper)
  (sk/set-keyboard-repeat)
  (sk/start-picom)
  (exwm-wm-mode))

(provide 'sk-exwm)
