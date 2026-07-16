;;; emacs-performance-state.el --- Observational EXWM state payload -*- lexical-binding: t; -*-

;; This file is sent as one expression to the running server.  It must not load
;; features, create buffers or processes, force GC, or change live variables.

(let* ((attributes (process-attributes (emacs-pid)))
       (messages (get-buffer "*Messages*"))
       (exwm-connected
        (and (boundp 'exwm--connection) exwm--connection t))
       (exwm-mode
        (and (boundp 'exwm-wm-mode) exwm-wm-mode t))
       (server-live
        (and (boundp 'server-process)
             (process-live-p server-process)
             t))
       (source-root
        (and (boundp 'sk/user-directory)
             (stringp sk/user-directory)
             (file-truename sk/user-directory)))
       (resolved-init
        (and (stringp user-init-file) (file-truename user-init-file)))
       (sk-exwm-source
        (when-let ((source (symbol-file 'sk/exwm-launch-app 'defun)))
          (file-truename source)))
       (running-executable
        (file-truename
         (expand-file-name invocation-name invocation-directory)))
       (home-profile (file-truename "~/.guix-home/profile"))
       (native-key
        (and (boundp 'sk/native-comp-profile-key)
             sk/native-comp-profile-key))
       (cache-fingerprint
        (secure-hash
         'sha256
         (prin1-to-string
          (list
           (and (boundp 'counsel--linux-apps-cache)
                counsel--linux-apps-cache)
           (and (boundp 'counsel--linux-apps-cached-files)
                counsel--linux-apps-cached-files)
           (and (boundp 'counsel--linux-apps-cache-timestamp)
                counsel--linux-apps-cache-timestamp)
           (and (boundp 'counsel--linux-apps-cache-format-function)
                counsel--linux-apps-cache-format-function)
           (and (boundp 'counsel-linux-apps-faulty)
                counsel-linux-apps-faulty))))))
  (unless (and before-init-time after-init-time source-root resolved-init
               sk-exwm-source native-key
               (featurep 'exwm) exwm-connected exwm-mode server-live)
    (error "live EXWM/server/source identity is incomplete"))
  (json-serialize
   `((protocol . "sk-emacs-performance-state-v1")
     (pid . ,(emacs-pid))
     (version . ,emacs-version)
     (init_seconds
      . ,(float-time (time-subtract after-init-time before-init-time)))
     (started_utc . ,(format-time-string "%Y-%m-%dT%H:%M:%SZ"
                                         before-init-time t))
     (uptime_seconds
      . ,(float-time (time-subtract (current-time) before-init-time)))
     (gc_count . ,gcs-done)
     (gc_elapsed_seconds . ,gc-elapsed)
     (gc_cons_threshold . ,gc-cons-threshold)
     (gc_cons_percentage . ,gc-cons-percentage)
     (rss_kib . ,(or (alist-get 'rss attributes) 0))
     (vsize_kib . ,(or (alist-get 'vsize attributes) 0))
     (buffer_count . ,(length (buffer-list)))
     (frame_count . ,(length (frame-list)))
     (visible_frame_count . ,(length (visible-frame-list)))
     (process_count . ,(length (process-list)))
     (pending_launch_intents
      . ,(if (boundp 'sk/exwm-launch-intents)
             (length sk/exwm-launch-intents)
           -1))
     (messages_bytes
      . ,(if messages (with-current-buffer messages (buffer-size)) 0))
     (exwm_loaded . ,(if (featurep 'exwm) "true" "false"))
     (exwm_connected . ,(if exwm-connected "true" "false"))
     (exwm_wm_mode . ,(if exwm-mode "true" "false"))
     (server_running . ,(if server-live "true" "false"))
     (source_root . ,source-root)
     (user_init_file . ,resolved-init)
     (sk_exwm_file . ,sk-exwm-source)
     (running_executable . ,running-executable)
     (home_profile . ,home-profile)
     (native_profile_key . ,native-key)
     (message_advice
      . ,(if (and (fboundp 'sk/log--message-around)
                  (advice-member-p #'sk/log--message-around #'message))
             "true"
           "false"))
     (counsel_loaded . ,(if (featurep 'counsel) "true" "false"))
     (counsel_cache_fingerprint . ,cache-fingerprint))))
