;;; emacs-startup-attribution-state.el --- Read-only startup trace payload -*- lexical-binding: t; -*-

;; This single expression is sent to the already-running EXWM server.  It reads
;; the sealed one-shot trace and live provenance only; it must not load a
;; feature, create a buffer/process, emit a message, or modify trace state.

(let* ((trace-events
        (and (boundp 'sk/startup-trace-events)
             sk/startup-trace-events))
       (events-chronological
        (and trace-events
             (sort
              (copy-sequence trace-events)
              #'sk/startup-trace--event-less-p)))
       (trace-complete
        (and (boundp 'sk/startup-trace-complete-p)
             sk/startup-trace-complete-p))
       (trace-enabled
        (and (boundp 'sk/startup-trace-enabled-p)
             sk/startup-trace-enabled-p))
       (source-root
        (and (boundp 'sk/user-directory)
             (stringp sk/user-directory)
             (file-truename sk/user-directory)))
       (resolved-init
        (and (stringp user-init-file) (file-truename user-init-file)))
       (sk-exwm-source
        (when-let ((source (symbol-file 'sk/exwm-start 'defun)))
          (file-truename source)))
       (running-executable
        (file-truename
         (expand-file-name invocation-name invocation-directory)))
       (home-profile (file-truename "~/.guix-home/profile"))
       (native-key
        (and (boundp 'sk/native-comp-profile-key)
             sk/native-comp-profile-key))
       (exwm-connected
        (and (boundp 'exwm--connection) exwm--connection t))
       (exwm-mode
        (and (boundp 'exwm-wm-mode) exwm-wm-mode t))
       (server-live
        (and (boundp 'server-process)
             (process-live-p server-process)
             t))
       (expected-features
        (and (boundp 'sk/startup-trace-expected-init-features)
             sk/startup-trace-expected-init-features)))
  (unless (and trace-enabled trace-complete trace-events
               before-init-time after-init-time
               source-root resolved-init sk-exwm-source native-key
               expected-features
               (featurep 'exwm) exwm-connected exwm-mode server-live)
    (error "complete attributed EXWM startup/source identity is unavailable"))
  (json-serialize
   `((protocol . ,sk/startup-trace-protocol)
     (timer . "emacs-current-time-realtime")
     (trace_activation . ,sk/startup-trace-activation)
     (trace_complete . "true")
     (pid . ,(emacs-pid))
     (version . ,emacs-version)
     (started_utc . ,(format-time-string "%Y-%m-%dT%H:%M:%SZ"
                                         before-init-time t))
     (before_init_seconds . ,(float-time before-init-time))
     (after_init_seconds . ,(float-time after-init-time))
     (init_seconds
      . ,(float-time (time-subtract after-init-time before-init-time)))
     (event_count . ,(length events-chronological))
     (expected_init_features
      . ,(vconcat (mapcar #'symbol-name expected-features)))
     (events
      . ,(vconcat
          (mapcar
           (lambda (event)
             (let* ((kind (plist-get event :kind))
                    (started (plist-get event :start))
                    (ended (plist-get event :end))
                    (already-loaded (plist-get event :already-loaded)))
               `((sequence . ,(plist-get event :sequence))
                 (kind . ,kind)
                 (name . ,(plist-get event :name))
                 (start_seconds . ,(float-time started))
                 (end_seconds . ,(float-time ended))
                 (elapsed_seconds
                  . ,(float-time (time-subtract ended started)))
                 (status . ,(plist-get event :status))
                 (already_loaded
                  . ,(if (equal kind "require")
                         (if already-loaded "true" "false")
                       "not-applicable"))
                 (gc_count_delta . ,(plist-get event :gc-count-delta))
                 (gc_elapsed_seconds
                  . ,(plist-get event :gc-elapsed-delta)))))
           events-chronological)))
     (source_root . ,source-root)
     (user_init_file . ,resolved-init)
     (sk_exwm_file . ,sk-exwm-source)
     (running_executable . ,running-executable)
     (home_profile . ,home-profile)
     (native_profile_key . ,native-key)
     (gc_cons_threshold . ,gc-cons-threshold)
     (gc_cons_percentage . ,gc-cons-percentage)
     (exwm_loaded . "true")
     (exwm_connected . "true")
     (exwm_wm_mode . "true")
     (server_running . "true")
     (observer_require_advice
      . ,(if (advice-member-p #'sk/startup-trace--require-around 'require)
             "true" "false"))
     (observer_dashboard_advice
      . ,(if (and (fboundp 'sk/dashboard-buffer)
                  (advice-member-p #'sk/startup-trace--dashboard-around
                                   'sk/dashboard-buffer))
             "true" "false"))
     (observer_exwm_mode_advice
      . ,(if (and (fboundp 'exwm-wm-mode)
                  (advice-member-p #'sk/startup-trace--exwm-mode-around
                                   'exwm-wm-mode))
             "true" "false"))
     (observer_hooks
      . ,(if (or (memq #'sk/startup-trace--after-init-hook after-init-hook)
                 (memq #'sk/startup-trace--emacs-startup-hook
                       emacs-startup-hook)
                 (memq #'sk/startup-trace--window-setup-hook
                       window-setup-hook))
             "true" "false")))))

;;; emacs-startup-attribution-state.el ends here
