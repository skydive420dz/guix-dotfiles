;;; sk-status.el --- One-shot system status view -*- lexical-binding: t; -*-

;;; Commentary:
;; Asynchronously render the bounded Scheme expression from scripts/sk-status.
;; Collection is explicit: there is no timer, polling, action surface, or cache.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'sk-window-policy)
(defvar sk/user-directory)
(declare-function evil-define-key "evil-core")
(define-error 'sk/status-invalid-output "Invalid sk-status output")
(defconst sk/status-buffer-name "*SK Status*")
(defconst sk/status-program
  (expand-file-name
   "scripts/sk-status"
   (file-name-directory
    (directory-file-name (file-truename sk/user-directory)))))

;; Record/list children consume a field's tail; other fields have one scalar.
(defconst sk/status-schema
  '(record
    (observed-at natural) (overall (enum ok degraded critical))
    (generations
     (record
      (system (record (state component-state) (current positive-or-unknown)
                      (active-current (enum yes no unknown))
                      (booted-current (enum yes no unknown))))
      (home (record (state component-state) (current positive-or-unknown)
                    (active-current (enum yes no unknown))))
      (pull (record (state component-state) (current positive-or-unknown)
                    (active-current (enum yes no unknown))))))
    (desktop
     (record
      (emacs (record (state component-state) (pid positive-or-unknown)
                     (version string-or-unknown)))
      (exwm (record (state component-state) (loaded (enum yes no unknown))
                    (workspaces natural-or-unknown)))))
    (session
     (record (shepherd (record (state component-state)))
             (dbus (record (state component-state)))))
    (audio
     (record (pipewire (record (state component-state)))
             (wireplumber (record (state component-state)))
             (pulse-compat (record (state component-state)))))
    (bluetooth
     (record (state component-state) (controller (enum powered off absent unknown))
             (connected-devices natural-or-unknown)))
    (network
     (record (state component-state) (manager (enum running stopped unknown))
             (connection (enum connected disconnected unknown))
             (connectivity (enum full limited portal none unknown))))
    (storage
     (record
      (capacity
       (record (state component-state) (used-percent natural-or-unknown)
               (available-gib natural-or-unknown)))
      (smart
       (record (state component-state)
               (classification
                (enum favorable failing-indicator unknown unavailable))))
      (trim
       (record (state component-state)
               (schedule (enum sunday-1800 unknown))
               (filesystems (enum ext4 unknown))))))
    (findings (list (record (severity (enum info warning critical)) (code symbol)
                            (summary string) (hint string))))))
(defconst sk/status-render-sections
  '(("Generations" generations
     (("System" system (state current active-current booted-current))
      ("Home" home (state current active-current))
      ("Pull" pull (state current active-current))))
    ("Desktop" desktop
     (("Emacs" emacs (state pid version))
      ("EXWM" exwm (state loaded workspaces))))
    ("Session" session (("Shepherd" shepherd (state)) ("D-Bus" dbus (state))))
    ("Audio" audio
     (("PipeWire" pipewire (state)) ("WirePlumber" wireplumber (state))
      ("Pulse compat" pulse-compat (state))))
    ("Bluetooth" bluetooth (("Controller" nil (state controller connected-devices))))
    ("Network" network
     (("NetworkManager" nil (state manager connection connectivity))))
    ("Storage" storage
     (("Root capacity" capacity (state used-percent available-gib))
      ("Root SMART" smart (state classification))
      ("Weekly TRIM" trim (state schedule filesystems))))))
