;;; early-init.el --- First-frame and profile startup policy -*- lexical-binding: t; -*-

;; Establish creation-time visual state before Emacs constructs its first X
;; frame.  GUI-dependent mode calls remain in sk-ui after graphical startup.
;; Native-compiled Lisp is tied to the Emacs and package profile that produced
;; it, so each Guix Home profile also receives its own XDG cache.

;; P2.2's startup observer is opt-in and one-shot.  Ordinary sessions take only
;; this exact string comparison; they do not load the observer or install any
;; hook/advice.  An attributed session retains its trace in memory for a later
;; read-only client extraction.
(when (equal (getenv "SK_EMACS_STARTUP_TRACE") "p2.2-v1")
  (let* ((observer-started (current-time))
         (gc-count-start gcs-done)
         (gc-elapsed-start gc-elapsed)
         ;; The live entrypoint is a ~/.emacs.d symlink into this repository.
         ;; Resolve that link before locating the adjacent lisp directory;
         ;; user-emacs-directory deliberately remains ~/.emacs.d here.
         (early-init-source
          (file-truename
           (or load-file-name buffer-file-name
               (locate-user-emacs-file "early-init.el"))))
         (early-init-source-directory
          (file-name-directory early-init-source)))
    (load (expand-file-name "lisp/sk-startup-trace.el"
                            early-init-source-directory)
          nil t)
    (sk/startup-trace-bootstrap observer-started
                                gc-count-start gc-elapsed-start)))

(setq inhibit-startup-message t
      inhibit-startup-screen t)

