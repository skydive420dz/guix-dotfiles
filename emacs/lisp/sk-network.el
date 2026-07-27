;;; sk-network.el --- Bounded NetworkManager control panel -*- lexical-binding: t; -*-

;;; Commentary:
;; Present the repository's Guile nmcli facade and retain
;; nm-connection-editor for new networks and secrets.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'sk-window-policy)

(defvar sk/user-directory)
(declare-function evil-define-key "evil-core")

(define-error 'sk/network-invalid-output "Invalid sk-network output")

(defconst sk/network-buffer-name "*SK Network*")
(defconst sk/network-program
  (expand-file-name
   "scripts/sk-network"
   (file-name-directory
    (directory-file-name (file-truename sk/user-directory)))))
(defconst sk/network-editor-program
  "/run/current-system/profile/bin/nm-connection-editor")

(defvar-local sk/network--process nil)
(defvar-local sk/network--snapshot nil)

(defun sk/network--invalid (detail)
  "Signal invalid collector output with DETAIL."
  (signal 'sk/network-invalid-output (list detail)))

(defun sk/network--value (record key)
  "Return scalar KEY from RECORD or reject it."
  (let ((entries (seq-filter (lambda (entry) (eq (car-safe entry) key))
                             record)))
    (unless (and (= (length entries) 1)
                 (= (length (car entries)) 2))
      (sk/network--invalid "invalid record field"))
    (cadar entries)))

(defun sk/network--safe-string-p (value)
  "Return non-nil when VALUE is bounded display text."
  (and (stringp value)
       (<= 1 (length value) 256)
       (not (string-match-p "[[:cntrl:]]" value))))

(defun sk/network--valid-scalar-p (value type)
  "Return non-nil when VALUE satisfies TYPE."
  (pcase type
    ('string (sk/network--safe-string-p value))
    ('uuid
     (and
      (stringp value)
      (string-match-p
       "\\`[[:xdigit:]]\\{8\\}-[[:xdigit:]]\\{4\\}-[[:xdigit:]]\\{4\\}-[[:xdigit:]]\\{4\\}-[[:xdigit:]]\\{12\\}\\'"
       value)))
    ('signal (and (integerp value) (<= 0 value 100)))
    (`(enum . ,members) (memq value members))
    (_ nil)))

(defun sk/network--validate-record (record schema)
  "Validate RECORD against fixed scalar SCHEMA."
  (unless (and (proper-list-p record)
               (= (length record) (length schema))
               (cl-every
                (lambda (entry)
                  (and (proper-list-p entry)
                       (= (length entry) 2)
                       (symbolp (car entry))))
                record))
    (sk/network--invalid "invalid record"))
  (dolist (field schema)
    (unless
        (sk/network--valid-scalar-p
         (sk/network--value record (car field)) (cadr field))
      (sk/network--invalid "invalid scalar value"))))

(defconst sk/network--manager-schema
  '((running (enum yes no unknown))
    (state string)
    (connectivity string)))

(defconst sk/network--wifi-schema
  '((hardware (enum enabled disabled unknown))
    (radio (enum enabled disabled unknown))))

(defconst sk/network--device-schema
  '((name string)
    (kind (enum wifi ethernet loopback other))
    (state string)
    (connection (enum none))))

(defconst sk/network--connection-schema
  '((uuid uuid)
    (name string)
    (kind (enum wifi ethernet))
    (active (enum yes no))))

(defconst sk/network--access-point-schema
  '((ssid string)
    (signal signal)
    (security string)
    (active (enum yes no))))

(defun sk/network--validate-device (record)
  "Validate one device RECORD, including its optional connection name."
  (let ((connection
         (condition-case nil
             (sk/network--value record 'connection)
           (error nil))))
    (if (stringp connection)
        (sk/network--validate-record
         record
         '((name string)
           (kind (enum wifi ethernet loopback other))
           (state string)
           (connection string)))
      (sk/network--validate-record record sk/network--device-schema))))

(defun sk/network--parse (output)
  "Read and validate one NetworkManager snapshot from OUTPUT."
  (unless (stringp output)
    (sk/network--invalid "output is not text"))
  (with-temp-buffer
    (insert output)
    (goto-char (point-min))
    (let ((form
           (let ((read-circle nil))
             (condition-case nil
                 (read (current-buffer))
               (error (sk/network--invalid "unreadable expression"))))))
      (skip-chars-forward " \t\r\n")
      (unless (eobp)
        (sk/network--invalid "trailing output"))
      (unless (and (proper-list-p form)
                   (= (length form) 6)
                   (eq (car form) 'sk-network/v1)
                   (equal (mapcar #'car-safe (cdr form))
                          '(manager wifi devices connections access-points)))
        (sk/network--invalid "invalid top-level form"))
      (sk/network--validate-record
       (cdr (nth 1 form)) sk/network--manager-schema)
      (sk/network--validate-record
       (cdr (nth 2 form)) sk/network--wifi-schema)
      (dolist (record (cdr (nth 3 form)))
        (sk/network--validate-device record))
      (dolist (record (cdr (nth 4 form)))
        (sk/network--validate-record
         record sk/network--connection-schema))
      (dolist (record (cdr (nth 5 form)))
        (sk/network--validate-record
         record sk/network--access-point-schema))
      (let ((ids
             (mapcar
              (lambda (record) (sk/network--value record 'uuid))
              (cdr (nth 4 form)))))
        (unless (= (length ids) (length (delete-dups (copy-sequence ids))))
          (sk/network--invalid "duplicate connection identifier")))
      form)))

(defun sk/network--section (index)
  "Return snapshot section INDEX or report that status is not ready."
  (unless sk/network--snapshot
    (user-error "Network status is not ready; press g"))
  (cdr (nth index sk/network--snapshot)))

(defun sk/network--display (function)
  "Replace the panel contents by calling FUNCTION."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (funcall function)
    (goto-char (point-min))))

(defun sk/network--text (value)
  "Return VALUE as compact display text."
  (if (symbolp value) (symbol-name value) value))

(defun sk/network--render (snapshot)
  "Render validated SNAPSHOT in the current panel."
  (setq sk/network--snapshot snapshot)
  (let ((manager (cdr (nth 1 snapshot)))
        (wifi (cdr (nth 2 snapshot)))
        (devices (cdr (nth 3 snapshot)))
        (connections (cdr (nth 4 snapshot)))
        (access-points (cdr (nth 5 snapshot))))
    (sk/network--display
     (lambda ()
       (insert
        "SK Network\n\n"
        "NetworkManager: running="
        (sk/network--text (sk/network--value manager 'running))
        "  state=" (sk/network--value manager 'state)
        "  connectivity=" (sk/network--value manager 'connectivity)
        "\nWi-Fi: hardware="
        (sk/network--text (sk/network--value wifi 'hardware))
        "  radio=" (sk/network--text (sk/network--value wifi 'radio))
        "\n\nDevices\n")
       (if devices
           (progn
             (insert (format "  %-14s %-10s %-18s %s\n"
                             "Name" "Kind" "State" "Connection"))
             (dolist (record devices)
               (insert
                (format
                 "  %-14s %-10s %-18s %s\n"
                 (sk/network--value record 'name)
                 (sk/network--text
                  (sk/network--value record 'kind))
                 (sk/network--value record 'state)
                 (sk/network--text
                  (sk/network--value record 'connection))))))
         (insert "  None\n"))
       (insert "\nSaved connections\n")
       (if connections
           (progn
             (insert (format "  %-1s %-32s %s\n" "*" "Name" "Kind"))
             (dolist (record connections)
               (insert
                (format
                 "  %-1s %-32s %s\n"
                 (if (eq (sk/network--value record 'active) 'yes)
                     "*" "")
                 (truncate-string-to-width
                  (sk/network--value record 'name) 32 nil nil t)
                 (sk/network--text
                  (sk/network--value record 'kind))))))
         (insert "  None\n"))
       (insert "\nNearby Wi-Fi\n")
       (if access-points
           (progn
             (insert
              (format "  %-1s %-32s %6s  %s\n"
                      "*" "SSID" "Signal" "Security"))
             (dolist (record access-points)
               (insert
                (format
                 "  %-1s %-32s %5d%%  %s\n"
                 (if (eq (sk/network--value record 'active) 'yes)
                     "*" "")
                 (truncate-string-to-width
                  (sk/network--value record 'ssid) 32 nil nil t)
                 (sk/network--value record 'signal)
                 (sk/network--value record 'security)))))
         (insert "  None\n"))
       (insert
        "\ng refresh   s rescan   c connect saved   d disconnect\n"
        "w Wi-Fi radio   e connection editor   q quit\n")))))

(defun sk/network--message (heading detail)
  "Render HEADING and DETAIL in the panel."
  (setq sk/network--snapshot nil)
  (sk/network--display
   (lambda ()
     (insert heading "\n\n" detail
             "\n\nPress g to retry or e for the connection editor.\n"))))

(defun sk/network--finish (process target output error-output)
  "Finish PROCESS for TARGET using OUTPUT and ERROR-OUTPUT."
  (when (memq (process-status process) '(exit signal))
    (unwind-protect
        (when (buffer-live-p target)
          (with-current-buffer target
            (when (eq process sk/network--process)
              (setq sk/network--process nil)
              (if (and (eq (process-status process) 'exit)
                       (zerop (process-exit-status process)))
                  (condition-case nil
                      (sk/network--render
                       (with-current-buffer output
                         (sk/network--parse (buffer-string))))
                    (error
                     (sk/network--message
                      "SK Network unavailable"
                      "The Guile client returned invalid data.")))
                (let ((detail
                       (with-current-buffer error-output
                         (string-trim (buffer-string)))))
                  (sk/network--message
                   "Network action failed"
                   (if (string-empty-p detail)
                       "NetworkManager rejected or timed out the request."
                     (truncate-string-to-width detail 2000))))))))
      (dolist (buffer (list output error-output))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(defun sk/network--run (arguments heading)
  "Run the Guile client with ARGUMENTS while displaying HEADING."
  (when (and sk/network--process (process-live-p sk/network--process))
    (user-error "A network action is already running"))
  (unless (file-executable-p sk/network-program)
    (user-error "Network client is not executable: %s"
                sk/network-program))
  (let ((target (current-buffer))
        (output (generate-new-buffer " *sk-network-output*"))
        (error-output (generate-new-buffer " *sk-network-error*")))
    (sk/network--display (lambda () (insert heading "\n")))
    (condition-case err
        (setq sk/network--process
              (make-process
               :name "sk-network"
               :buffer output
               :command (cons sk/network-program arguments)
               :connection-type 'pipe
               :coding 'utf-8-unix
               :noquery t
               :stderr error-output
               :sentinel
               (lambda (process _event)
                 (sk/network--finish
                  process target output error-output))))
      (error
       (dolist (buffer (list output error-output))
         (when (buffer-live-p buffer) (kill-buffer buffer)))
       (sk/network--message
        "SK Network unavailable" (error-message-string err))))))

(defun sk/network-refresh ()
  "Collect one fresh NetworkManager snapshot."
  (interactive)
  (sk/network--run '("status") "Refreshing network status..."))

(defun sk/network-scan ()
  "Request one bounded Wi-Fi rescan."
  (interactive)
  (sk/network--run '("scan") "Rescanning Wi-Fi..."))

(defun sk/network--select-connection (prompt active)
  "Select a saved connection using PROMPT and ACTIVE state."
  (let* ((records
          (seq-filter
           (lambda (record)
             (eq (sk/network--value record 'active) active))
           (sk/network--section 4)))
         (choices
          (mapcar
           (lambda (record)
             (cons
              (format "%s — %s"
                      (sk/network--value record 'name)
                      (sk/network--text
                       (sk/network--value record 'kind)))
              record))
           records)))
    (unless choices
      (user-error "No matching saved connection; refresh or use e"))
    (cdr (assoc (completing-read prompt choices nil t) choices))))

(defun sk/network-connect ()
  "Activate one saved inactive connection after confirmation."
  (interactive)
  (let* ((record (sk/network--select-connection "Connect: " 'no))
         (name (sk/network--value record 'name)))
    (unless
        (yes-or-no-p
         (format "Activate %s and possibly interrupt remote sessions? "
                 name))
      (user-error "Connection cancelled"))
    (sk/network--run
     (list "connect" (sk/network--value record 'uuid))
     "Activating saved connection...")))

(defun sk/network-disconnect ()
  "Disconnect one active connection after confirmation."
  (interactive)
  (let* ((record (sk/network--select-connection "Disconnect: " 'yes))
         (name (sk/network--value record 'name)))
    (unless
        (yes-or-no-p
         (format "Disconnect %s and possibly interrupt remote sessions? "
                 name))
      (user-error "Disconnect cancelled"))
    (sk/network--run
     (list "disconnect" (sk/network--value record 'uuid))
     "Disconnecting saved connection...")))

(defun sk/network-toggle-wifi ()
  "Toggle the Wi-Fi radio, confirming before turning it off."
  (interactive)
  (let* ((wifi (sk/network--section 2))
         (turn-off (eq (sk/network--value wifi 'radio) 'enabled)))
    (when (and turn-off
               (not
                (yes-or-no-p
                 "Turn off Wi-Fi and disconnect wireless sessions? ")))
      (user-error "Wi-Fi change cancelled"))
    (sk/network--run
     (list "wifi" (if turn-off "off" "on"))
     (if turn-off "Turning off Wi-Fi..." "Turning on Wi-Fi..."))))

(defun sk/network-editor ()
  "Open NetworkManager's retained editor for new networks and secrets."
  (interactive)
  (unless (file-executable-p sk/network-editor-program)
    (user-error "Network editor is not executable: %s"
                sk/network-editor-program))
  (start-process "nm-connection-editor" nil sk/network-editor-program)
  (message "Started NetworkManager connection editor"))

(defvar sk/network-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'sk/network-refresh)
    (define-key map (kbd "s") #'sk/network-scan)
    (define-key map (kbd "c") #'sk/network-connect)
    (define-key map (kbd "d") #'sk/network-disconnect)
    (define-key map (kbd "w") #'sk/network-toggle-wifi)
    (define-key map (kbd "e") #'sk/network-editor)
    (define-key map (kbd "q") #'quit-window)
    map))

(define-derived-mode sk/network-mode special-mode "SK-Network"
  "Major mode for bounded NetworkManager status and actions."
  (setq-local buffer-read-only t truncate-lines t))

(with-eval-after-load 'evil
  (evil-define-key '(normal motion) sk/network-mode-map
    (kbd "g") #'sk/network-refresh
    (kbd "s") #'sk/network-scan
    (kbd "c") #'sk/network-connect
    (kbd "d") #'sk/network-disconnect
    (kbd "w") #'sk/network-toggle-wifi
    (kbd "e") #'sk/network-editor
    (kbd "q") #'quit-window))

;;;###autoload
(defun sk/network ()
  "Open the network utility panel and collect one fresh snapshot."
  (interactive)
  (let ((buffer (get-buffer-create sk/network-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'sk/network-mode)
        (sk/network-mode))
      (unless (and sk/network--process
                   (process-live-p sk/network--process))
        (sk/network-refresh)))
    (select-window (sk/window-display-right buffer))
    buffer))

(provide 'sk-network)

;;; sk-network.el ends here