(defvar-local sk/status--process nil)
(defun sk/status--invalid (detail)
  "Signal invalid output with DETAIL."
  (signal 'sk/status-invalid-output (list detail)))
(defun sk/status--validate-node (value spec)
  "Validate VALUE against declarative SPEC."
  (pcase (car-safe spec)
    ('enum
     (unless (memq value (cdr spec))
       (sk/status--invalid "invalid enum value")))
    ('list
     (unless (proper-list-p value)
       (sk/status--invalid "improper list"))
     (dolist (item value)
       (sk/status--validate-node item (cadr spec))))
    ('record
     (unless (and (proper-list-p value)
                  (cl-every (lambda (field)
                              (and (proper-list-p field)
                                   (consp field) (symbolp (car field))))
                            value))
       (sk/status--invalid "improper record"))
     (let ((keys (mapcar #'car value))
           (expected (mapcar #'car (cdr spec))))
       (unless (and (= (length keys) (length expected))
                    (cl-every (lambda (key) (= (cl-count key keys) 1))
                              expected)
                    (cl-every (lambda (key) (memq key expected)) keys))
         (sk/status--invalid "invalid record fields")))
     (dolist (field-spec (cdr spec))
       (let* ((key (car field-spec))
              (child (cadr field-spec))
              (field (assq key value))
              (payload
               (if (memq (car-safe child) '(record list))
                   (cdr field)
                 (unless (= (length field) 2)
                   (sk/status--invalid "non-scalar field"))
                 (cadr field))))
         (sk/status--validate-node payload child))))
    (_
     (unless
         (pcase spec
           ('natural (and (integerp value) (>= value 0)))
           ('positive-or-unknown
            (or (eq value 'unknown) (and (integerp value) (> value 0))))
           ('natural-or-unknown
            (or (eq value 'unknown) (and (integerp value) (>= value 0))))
           ('string-or-unknown (or (eq value 'unknown) (stringp value)))
           ('component-state (memq value '(ok degraded unavailable unknown)))
           ('symbol (symbolp value))
           ('string (stringp value)))
       (sk/status--invalid "invalid scalar value")))))
(defun sk/status--parse (output)
  "Read, completely consume, and validate one Scheme form from OUTPUT."
  (unless (stringp output)
    (sk/status--invalid "collector output is not text"))
  (with-temp-buffer
    (insert output)
    (goto-char (point-min))
    (let (form)
      (setq form
            (let ((read-circle nil) (read-eval nil))
              (condition-case nil
                  (read (current-buffer))
                (error (sk/status--invalid "unreadable expression")))))
      (skip-chars-forward " \t\r\n")
      (unless (eobp)
        (sk/status--invalid "collector output has trailing data"))
      (unless (and (proper-list-p form) (eq (car form) 'sk-status/v2))
        (sk/status--invalid "unknown top-level schema"))
      (sk/status--validate-node (cdr form) sk/status-schema)
      form)))
(defun sk/status--tail (record key)
  "Return KEY's tail in validated RECORD."
  (cdr (assq key record)))
(defun sk/status--value (record key)
  "Return scalar KEY in validated RECORD."
  (cadr (assq key record)))
(defun sk/status--render (form)
  "Render validated status FORM in the current buffer."
  (let* ((root (cdr form))
         (overall (sk/status--value root 'overall))
         (findings (sk/status--tail root 'findings)))
    (insert "SK Status\n\nObserved: "
            (format-time-string
             "%Y-%m-%d %H:%M:%S %Z"
             (seconds-to-time (sk/status--value root 'observed-at)))
            "\nOverall: " (symbol-name overall) "\n")
    (dolist (section sk/status-render-sections)
      (let ((record (sk/status--tail root (cadr section))))
        (insert "\n" (car section) "\n")
        (dolist (row (caddr section))
          (let ((row-record
                 (if (cadr row)
                     (sk/status--tail record (cadr row))
                   record)))
            (insert (format "  %-14s" (car row)))
            (dolist (key (caddr row))
              (insert (format "  %s=%s" key
                              (sk/status--value row-record key))))
            (insert "\n")))))
    (insert "\nFindings\n")
    (if findings
        (dolist (finding findings)
          (let ((severity (sk/status--value finding 'severity)))
            (insert "  " (upcase (symbol-name severity))
                    " [" (symbol-name (sk/status--value finding 'code)) "] "
                    (sk/status--value finding 'summary) "\n    Hint: "
                    (sk/status--value finding 'hint) "\n")))
      (insert "  None.\n"))
    (insert "\ng refresh    q quit\n")))
(defun sk/status--draw (function)
  "Replace the current view by calling FUNCTION."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (funcall function)
    (goto-char (point-min))))
(defun sk/status--message (heading detail)
  "Render HEADING and DETAIL."
  (sk/status--draw
   (lambda () (insert heading "\n\n" detail "\n"))))
(defun sk/status--finish (process target output error-output)
  "Finish PROCESS for TARGET using OUTPUT, then clean ERROR-OUTPUT."
  (when (memq (process-status process) '(exit signal))
    (unwind-protect
        (when (buffer-live-p target)
          (with-current-buffer target
            (when (eq process sk/status--process)
              (setq sk/status--process nil)
              (if (and (eq (process-status process) 'exit)
                       (zerop (process-exit-status process)))
                  (condition-case nil
                      (let ((form
                             (with-current-buffer output
                               (sk/status--parse (buffer-string)))))
                        (sk/status--draw
                         (lambda () (sk/status--render form))))
                    (error
                     (sk/status--message
                      "SK Status unavailable"
                      "The collector returned an invalid status expression.")))
                (sk/status--message "SK Status unavailable"
                                    "The collector failed.")))))
      (dolist (buffer (list output error-output))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))
(defun sk/status-refresh ()
  "Run one asynchronous refresh in the current status buffer."
  (interactive)
  (when (and sk/status--process (process-live-p sk/status--process))
    (user-error "A status refresh is already running"))
  (let ((target (current-buffer))
        (output (generate-new-buffer " *sk-status-output*"))
        (error-output (generate-new-buffer " *sk-status-error*")))
    (sk/status--message "SK Status" "Collecting one read-only snapshot...")
    (condition-case nil
        (setq sk/status--process
              (make-process
               :name "sk-status" :buffer output
               :command (list sk/status-program) :connection-type 'pipe
               :coding 'utf-8-unix :noquery t :stderr error-output
               :sentinel
               (lambda (process _event)
                 (sk/status--finish process target output error-output))))
      (error
       (dolist (buffer (list output error-output))
         (when (buffer-live-p buffer) (kill-buffer buffer)))
       (sk/status--message
        "SK Status unavailable"
        "The read-only collector could not be started.")
       nil))))
(defvar sk/status-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'sk/status-refresh)
    (define-key map (kbd "q") #'quit-window)
    map))
(define-derived-mode sk/status-mode special-mode "SK-Status"
  "Major mode for the one-shot system status view."
  (setq-local buffer-read-only t truncate-lines t))
(with-eval-after-load 'evil
  (evil-define-key '(normal motion) sk/status-mode-map
    (kbd "g") #'sk/status-refresh
    (kbd "q") #'quit-window))
;;;###autoload
(defun sk/status ()
  "Display the status utility window and collect one fresh snapshot."
  (interactive)
  (let ((buffer (get-buffer-create sk/status-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'sk/status-mode) (sk/status-mode))
      (unless (and sk/status--process (process-live-p sk/status--process))
        (sk/status-refresh)))
    (select-window (sk/window-display-right buffer))
    buffer))
(provide 'sk-status)
;;; sk-status.el ends here