(require 'subr-x)

(defconst sk/startup-frame-opacity-environment-variable
  "SK_EMACS_STARTUP_OPACITY_PERCENT"
  "One-shot X-session variable that requests a mapped transparent first frame.")

(defun sk/startup-frame--opacity-from-environment ()
  "Return the validated startup opacity percentage, or nil.
The X-session owner exports the variable only after Picom is ready."
  (when-let ((raw
              (getenv sk/startup-frame-opacity-environment-variable)))
    (if (string-match-p "\\`[0-9]+\\'" raw)
        (let ((percent (string-to-number raw)))
          (when (<= 1 percent 100)
            percent))
      nil)))

(defconst sk/startup-frame-final-opacity-percent
  (sk/startup-frame--opacity-from-environment)
  "Final Emacs opacity requested by the one-shot X-session gate, or nil.")

(defconst sk/startup-frame-saved-alpha-lower-limit
  frame-alpha-lower-limit
  "Alpha floor in effect before the one-shot startup gate.")

(defvar sk/startup-frame-gate-active-p
  (numberp sk/startup-frame-final-opacity-percent)
  "Non-nil while startup frames must remain transparent but mapped.")

(defvar sk/startup-frame-gate-release-complete-p nil
  "Non-nil after the one-shot startup frame gate has been released.")

(defconst sk/startup-frame-gate-watchdog-seconds 30
  "Seconds before the startup opacity gate fails open automatically.")

(defconst sk/startup-frame-geometry-timeout 2.0
  "Seconds to wait for EXWM frame ConfigureNotify events before reveal.")

(defvar sk/startup-frame-gate-watchdog-timer nil
  "One-shot fail-open timer for an interrupted window-setup hook chain.")

(defvar sk/startup-frame-gate-release-timer nil
  "Pending idle or polling timer for the normal startup-frame release.")

(defvar sk/startup-frame-geometry-deadline nil
  "Absolute time after which geometry polling must fail open.")

(defun sk/startup-frame--arm-watchdog ()
  "Arm the graphical startup gate's bounded fail-open watchdog once."
  (when (and sk/startup-frame-gate-active-p
             ;; Early init runs before Emacs constructs the first X frame, so
             ;; `display-graphic-p' still observes the terminal frame here.
             (eq initial-window-system 'x)
             (not (timerp sk/startup-frame-gate-watchdog-timer)))
    (condition-case error-data
        (let ((timer
               (run-at-time sk/startup-frame-gate-watchdog-seconds nil
                            #'sk/startup-frame--watchdog-release)))
          (unless (timerp timer)
            (error "timer registration returned %S" timer))
          (setq sk/startup-frame-gate-watchdog-timer timer))
      (error
       (sk/startup-frame--warn
        "Could not schedule startup-frame watchdog: %s"
        error-data)
       (sk/startup-frame--finish-release)))))

(defun sk/startup-frame--warn-text (message)
  "Display startup warning MESSAGE without risking the release path."
  (ignore-errors
    (display-warning 'sk-startup message :warning)))

(defun sk/startup-frame--warn (format-string error-data)
  "Best-effort startup warning from FORMAT-STRING and ERROR-DATA."
  (sk/startup-frame--warn-text
   (format format-string (error-message-string error-data))))

(defun sk/startup-frame--set-opacity (frame percent)
  "Set graphical FRAME to opacity PERCENT.
Return non-nil when the requested value or an opaque fail-open value succeeds."
  (if (not (and (frame-live-p frame)
                (display-graphic-p frame)))
      t
    (condition-case error-data
        (progn
          (set-frame-parameter frame 'alpha percent)
          t)
      (error
       (let ((fallback-succeeded-p
              (condition-case nil
                  (progn
                    (set-frame-parameter frame 'alpha 100)
                    t)
                (error nil))))
         (sk/startup-frame--warn
          "Could not restore requested frame opacity: %s"
          error-data)
         fallback-succeeded-p)))))

(defun sk/startup-frame--force-opaque ()
  "Best-effort opaque release for every current graphical frame."
  (condition-case nil
      (let ((succeeded-p t))
        (dolist (frame (frame-list))
          (when (and (frame-live-p frame)
                     (display-graphic-p frame))
            (condition-case nil
                (set-frame-parameter frame 'alpha 100)
              (error (setq succeeded-p nil)))))
        succeeded-p)
    (error nil)))

(defun sk/startup-frame--geometry-ready-p ()
  "Return non-nil when every active graphical frame has final geometry.
EXWM intentionally keeps inactive workspace containers at 1x1 and may leave
their outer-frame size cached until activation.  Only selected or EXWM-active
frames can paint during the startup reveal."
  (condition-case nil
      (let ((selected (selected-frame))
            (active-count 0)
            (ready-p t))
        (dolist (frame (frame-list))
          (when (and (frame-live-p frame)
                     (display-graphic-p frame)
                     (or (eq frame selected)
                         (frame-parameter frame 'exwm-active)))
            (setq active-count (1+ active-count))
            (let ((geometry (frame-monitor-attribute 'geometry frame)))
              (unless (and (eq (frame-parameter frame 'fullscreen) 'fullboth)
                           (listp geometry)
                           (= (length geometry) 4)
                           (= (frame-pixel-width frame) (nth 2 geometry))
                           (= (frame-pixel-height frame) (nth 3 geometry)))
                (setq ready-p nil)))))
        (and (> active-count 0) ready-p))
    (error nil)))

(defun sk/startup-frame--stop-compositor ()
  "Best-effort last-resort stop of this user's Picom compositor.
When Emacs cannot change an alpha-zero X property, removing the compositor
makes raw X ignore that property and restores a visible desktop."
  (when-let ((pkill (executable-find "pkill")))
    (condition-case error-data
        (let ((status
               (call-process
                pkill nil nil nil
                "-u" (number-to-string (user-uid)) "-x" "picom")))
          (if (memq status '(0 1))
              t
            (sk/startup-frame--warn-text
             (format
              "Could not stop Picom after opacity-release failure (status %s)"
              status))
            nil))
      (error
       (sk/startup-frame--warn
        "Could not stop Picom after opacity-release failure: %s"
        error-data)
       nil))))

(defun sk/startup-frame-schedule-release ()
  "Schedule the normal reveal after EXWM's deferred fullscreen timers."
  (remove-hook 'window-setup-hook #'sk/startup-frame-schedule-release)
  (when (and sk/startup-frame-gate-active-p
             (not sk/startup-frame-gate-release-complete-p))
    (setq sk/startup-frame-geometry-deadline
          (+ (float-time) sk/startup-frame-geometry-timeout))
    (unless (timerp sk/startup-frame-gate-release-timer)
      ;; EXWM creates each workspace's fullscreen operation as an idle timer.
      ;; Queue the reveal only after `exwm--init' has returned and registered
      ;; those timers, instead of blocking the window-setup hook that they need
      ;; to become runnable.
      (condition-case error-data
          (let ((timer
                 (run-with-idle-timer 0 nil #'sk/startup-frame-release)))
            (unless (timerp timer)
              (error "timer registration returned %S" timer))
            (setq sk/startup-frame-gate-release-timer timer))
        (error
         (sk/startup-frame--warn
          "Could not schedule startup-frame idle release: %s"
          error-data)
         (sk/startup-frame--finish-release))))))

(defun sk/startup-frame--finish-release ()
  "Reveal the mapped startup frames and remove every one-shot owner.
Inactive frames are restored first and the selected frame last, so the
foreground changes only after the other EXWM workspaces are ready."
  (let (released-p)
    (unwind-protect
        (let* ((selected (selected-frame))
               (other-frames (delq selected (copy-sequence (frame-list))))
               (percent (or sk/startup-frame-final-opacity-percent 100))
               (all-restored-p t))
          ;; Paint the final dashboard/workspace contents into transparent
          ;; frames before changing their compositor opacity.
          (condition-case error-data
              ;; Unlike `(redisplay t)', `redraw-display' explicitly clears
              ;; and redraws every visible frame.  All EXWM workspace frames
              ;; are mapped at this point but remain compositor-transparent.
              (redraw-display)
            (error
             (sk/startup-frame--warn
              "Could not pre-render startup frames: %s"
              error-data)))
          (dolist (frame other-frames)
            (unless (sk/startup-frame--set-opacity frame percent)
              (setq all-restored-p nil)))
          (unless (sk/startup-frame--set-opacity selected percent)
            (setq all-restored-p nil))
          (setq released-p all-restored-p
                sk/startup-frame-gate-release-complete-p all-restored-p))
      (unless released-p
        (setq released-p (sk/startup-frame--force-opaque)
              sk/startup-frame-gate-release-complete-p released-p)
        (unless released-p
          ;; A persistent X alpha write failure otherwise leaves Picom
          ;; compositing an alpha-zero frame.  Stopping only this user's Picom
          ;; is the last best-effort route back to raw, visible X; runtime
          ;; acceptance still fails because the managed compositor is absent.
          (unless (sk/startup-frame--stop-compositor)
            (sk/startup-frame--warn-text
             "Startup opacity release failed and Picom could not be stopped"))))
      (setq initial-frame-alist
            (assq-delete-all 'alpha initial-frame-alist)
            default-frame-alist
            (assq-delete-all 'alpha default-frame-alist)
            frame-alpha-lower-limit
            sk/startup-frame-saved-alpha-lower-limit
            sk/startup-frame-gate-active-p nil
            sk/startup-frame-geometry-deadline nil)
      (setenv sk/startup-frame-opacity-environment-variable nil)
      (remove-hook 'window-setup-hook #'sk/startup-frame-schedule-release)
      (when (timerp sk/startup-frame-gate-release-timer)
        (cancel-timer sk/startup-frame-gate-release-timer))
      (setq sk/startup-frame-gate-release-timer nil)
      (when (timerp sk/startup-frame-gate-watchdog-timer)
        (cancel-timer sk/startup-frame-gate-watchdog-timer))
      (setq sk/startup-frame-gate-watchdog-timer nil))))

(defun sk/startup-frame--watchdog-release ()
  "Fail open immediately when the startup-frame watchdog fires.
This deliberately bypasses geometry polling so the watchdog remains an
independent visibility bound even if the system clock moves backward."
  (when (and sk/startup-frame-gate-active-p
             (not sk/startup-frame-gate-release-complete-p))
    (sk/startup-frame--warn-text
     "Startup-frame watchdog forced the opacity gate open")
    (sk/startup-frame--finish-release)))

(defun sk/startup-frame-release ()
  "Reveal ready startup frames, or poll again without blocking idle timers."
  (when (and sk/startup-frame-gate-active-p
             (not sk/startup-frame-gate-release-complete-p))
    (when (timerp sk/startup-frame-gate-release-timer)
      (cancel-timer sk/startup-frame-gate-release-timer))
    (setq sk/startup-frame-gate-release-timer nil)
    (let ((geometry-ready-p (sk/startup-frame--geometry-ready-p)))
      (if (and (not geometry-ready-p)
               sk/startup-frame-geometry-deadline
               (< (float-time) sk/startup-frame-geometry-deadline))
          ;; Return to the command loop so EXWM's remaining idle fullscreen
          ;; operations and X ConfigureNotify events can run before retrying.
          (condition-case error-data
              (let ((timer
                     (run-at-time 0.05 nil #'sk/startup-frame-release)))
                (unless (timerp timer)
                  (error "timer registration returned %S" timer))
                (setq sk/startup-frame-gate-release-timer timer))
            (error
             (sk/startup-frame--warn
              "Could not schedule startup-frame geometry retry: %s"
              error-data)
             (sk/startup-frame--finish-release)))
        (unless geometry-ready-p
          (sk/startup-frame--warn-text
           "Startup frame geometry did not settle before the reveal timeout"))
        (sk/startup-frame--finish-release)))))

(defconst sk/early-frame-parameters
  (append
   '((menu-bar-lines . 0)
     (tool-bar-lines . 0)
     (vertical-scroll-bars . nil)
     (horizontal-scroll-bars . nil)
     (left-fringe . 10)
     (right-fringe . 10)
     (fullscreen . fullboth)
     (undecorated . t))
   (when sk/startup-frame-gate-active-p
     '((alpha . 0))))
  "Creation-time parameters for the initial and later EXWM frames.")

(when sk/startup-frame-gate-active-p
  ;; Emacs otherwise clamps zero opacity to its default 20-percent floor.
  (setq frame-alpha-lower-limit 0)
  ;; This early scheduler fails open through the watchdog if the later EXWM
  ;; module cannot reorder it behind real window-setup initialization.
  (add-hook 'window-setup-hook #'sk/startup-frame-schedule-release t))

(dolist (parameter sk/early-frame-parameters)
  ;; Delete prior values so each creation-time property has one owner.
  (setq default-frame-alist
        (cons parameter
              (assq-delete-all (car parameter) default-frame-alist))
        initial-frame-alist
        (cons parameter
              (assq-delete-all (car parameter) initial-frame-alist))))

(when sk/startup-frame-gate-active-p
  ;; Install every alpha owner before arming a watchdog whose own registration
  ;; failure deliberately invokes the complete fail-open cleanup immediately.
  ;; A later hook that aborts `run-hooks' still gets a best-effort release at
  ;; the first timer-service opportunity after thirty seconds.  The timer
  ;; cannot preempt a synchronous Emacs hang, but it covers ordinary hook
  ;; errors and deliberately prefers visibility over polish.  Batch and
  ;; terminal-only Emacs sessions do not need a timer because no graphical
  ;; frame can be hidden.
  (sk/startup-frame--arm-watchdog))

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

(defun sk/load-generated-theme (&optional file)
  "Load immutable generated theme FILE once.
FILE defaults to `sk/theme-generated-file'.  Mutable lookalikes are ignored."
  (let ((file (or file sk/theme-generated-file)))
    (when (and (not (featurep 'sk-theme-generated))
               (sk/immutable-store-file-p file))
      (load file nil 'nomessage)
      (featurep 'sk-theme-generated))))

(defun sk/native-comp--profile-key (&optional profile)
  "Return PROFILE's resolved basename, or nil when it is unavailable.
PROFILE defaults to the current Guix Home package profile."
  (let ((profile (or profile
                     (expand-file-name "~/.guix-home/profile"))))
    (condition-case nil
        (when (file-exists-p profile)
          (file-name-nondirectory
           (directory-file-name (file-truename profile))))
      (file-error nil))))

(defun sk/native-comp--running-emacs-key ()
  "Return a collision-resistant cache key for the running Emacs."
  (let* ((executable
          (expand-file-name (or invocation-name "emacs")
                            (or invocation-directory default-directory)))
         (resolved-executable
          (condition-case nil
              (file-truename executable)
            (file-error executable)))
         (identity
          (mapconcat #'identity
                     (list emacs-version system-configuration
                           resolved-executable)
                     "\0"))
         (version
          (replace-regexp-in-string "[^[:alnum:]._-]" "_" emacs-version)))
    (format "emacs-%s-%s" version (secure-hash 'sha256 identity))))

(defun sk/native-comp--cache-key (&optional profile)
  "Return PROFILE's key or the running-Emacs fallback.
PROFILE defaults to the current Guix Home package profile."
  (or (sk/native-comp--profile-key profile)
      (sk/native-comp--running-emacs-key)))

(defconst sk/native-comp-profile-key
  (sk/native-comp--cache-key)
  "Cache identity for the current Guix Home profile or running Emacs.")

(defconst sk/native-comp-cache-directory
  (let ((xdg-cache-home (getenv "XDG_CACHE_HOME")))
    (file-name-as-directory
     (expand-file-name
      sk/native-comp-profile-key
      (expand-file-name
       "emacs/eln-cache/"
       (if (and xdg-cache-home
                (file-name-absolute-p xdg-cache-home))
           xdg-cache-home
         "~/.cache/")))))
  "Profile-scoped directory for user native-comp artifacts.")

(defconst sk/native-comp-legacy-cache-directory
  (file-name-as-directory
   (expand-file-name "eln-cache" user-emacs-directory))
  "Legacy native-comp directory that must never remain a fallback.")

(when (and (fboundp 'startup-redirect-eln-cache)
           (boundp 'native-comp-eln-load-path))
  (make-directory sk/native-comp-cache-directory t)
  (startup-redirect-eln-cache sk/native-comp-cache-directory)
  ;; `startup-redirect-eln-cache' puts the selected cache first.  Delete any
  ;; legacy fallback explicitly while retaining every Guix-provided
  ;; native-site-lisp entry and its ordering.
  (setq native-comp-eln-load-path
        (delete sk/native-comp-legacy-cache-directory
                native-comp-eln-load-path)))

;; Before P3.4 activation this file is absent and sk-ui retains the exact
;; legacy Iosevka/Modus behavior.  Never load a mutable lookalike from
;; ~/.config.  Load after native-cache redirection but before frame creation.
(sk/load-generated-theme)

(when (fboundp 'sk/startup-trace-mark)
  (sk/startup-trace-mark "early-init-exit"))

;;; early-init.el ends here
