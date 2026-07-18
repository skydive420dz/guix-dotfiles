;;; sk-exwm.el --- EXWM session and application policy -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'exwm)
(require 'exwm-manage)
(require 'sk-window-policy)
(require 'seq)
(require 'subr-x)

(setq exwm-workspace-number 5)

(autoload 'counsel-linux-apps-list "counsel")

(defconst sk/exwm-reviewed-version "0.35"
  "EXWM release whose client metadata contracts this policy reviews.")

(defvar sk/startup-frame-gate-active-p nil)
(defvar sk/startup-frame-gate-release-complete-p nil)
(defvar sk/startup-frame-final-opacity-percent nil)
(declare-function sk/startup-frame-schedule-release nil)

(defun sk/exwm-installed-version ()
  "Return the EXWM version encoded in the installed library path."
  (when-let ((library (locate-library "exwm")))
    (when (string-match "/exwm-\\([0-9][^/]*\\)/" library)
      (match-string 1 library))))

(defun sk/exwm-assert-compatible ()
  "Fail clearly when the reviewed EXWM client APIs are unavailable."
  (let ((version (sk/exwm-installed-version)))
    (unless (and (equal version sk/exwm-reviewed-version)
                 (fboundp 'exwm-manage-get-pid)
                 (fboundp 'exwm-workspace-move-window)
                 (fboundp 'exwm-workspace-switch-create))
      (error "EXWM policy requires reviewed EXWM %s APIs; found %s"
             sk/exwm-reviewed-version (or version "unknown")))))

(defun sk/exwm-launch-app ()
  (interactive)
  (require 'counsel)
  (let* ((desktop-files (counsel-linux-apps-list-desktop-files))
         (candidates
          (seq-filter
           (lambda (candidate)
             (sk/exwm-supported-desktop-entry-p candidate desktop-files))
           (counsel-linux-apps-list))))
    (ivy-read "Run application: " candidates
              :require-match t
              :action
              (lambda (desktop-shortcut)
                (sk/exwm-launch-spec-in-stack
                 (sk/exwm-desktop-launch-spec
                  (cdr desktop-shortcut) desktop-files)))
              :caller 'sk/exwm-launch-app)))

(defun sk/exwm-supported-desktop-entry-p (desktop-shortcut &optional desktop-files)
  "Return non-nil when DESKTOP-SHORTCUT is visible and directly launchable."
  (and (get-text-property 0 'visible (car desktop-shortcut))
       (condition-case nil
           (progn
             (sk/exwm-desktop-launch-spec
              (cdr desktop-shortcut) desktop-files)
             t)
         (error nil))))

(defun sk/exwm-launch-desktop-entry (desktop-shortcut)
  "Validate and launch DESKTOP-SHORTCUT into the current stack."
  (let ((desktop-id (if (consp desktop-shortcut)
                        (cdr desktop-shortcut)
                      desktop-shortcut)))
    (sk/exwm-launch-spec-in-stack
     (sk/exwm-desktop-launch-spec desktop-id))))

(defun sk/exwm-desktop-launch-spec (desktop-id &optional desktop-files)
  "Return a validated direct-launch specification for DESKTOP-ID."
  (unless (and (stringp desktop-id) (not (string-empty-p desktop-id)))
    (user-error "Invalid desktop entry ID: %S" desktop-id))
  (require 'counsel)
  (let* ((desktop-file
          (cdr (assoc desktop-id
                      (or desktop-files
                          (counsel-linux-apps-list-desktop-files)))))
         (exec (and desktop-file (sk/desktop-entry-value desktop-file "Exec")))
         (startup-class
          (and desktop-file
               (sk/desktop-entry-value desktop-file "StartupWMClass")))
         (application-name
          (and desktop-file (sk/desktop-entry-value desktop-file "Name")))
         (hidden (and desktop-file
                      (sk/desktop-entry-value desktop-file "Hidden")))
         (no-display (and desktop-file
                          (sk/desktop-entry-value desktop-file "NoDisplay")))
         (terminal (string-equal
                    (downcase (or (and desktop-file
                                       (sk/desktop-entry-value desktop-file "Terminal"))
                                  "false"))
                    "true"))
         args
         command matchers)
    (unless (and desktop-file (file-readable-p desktop-file))
      (user-error "Desktop entry is unavailable: %s" desktop-id))
    (when (or (string-equal (downcase (or hidden "false")) "true")
              (string-equal (downcase (or no-display "false")) "true"))
      (user-error "Desktop entry is hidden from launchers: %s" desktop-id))
    (when (and exec (string-match-p "[\\\\\"']" exec))
      (user-error "Desktop entry uses unsupported Exec quoting: %s" desktop-id))
    (setq args (and exec
                    (split-string (sk/desktop-entry-clean-exec exec)
                                  "[[:space:]]+" t)))
    (unless args
      (user-error "No Exec line found for %s" desktop-id))
    (if terminal
        (let ((kitty (executable-find "kitty"))
              (payload (executable-find (car args))))
          (unless kitty
            (user-error "Terminal app needs kitty: %s" desktop-id))
          (unless payload
            (user-error "Terminal executable not found: %s" (car args)))
          (setq command (append (list kitty "--" payload) (cdr args))
                matchers '("kitty")))
      (let ((program (executable-find (car args))))
        (unless program
          (user-error "Executable not found: %s" (car args)))
        (setq command (cons program (cdr args))
              matchers
              (list startup-class
                    application-name
                    (file-name-base program)
                    (car (last (split-string
                                (file-name-sans-extension desktop-id)
                                "\\." t)))))))
    (list :desktop-id desktop-id
          :process-name (file-name-sans-extension desktop-id)
          :command command
          :matchers (sk/exwm-normalize-matchers matchers)
          :allow-live-name-fallback
          (member (sk/exwm-normalize-client-name (file-name-base (car command)))
                  '("chromium")))))

(defun sk/exwm-launch-desktop-entry-direct (desktop-id)
  "Compatibility entrypoint for a validated direct DESKTOP-ID launch."
  (sk/exwm-launch-spec-in-stack (sk/exwm-desktop-launch-spec desktop-id)))

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

(defun sk/exwm-normalize-client-name (name)
  "Normalize a client NAME for conservative class matching."
  (when (stringp name)
    (replace-regexp-in-string "[^[:alnum:]]" "" (downcase name))))

(defun sk/exwm-normalize-matchers (names)
  "Return unique usable client matchers derived from NAMES."
  (delete-dups
   (seq-filter (lambda (name) (>= (length name) 3))
               (delq nil (mapcar #'sk/exwm-normalize-client-name names)))))

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

(defcustom sk/exwm-launch-intent-timeout 30
  "Seconds a validated application launch may wait for its main X client."
  :type 'integer
  :group 'exwm)

(defvar sk/exwm-launch-intents nil
  "Validated application launches awaiting their matching EXWM client.")

(defvar sk/exwm-launch-sequence 0
  "Monotonic identifier for EXWM launch intents.")

(defun sk/exwm-find-launch-intent (token)
  "Return the pending launch intent identified by TOKEN."
  (seq-find (lambda (intent) (equal (plist-get intent :token) token))
            sk/exwm-launch-intents))

(defun sk/exwm-remove-launch-intent (token &optional reason)
  "Remove launch intent TOKEN, canceling its timer.
When REASON is non-nil, report why the client was not placed."
  (when-let ((intent (sk/exwm-find-launch-intent token)))
    (when-let ((timer (plist-get intent :timer)))
      (when (timerp timer)
        (cancel-timer timer)))
    (setq sk/exwm-launch-intents (delq intent sk/exwm-launch-intents))
    (when (null sk/exwm-launch-intents)
      (remove-hook 'exwm-manage-finish-hook
                   #'sk/exwm-dispatch-managed-client))
    (when reason
      (message "EXWM launch %s: %s" token reason))
    intent))

(defun sk/exwm-expire-launch-intent (token)
  "Expire launch intent TOKEN without changing the window layout."
  (sk/exwm-remove-launch-intent token "timed out without a matching client"))

(defun sk/exwm-launch-process-sentinel (process _event)
  "Cancel PROCESS's intent when the application launch fails."
  (when (memq (process-status process) '(exit signal failed))
    (unless (and (eq (process-status process) 'exit)
                 (zerop (process-exit-status process)))
      (when-let ((token (process-get process 'sk/exwm-launch-token)))
        (sk/exwm-remove-launch-intent
         token
         (format "process failed with status %s"
                 (process-exit-status process)))))))

(defun sk/exwm-register-launch-intent
    (process matchers frame &optional allow-live-name-fallback)
  "Track PROCESS for MATCHERS on launch FRAME without changing its layout.
ALLOW-LIVE-NAME-FALLBACK permits a unique class match for known single-instance
applications whose new window belongs to an existing process."
  (let* ((token (cl-incf sk/exwm-launch-sequence))
         (intent (list :token token
                       :process process
                       :pid (process-id process)
                       :matchers matchers
                       :allow-live-name-fallback allow-live-name-fallback
                       :frame frame
                       :timer nil)))
    (process-put process 'sk/exwm-launch-token token)
    (set-process-sentinel process #'sk/exwm-launch-process-sentinel)
    (setf (plist-get intent :timer)
          (run-at-time sk/exwm-launch-intent-timeout nil
                       #'sk/exwm-expire-launch-intent token))
    (push intent sk/exwm-launch-intents)
    (add-hook 'exwm-manage-finish-hook #'sk/exwm-dispatch-managed-client)
    intent))

(defun sk/exwm-clear-launch-intents (&optional reason)
  "Cancel every pending launch intent, optionally reporting REASON."
  (dolist (intent (copy-sequence sk/exwm-launch-intents))
    (sk/exwm-remove-launch-intent (plist-get intent :token) reason))
  (remove-hook 'exwm-manage-finish-hook #'sk/exwm-dispatch-managed-client))

(defun sk/exwm-process-descendant-p (pid ancestor)
  "Return non-nil when PID descends from ANCESTOR in the live process tree."
  (let ((current pid)
        (steps 0)
        attributes)
    (catch 'matched
      (while (and (integerp current) (> current 1) (< steps 32))
        (when (= current ancestor)
          (throw 'matched t))
        (setq attributes (process-attributes current)
              current (cdr (assq 'ppid attributes))
              steps (1+ steps)))
      nil)))

(defun sk/exwm-client-name-score (matchers class instance)
  "Score CLASS and INSTANCE against normalized MATCHERS."
  (let ((actual-names
         (delq nil (mapcar #'sk/exwm-normalize-client-name
                           (list class instance))))
        (score 0))
    (dolist (matcher matchers score)
      (dolist (actual actual-names)
        (setq score
              (max score
                   (cond
                    ((string= matcher actual) 60)
                    ((or (string-prefix-p matcher actual)
                         (string-prefix-p actual matcher))
                     50)
                    (t 0))))))))

(defun sk/exwm-launch-intent-score (intent pid class instance)
  "Score INTENT against client PID, CLASS, and INSTANCE."
  (let* ((root-pid (plist-get intent :pid))
         (process (plist-get intent :process))
         (process-running (and (processp process) (process-live-p process))))
    (cond
     ((and (integerp pid) (integerp root-pid) (= pid root-pid)) 100)
     ((and (integerp pid) (integerp root-pid)
           (sk/exwm-process-descendant-p pid root-pid))
      90)
     ((and process-running
           (not (plist-get intent :allow-live-name-fallback)))
      0)
     (t (sk/exwm-client-name-score
         (plist-get intent :matchers) class instance)))))

(defun sk/exwm-main-client-p ()
  "Return non-nil when the current EXWM client is not a popup-like window."
  (and (not exwm-transient-for)
       (not window-size-fixed)
       (not (and (boundp 'exwm--floating-frame) exwm--floating-frame))
       (or (null exwm-window-type)
           (memq xcb:Atom:_NET_WM_WINDOW_TYPE_NORMAL exwm-window-type))))

(defun sk/exwm-unique-matching-intent (pid class instance)
  "Return the unique best launch intent for PID, CLASS, and INSTANCE."
  (let* ((scored
          (mapcar (lambda (intent)
                    (cons (sk/exwm-launch-intent-score
                           intent pid class instance)
                          intent))
                  sk/exwm-launch-intents))
         (best-score (if scored (apply #'max (mapcar #'car scored)) 0))
         (best (seq-filter (lambda (entry) (= (car entry) best-score)) scored)))
    (when (and (> best-score 0) (= (length best) 1))
      (cdar best))))

(defun sk/exwm-display-client-in-stack (buffer frame)
  "Display client BUFFER once in FRAME's master/stack layout."
  (unless (frame-live-p frame)
    (error "Launch workspace no longer exists"))
  (let* ((source-windows (get-buffer-window-list buffer nil t))
         (source-replacements
          (mapcar
           (lambda (window)
             (cons window
                   (seq-find
                    (lambda (candidate)
                      (and (buffer-live-p candidate)
                           (not (eq candidate buffer))))
                    (mapcar #'car (window-prev-buffers window)))))
           source-windows))
        target)
    (with-selected-frame frame
      (setq target (sk/window-new-stack-window))
      (sk/window-clear-side-state target)
      (set-window-buffer target buffer)
      (dolist (window source-windows)
        (when (and (window-live-p window)
                   (not (eq window target))
                   (eq (window-buffer window) buffer))
          (let ((replacement (cdr (assq window source-replacements))))
            (if (buffer-live-p replacement)
                (set-window-buffer window replacement)
              (switch-to-prev-buffer window)))))
      (select-window target))
    target))

(defun sk/exwm-place-client-for-intent (intent)
  "Move the current EXWM client into the stack recorded by INTENT."
  (let ((buffer (current-buffer))
        (frame (plist-get intent :frame)))
    (exwm-workspace-move-window frame)
    (sk/exwm-display-client-in-stack buffer frame)))

(defun sk/exwm-dispatch-managed-client ()
  "Place the current managed client only when one launch intent matches."
  (when (and sk/exwm-launch-intents (sk/exwm-main-client-p))
    (let* ((pid (exwm-manage-get-pid))
           (intent (sk/exwm-unique-matching-intent
                    pid exwm-class-name exwm-instance-name)))
      (when intent
        (sk/exwm-remove-launch-intent (plist-get intent :token))
        (condition-case err
            (sk/exwm-place-client-for-intent intent)
          (error
           (message "EXWM matched launch could not be placed: %s"
                    (error-message-string err))))))))

(defun sk/exwm-launch-spec-in-stack (spec)
  "Launch validated SPEC and register its stack-placement intent."
  (let* ((command (plist-get spec :command))
         (process
          (apply #'start-process
                 (plist-get spec :process-name) nil (car command) (cdr command))))
    (sk/exwm-register-launch-intent
     process (plist-get spec :matchers) (selected-frame)
     (plist-get spec :allow-live-name-fallback))
    (message "Launching %s in stack" (plist-get spec :process-name))
    process))

(defun sk/exwm-launch-command-in-stack
    (name program args matchers &optional allow-live-name-fallback)
  "Launch PROGRAM with ARGS for NAME and MATCHERS into the current stack."
  (let ((executable (executable-find program)))
    (unless executable
      (user-error "%s is not available" program))
    (sk/exwm-launch-spec-in-stack
     (list :process-name name
           :command (cons executable args)
           :matchers (sk/exwm-normalize-matchers matchers)
           :allow-live-name-fallback allow-live-name-fallback))))

(defun sk/exwm-workspace-index (number)
  (1- number))

(defun sk/exwm-workspace-frame (index)
  "Return workspace frame INDEX through the reviewed EXWM 0.35 adapter."
  (unless (and (boundp 'exwm-workspace--list)
               (listp exwm-workspace--list)
               (frame-live-p (nth index exwm-workspace--list)))
    (user-error "EXWM 0.35 workspace frame contract is unavailable for index %s"
                index))
  (nth index exwm-workspace--list))

(defun sk/exwm-switch-workspace (number)
  (exwm-workspace-switch-create (sk/exwm-workspace-index number)))

(defun sk/exwm-move-window-to-workspace (number)
  (unless (derived-mode-p 'exwm-mode)
    (user-error "Current buffer is not an EXWM window"))
  (let* ((buffer (current-buffer))
         (target-index (sk/exwm-workspace-index number))
         (target-frame (sk/exwm-workspace-frame target-index))
         (target-buffers (and target-frame
                              (delq buffer (sk/window-buffer-list target-frame))))
         (target-master (car target-buffers))
         (target-stack (append (cdr target-buffers) (list buffer))))
    (exwm-workspace-move-window target-index)
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

(defconst sk/picom-emacs-opacity-percent
  (or sk/startup-frame-final-opacity-percent 85)
  "Final Emacs frame opacity shared with the managed Picom policy.")

(defconst sk/picom-opacity-condition
  "class_g = \"Emacs\" && !_NET_WM_WINDOW_OPACITY && !_NET_WM_WINDOW_OPACITY@"
  "Match Emacs only when neither frame nor client owns an opacity property.")

(defconst sk/picom-opacity-rule
  (format "%d:%s" sk/picom-emacs-opacity-percent sk/picom-opacity-condition)
  "Picom opacity rule for Emacs frame transparency.")

(defconst sk/picom-stop-timeout 2.0
  "Seconds to wait for the previous Picom process to stop.")

(defconst sk/picom-start-timeout 2.0
  "Seconds to wait for the replacement Picom compositor to become ready.")

(defun sk/picom--active-pids ()
  "Return this user's non-dead Picom process IDs on the local host."
  (let ((default-directory "/")
        (uid (user-uid)))
    (seq-filter
     (lambda (pid)
       (let ((attributes (process-attributes pid)))
         (and (equal (cdr (assq 'comm attributes)) "picom")
              (equal (cdr (assq 'euid attributes)) uid)
              (not (member (cdr (assq 'state attributes)) '("Z" "X"))))))
     (list-system-processes))))

(defun sk/picom--occupied-p ()
  "Return non-nil while Picom or the X screen-0 compositor owns the session."
  (or (sk/picom--active-pids)
      (and (eq window-system 'x)
           (gui-backend-selection-exists-p '_NET_WM_CM_S0))))

(defun sk/picom--wait-for-stop ()
  "Wait boundedly for Picom and its X compositor selection to clear."
  (let ((deadline (+ (float-time) sk/picom-stop-timeout))
        occupied)
    (while (and (setq occupied (sk/picom--occupied-p))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (not occupied)))

(defun sk/picom--ready-p ()
  "Return non-nil when exactly one Picom owns the X compositor selection."
  (and (= (length (sk/picom--active-pids)) 1)
       (eq window-system 'x)
       (gui-backend-selection-exists-p '_NET_WM_CM_S0)))

(defun sk/picom--wait-for-ready ()
  "Wait boundedly for one Picom and the X compositor selection."
  (let ((deadline (+ (float-time) sk/picom-start-timeout))
        ready)
    (while (and (not (setq ready (sk/picom--ready-p)))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    ready))

(defun sk/start-picom ()
  "Start the session compositor with the managed EXWM opacity rule."
  (interactive)
  (when (executable-find "picom")
    (unless (executable-find "pkill")
      (user-error "Cannot restart Picom without pkill"))
    (let ((status (call-process
                   "pkill" nil nil nil
                   "-u" (number-to-string (user-uid)) "-x" "picom")))
      (unless (memq status '(0 1))
        (user-error "pkill failed while stopping Picom (status %s)" status))
      (unless (sk/picom--wait-for-stop)
        (let ((survivors (sk/picom--active-pids)))
          (user-error
             "Picom/X compositor selection did not clear within %.1f seconds; active PIDs: %s"
             sk/picom-stop-timeout
             (if survivors
                 (mapconcat #'number-to-string survivors ",")
               "none")))))
    ;; `--daemon' returns only after Picom has initialized and forked.  Keep
    ;; this manual restart path aligned with Xinit's compositor-ready contract
    ;; instead of reporting success for an asynchronous process that may fail.
    (let (diagnostics status)
      (with-temp-buffer
        (setq status
              (call-process
               "picom" nil '(t t) nil
               "--config" "/dev/null"
               "--backend" "glx"
               "--vsync"
               "--detect-client-opacity"
               "--opacity-rule" sk/picom-opacity-rule
               "--daemon")
              diagnostics (string-trim (buffer-string))))
      (unless (eq status 0)
        (user-error "Picom failed to initialize (status %s)%s"
                    status
                    (if (string-empty-p diagnostics)
                        ""
                      (format ": %s" diagnostics))))
      (unless (sk/picom--wait-for-ready)
        (ignore-errors
          (call-process
           "pkill" nil nil nil
           "-u" (number-to-string (user-uid)) "-x" "picom"))
        (user-error
         "Picom did not own the compositor selection within %.1f seconds"
         sk/picom-start-timeout)))))

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
  (sk/exwm-launch-command-in-stack "kitty" "kitty" nil '("kitty")))

(defun sk/exwm-launch-browser ()
  (interactive)
  (sk/exwm-launch-command-in-stack
   "browser" "chromium" nil '("chromium" "chromium-browser") t))

(defun sk/exwm-reload ()
  (interactive)
  (sk/reload-modules
   "EXWM config" '("sk-window-policy" "sk-exwm")
   #'sk/exwm-complete-reload))

(defun sk/exwm-complete-reload ()
  "Activate a successfully loaded EXWM policy, then clear old launch intents."
  (sk/exwm-start)
  (sk/exwm-clear-launch-intents "canceled by successful EXWM reload"))

(defun sk/exwm-update-title ()
  (exwm-workspace-rename-buffer
   (string-trim
    (format "%s%s%s"
            (or exwm-class-name "EXWM")
            (if (and exwm-title (not (string-empty-p exwm-title))) ": " "")
            (or exwm-title "")))))

(defun sk/exwm-bind-keys ()
  (exwm-input-set-key (kbd "C-q") #'exwm-input-send-next-key)
  (exwm-input-set-key (kbd "s-SPC") #'sk/exwm-launch-app)
  (exwm-input-set-key (kbd "s-h") #'sk/window-left)
  (exwm-input-set-key (kbd "s-j") #'sk/window-down)
  (exwm-input-set-key (kbd "s-k") #'sk/window-up)
  (exwm-input-set-key (kbd "s-l") #'sk/window-right)
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
  (sk/exwm-assert-compatible)
  (add-hook 'exwm-update-class-hook #'sk/exwm-update-title)
  (add-hook 'exwm-update-title-hook #'sk/exwm-update-title)
  (sk/exwm-bind-keys)
  (sk/set-keyboard-repeat)
  (if (and sk/startup-frame-gate-active-p
           (not sk/startup-frame-gate-release-complete-p)
           (fboundp 'sk/startup-frame-schedule-release))
      (progn
        ;; Early init installs a fail-open scheduler.  Re-arm it only after
        ;; `exwm-wm-mode' has appended the real `exwm--init' window-setup
        ;; function.  The scheduler then returns to the command loop so EXWM's
        ;; deferred idle fullscreen work can finish before transparent frames
        ;; become visible.
        (remove-hook
         'window-setup-hook #'sk/startup-frame-schedule-release)
        (unwind-protect
            (unless exwm-wm-mode
              (exwm-wm-mode 1))
          (unless sk/startup-frame-gate-release-complete-p
            (add-hook
             'window-setup-hook #'sk/startup-frame-schedule-release t))))
    (unless exwm-wm-mode
      (exwm-wm-mode 1))))

(provide 'sk-exwm)

;;; sk-exwm.el ends here
