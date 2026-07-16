;;; startup-attribution-state-check.el --- P2.2 payload check -*- lexical-binding: t; -*-

(require 'json)

(defvar exwm--connection t)
(defvar exwm-wm-mode t)
(defvar server-process nil)
(defvar sk/user-directory nil)
(defvar sk/native-comp-profile-key nil)

(defun sk/exwm-start ()
  "Fixture definition used only for source provenance.")

(defun sk/dashboard-buffer ()
  "Fixture dashboard definition used only for advice-state inspection.")

(defun sk/startup-attribution-state-test-read-one (file)
  "Read and return FILE's sole Lisp form."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((form (read (current-buffer))))
      (condition-case nil
          (progn
            (read (current-buffer))
            (error "payload contains more than one form: %s" file))
        (end-of-file form)))))

(let* ((source-root
        (file-name-as-directory
         (file-truename
          (or (getenv "SK_EMACS_STARTUP_ATTRIBUTION_SOURCE_ROOT")
              (error "SK_EMACS_STARTUP_ATTRIBUTION_SOURCE_ROOT is required")))))
       (trace-file
        (expand-file-name "emacs/lisp/sk-startup-trace.el" source-root))
       (payload-file
        (expand-file-name
         "scripts/emacs-startup-attribution-state.el" source-root))
       (sk-exwm-file
        (expand-file-name "emacs/lisp/sk-exwm.el" source-root))
       (fixture-history
        (list sk-exwm-file '(defun . sk/exwm-start)))
       (server
        (make-pipe-process :name "sk-startup-state-server" :noquery t)))
  (unwind-protect
      (progn
        (unless (equal (getenv "SK_EMACS_STARTUP_TRACE") "p2.2-v1")
          (error "payload fixture requires exact trace activation"))
        (load trace-file nil 'nomessage)
        (push fixture-history load-history)
        (provide 'exwm)
        (setq server-process server
              sk/user-directory (expand-file-name "emacs" source-root)
              user-init-file (expand-file-name "emacs/init.el" source-root)
              sk/native-comp-profile-key
              (file-name-nondirectory
               (directory-file-name (file-truename "~/.guix-home/profile")))
              before-init-time (seconds-to-time 1000)
              after-init-time (seconds-to-time 1001)
              sk/startup-trace-events
              (list
               (list :sequence 1
                     :kind "mark"
                     :name "fixture"
                     :start (seconds-to-time 1000)
                     :end (seconds-to-time 1000)
                     :status "ok"
                     :already-loaded nil
                     :gc-count-delta 0
                     :gc-elapsed-delta 0.0))
              sk/startup-trace-complete-p t)
        (let* ((trace-before (copy-tree sk/startup-trace-events))
               (buffers-before (buffer-list))
               (processes-before (process-list))
               (encoded
                (eval
                 (sk/startup-attribution-state-test-read-one payload-file) t))
               (state
                (json-parse-string encoded
                                   :object-type 'alist
                                   :array-type 'list
                                   :null-object nil
                                   :false-object :false)))
          (unless (and
                   (equal (alist-get 'protocol state)
                          "sk-emacs-startup-attribution-v1")
                   (equal (alist-get 'timer state)
                          "emacs-current-time-realtime")
                   (equal (alist-get 'trace_complete state) "true")
                   (= (alist-get 'event_count state) 1)
                   (= (length (alist-get 'expected_init_features state)) 24)
                   (equal (alist-get 'observer_require_advice state) "false")
                   (equal (alist-get 'observer_hooks state) "false")
                   (= (alist-get 'init_seconds state) 1.0)
                   (equal (alist-get 'source_root state)
                          (file-truename (expand-file-name "emacs" source-root)))
                   (equal (alist-get 'sk_exwm_file state)
                          (file-truename sk-exwm-file)))
            (error "startup attribution payload identity is invalid: %S" state))
          (let ((event (car (alist-get 'events state))))
            (unless (and (= (alist-get 'sequence event) 1)
                         (equal (alist-get 'kind event) "mark")
                         (equal (alist-get 'already_loaded event)
                                "not-applicable")
                         (= (alist-get 'elapsed_seconds event) 0.0))
              (error "startup attribution payload event is invalid: %S" event)))
          (unless (and (equal trace-before sk/startup-trace-events)
                       (equal buffers-before (buffer-list))
                       (equal processes-before (process-list)))
            (error "startup attribution payload changed live state")))
        (princ "emacs-startup-attribution-state-check: PASS\n"))
    (setq load-history (delq fixture-history load-history))
    (when (process-live-p server)
      (delete-process server))))

;;; startup-attribution-state-check.el ends here
