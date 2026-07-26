;;; sk-bluetooth.el --- Bounded BlueZ control panel -*- lexical-binding: t; -*-

;;; Commentary:
;; Run the repository's Guile BlueZ client asynchronously and retain Blueman
;; as the explicit recovery UI.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'sk-window-policy)

(defvar sk/user-directory)
(declare-function evil-define-key "evil-core")

(defgroup sk/bluetooth nil
  "GuixPC Bluetooth control."
  :group 'hardware)

(defcustom sk/bluetooth-scan-seconds 10
  "Seconds used for one explicit Bluetooth scan."
  :type '(integer :tag "Seconds")
  :safe (lambda (value)
          (and (integerp value) (<= 1 value 30))))

(define-error 'sk/bluetooth-invalid-output
  "Invalid sk-bluetooth output")

(defconst sk/bluetooth-buffer-name "*SK Bluetooth*")
(defconst sk/bluetooth-program
  (expand-file-name
   "scripts/sk-bluetooth"
   (file-name-directory
    (directory-file-name (file-truename sk/user-directory)))))
(defconst sk/bluetooth-blueman-program
  (expand-file-name "~/.guix-home/profile/bin/blueman-manager"))

(defvar-local sk/bluetooth--process nil)
(defvar-local sk/bluetooth--snapshot nil)

(defun sk/bluetooth--invalid (detail)
  "Signal invalid collector output with DETAIL."
  (signal 'sk/bluetooth-invalid-output (list detail)))

(defun sk/bluetooth--value (record key)
  "Return scalar KEY from RECORD or reject it."
  (let ((entries (seq-filter (lambda (entry) (eq (car-safe entry) key))
                             record)))
    (unless (and (= (length entries) 1)
                 (= (length (car entries)) 2))
      (sk/bluetooth--invalid "invalid record field"))
    (cadar entries)))

(defun sk/bluetooth--validate-scalar (value type)
  "Validate VALUE as TYPE."
  (unless
      (pcase type
        ('string-or-unknown (or (stringp value) (eq value 'unknown)))
        ('natural-or-unknown
         (or (eq value 'unknown)
             (and (integerp value) (>= value 0) (<= value 100))))
        (`(enum . ,members) (memq value members))
        (_ nil))
    (sk/bluetooth--invalid "invalid scalar value")))

(defun sk/bluetooth--validate-record (record schema)
  "Validate RECORD against fixed scalar SCHEMA."
  (unless (and (proper-list-p record)
               (= (length record) (length schema))
               (cl-every (lambda (entry)
                           (and (proper-list-p entry)
                                (= (length entry) 2)
                                (symbolp (car entry))))
                         record))
    (sk/bluetooth--invalid "invalid record"))
  (dolist (field schema)
    (sk/bluetooth--validate-scalar
     (sk/bluetooth--value record (car field))
     (cadr field))))

(defconst sk/bluetooth--adapter-schema
  '((state (enum present absent unavailable unknown))
    (path string-or-unknown)
    (alias string-or-unknown)
    (powered (enum yes no unknown))
    (discovering (enum yes no unknown))))

(defconst sk/bluetooth--device-schema
  '((path string-or-unknown)
    (address string-or-unknown)
    (alias string-or-unknown)
    (paired (enum yes no unknown))
    (trusted (enum yes no unknown))
    (connected (enum yes no unknown))
    (audio (enum yes no unknown))
    (battery natural-or-unknown)))

(defun sk/bluetooth--parse (output)
  "Read and validate one Bluetooth snapshot from OUTPUT."
  (unless (stringp output)
    (sk/bluetooth--invalid "output is not text"))
  (with-temp-buffer
    (insert output)
    (goto-char (point-min))
    (let ((form
           (let ((read-circle nil)
                 (read-eval nil))
             (condition-case nil
                 (read (current-buffer))
               (error (sk/bluetooth--invalid "unreadable expression"))))))
      (skip-chars-forward " \t\r\n")
      (unless (eobp)
        (sk/bluetooth--invalid "trailing output"))
      (unless (and (proper-list-p form)
                   (= (length form) 3)
                   (eq (car form) 'sk-bluetooth/v1)
                   (eq (car-safe (cadr form)) 'adapter)
                   (eq (car-safe (caddr form)) 'devices))
        (sk/bluetooth--invalid "invalid top-level form"))
      (sk/bluetooth--validate-record
       (cdr (cadr form)) sk/bluetooth--adapter-schema)
      (unless (proper-list-p (cdr (caddr form)))
        (sk/bluetooth--invalid "invalid device list"))
      (dolist (device (cdr (caddr form)))
        (sk/bluetooth--validate-record
         device sk/bluetooth--device-schema))
      form)))

(defun sk/bluetooth--adapter ()
  "Return the adapter record from the current snapshot."
  (unless sk/bluetooth--snapshot
    (user-error "Bluetooth status is not ready; press g"))
  (cdr (cadr sk/bluetooth--snapshot)))

(defun sk/bluetooth--devices ()
  "Return device records from the current snapshot."
  (unless sk/bluetooth--snapshot
    (user-error "Bluetooth status is not ready; press g"))
  (cdr (caddr sk/bluetooth--snapshot)))

(defun sk/bluetooth--display (function)
  "Replace the panel contents by calling FUNCTION."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (funcall function)
    (goto-char (point-min))))

(defun sk/bluetooth--text (value)
  "Return VALUE as compact display text."
  (if (symbolp value) (symbol-name value) (format "%s" value)))

(defun sk/bluetooth--render (snapshot)
  "Render validated SNAPSHOT in the current panel."
  (setq sk/bluetooth--snapshot snapshot)
  (let* ((adapter (cdr (cadr snapshot)))
         (devices (cdr (caddr snapshot)))
         (alias (sk/bluetooth--value adapter 'alias)))
    (sk/bluetooth--display
     (lambda ()
       (insert "SK Bluetooth\n\n"
               "Controller: " (sk/bluetooth--text alias)
               "  state=" (sk/bluetooth--text
                            (sk/bluetooth--value adapter 'state))
               "  powered=" (sk/bluetooth--text
                              (sk/bluetooth--value adapter 'powered))
               "  scanning=" (sk/bluetooth--text
                               (sk/bluetooth--value adapter 'discovering))
               "\n\n")
       (if devices
           (progn
             (insert
              (format "%-28s %-17s %7s %7s %9s %5s %7s\n"
                      "Device" "Address" "Paired" "Trusted"
                      "Connected" "Audio" "Battery"))
             (dolist (device devices)
               (let ((battery (sk/bluetooth--value device 'battery)))
                 (insert
                  (format
                   "%-28s %-17s %7s %7s %9s %5s %7s\n"
                   (truncate-string-to-width
                    (sk/bluetooth--text
                     (sk/bluetooth--value device 'alias))
                    28 nil nil t)
                   (sk/bluetooth--text
                    (sk/bluetooth--value device 'address))
                   (sk/bluetooth--text
                    (sk/bluetooth--value device 'paired))
                   (sk/bluetooth--text
                    (sk/bluetooth--value device 'trusted))
                   (sk/bluetooth--text
                    (sk/bluetooth--value device 'connected))
                   (sk/bluetooth--text
                    (sk/bluetooth--value device 'audio))
                   (if (integerp battery)
                       (format "%d%%" battery)
                     "unknown"))))))
         (insert "No known devices.  Press s to scan.\n"))
       (insert
        "\ng refresh   P power   s scan   p pair   t trust\n"
        "c connect   d disconnect   a audio profile   r reconnect\n"
        "b Blueman fallback   q quit\n")))))

(defun sk/bluetooth--message (heading detail)
  "Render HEADING and DETAIL in the panel."
  (setq sk/bluetooth--snapshot nil)
  (sk/bluetooth--display
   (lambda ()
     (insert heading "\n\n" detail
             "\n\nPress g to retry or b for Blueman.\n"))))

(defun sk/bluetooth--finish (process target output error-output)
  "Finish PROCESS for TARGET using OUTPUT and ERROR-OUTPUT."
  (when (memq (process-status process) '(exit signal))
    (unwind-protect
        (when (buffer-live-p target)
          (with-current-buffer target
            (when (eq process sk/bluetooth--process)
              (setq sk/bluetooth--process nil)
              (if (and (eq (process-status process) 'exit)
                       (zerop (process-exit-status process)))
                  (condition-case nil
                      (sk/bluetooth--render
                       (with-current-buffer output
                         (sk/bluetooth--parse (buffer-string))))
                    (error
                     (sk/bluetooth--message
                      "SK Bluetooth unavailable"
                      "The Guile client returned invalid data.")))
                (let ((detail
                       (with-current-buffer error-output
                         (string-trim (buffer-string)))))
                  (sk/bluetooth--message
                   "Bluetooth action failed"
                   (if (string-empty-p detail)
                       "BlueZ rejected or timed out the request."
                     (truncate-string-to-width detail 2000))))))))
      (dolist (buffer (list output error-output))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(defun sk/bluetooth--run (arguments heading)
  "Run the Guile client with ARGUMENTS while displaying HEADING."
  (when (and sk/bluetooth--process
             (process-live-p sk/bluetooth--process))
    (user-error "A Bluetooth action is already running"))
  (unless (file-executable-p sk/bluetooth-program)
    (user-error "Bluetooth client is not executable: %s"
                sk/bluetooth-program))
  (let ((target (current-buffer))
        (output (generate-new-buffer " *sk-bluetooth-output*"))
        (error-output (generate-new-buffer " *sk-bluetooth-error*")))
    (sk/bluetooth--display (lambda () (insert heading "\n")))
    (condition-case err
        (setq sk/bluetooth--process
              (make-process
               :name "sk-bluetooth"
               :buffer output
               :command (cons sk/bluetooth-program arguments)
               :connection-type 'pipe
               :coding 'utf-8-unix
               :noquery t
               :stderr error-output
               :sentinel
               (lambda (process _event)
                 (sk/bluetooth--finish
                  process target output error-output))))
      (error
       (dolist (buffer (list output error-output))
         (when (buffer-live-p buffer) (kill-buffer buffer)))
       (sk/bluetooth--message
        "SK Bluetooth unavailable"
        (error-message-string err))))))

(defun sk/bluetooth-refresh ()
  "Collect one fresh BlueZ snapshot."
  (interactive)
  (sk/bluetooth--run '("status") "Refreshing Bluetooth status..."))

(defun sk/bluetooth--select-device (prompt &optional predicate)
  "Select a device using PROMPT, restricted by PREDICATE."
  (let* ((devices
          (if predicate
              (seq-filter predicate (sk/bluetooth--devices))
            (sk/bluetooth--devices)))
         (choices
          (mapcar
           (lambda (device)
             (cons
              (format "%s — %s"
                      (sk/bluetooth--text
                       (sk/bluetooth--value device 'alias))
                      (sk/bluetooth--text
                       (sk/bluetooth--value device 'address)))
              device))
           devices)))
    (unless choices
      (user-error "No matching Bluetooth device; scan or refresh first"))
    (cdr
     (assoc
      (completing-read prompt choices nil t)
      choices))))

(defun sk/bluetooth--device-action (verb heading &optional predicate)
  "Run VERB for a selected device while displaying HEADING."
  (let* ((device (sk/bluetooth--select-device
                  (concat heading ": ") predicate))
         (address (sk/bluetooth--value device 'address)))
    (unless (stringp address)
      (user-error "Selected device has no usable address"))
    (sk/bluetooth--run (list verb address)
                       (concat heading "..."))))

(defun sk/bluetooth-power ()
  "Toggle adapter power, confirming the disruptive off transition."
  (interactive)
  (let* ((adapter (sk/bluetooth--adapter))
         (powered (sk/bluetooth--value adapter 'powered))
         (turn-off (eq powered 'yes)))
    (when (and turn-off
               (not (yes-or-no-p
                     "Power off Bluetooth and disconnect devices? ")))
      (user-error "Bluetooth power change cancelled"))
    (sk/bluetooth--run
     (list "power" (if turn-off "off" "on"))
     (if turn-off
         "Powering off Bluetooth..."
       "Powering on Bluetooth..."))))

(defun sk/bluetooth-scan ()
  "Run one bounded scan and refresh known devices."
  (interactive)
  (sk/bluetooth--run
   (list "scan" (number-to-string sk/bluetooth-scan-seconds))
   (format "Scanning for %d seconds..." sk/bluetooth-scan-seconds)))

(defun sk/bluetooth-pair ()
  "Pair one known unpaired device."
  (interactive)
  (sk/bluetooth--device-action
   "pair" "Pairing"
   (lambda (device)
     (not (eq (sk/bluetooth--value device 'paired) 'yes)))))

(defun sk/bluetooth-trust ()
  "Toggle trust for one known device."
  (interactive)
  (let* ((device (sk/bluetooth--select-device "Trust device: "))
         (address (sk/bluetooth--value device 'address))
         (trusted (eq (sk/bluetooth--value device 'trusted) 'yes))
         (alias (sk/bluetooth--value device 'alias)))
    (unless (stringp address)
      (user-error "Selected device has no usable address"))
    (when (and trusted
               (not (yes-or-no-p
                     (format "Remove trust from %s? " alias))))
      (user-error "Bluetooth trust change cancelled"))
    (sk/bluetooth--run
     (list "trust" address (if trusted "off" "on"))
     (if trusted "Removing trust..." "Trusting device..."))))

(defun sk/bluetooth-connect ()
  "Connect one device."
  (interactive)
  (sk/bluetooth--device-action
   "connect" "Connecting"
   (lambda (device)
     (not (eq (sk/bluetooth--value device 'connected) 'yes)))))

(defun sk/bluetooth-disconnect ()
  "Disconnect one connected device."
  (interactive)
  (sk/bluetooth--device-action
   "disconnect" "Disconnecting"
   (lambda (device)
     (eq (sk/bluetooth--value device 'connected) 'yes))))

(defun sk/bluetooth-audio-profile ()
  "Connect the remote Audio Sink profile for one audio device."
  (interactive)
  (let* ((device
          (sk/bluetooth--select-device
           "Audio profile: "
           (lambda (candidate)
             (eq (sk/bluetooth--value candidate 'audio) 'yes))))
         (address (sk/bluetooth--value device 'address)))
    (unless (stringp address)
      (user-error "Selected device has no usable address"))
    (sk/bluetooth--run
     (list "profile" address "audio")
     "Connecting audio profile...")))

(defun sk/bluetooth-reconnect ()
  "Power the adapter if needed and reconnect one trusted paired device."
  (interactive)
  (sk/bluetooth--device-action
   "reconnect" "Reconnecting"
   (lambda (device)
     (and (eq (sk/bluetooth--value device 'paired) 'yes)
          (eq (sk/bluetooth--value device 'trusted) 'yes)))))

(defun sk/bluetooth-blueman ()
  "Launch Blueman as the retained recovery interface."
  (interactive)
  (unless (file-executable-p sk/bluetooth-blueman-program)
    (user-error "Blueman is not executable: %s"
                sk/bluetooth-blueman-program))
  (start-process "blueman-manager" nil sk/bluetooth-blueman-program)
  (message "Started Blueman fallback"))

(defvar sk/bluetooth-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'sk/bluetooth-refresh)
    (define-key map (kbd "P") #'sk/bluetooth-power)
    (define-key map (kbd "s") #'sk/bluetooth-scan)
    (define-key map (kbd "p") #'sk/bluetooth-pair)
    (define-key map (kbd "t") #'sk/bluetooth-trust)
    (define-key map (kbd "c") #'sk/bluetooth-connect)
    (define-key map (kbd "d") #'sk/bluetooth-disconnect)
    (define-key map (kbd "a") #'sk/bluetooth-audio-profile)
    (define-key map (kbd "r") #'sk/bluetooth-reconnect)
    (define-key map (kbd "b") #'sk/bluetooth-blueman)
    (define-key map (kbd "q") #'quit-window)
    map))

(define-derived-mode sk/bluetooth-mode special-mode "SK-Bluetooth"
  "Major mode for bounded BlueZ status and actions."
  (setq-local buffer-read-only t truncate-lines t))

(with-eval-after-load 'evil
  (evil-define-key '(normal motion) sk/bluetooth-mode-map
    (kbd "g") #'sk/bluetooth-refresh
    (kbd "P") #'sk/bluetooth-power
    (kbd "s") #'sk/bluetooth-scan
    (kbd "p") #'sk/bluetooth-pair
    (kbd "t") #'sk/bluetooth-trust
    (kbd "c") #'sk/bluetooth-connect
    (kbd "d") #'sk/bluetooth-disconnect
    (kbd "a") #'sk/bluetooth-audio-profile
    (kbd "r") #'sk/bluetooth-reconnect
    (kbd "b") #'sk/bluetooth-blueman
    (kbd "q") #'quit-window))

;;;###autoload
(defun sk/bluetooth ()
  "Open the Bluetooth utility panel and collect one fresh snapshot."
  (interactive)
  (let ((buffer (get-buffer-create sk/bluetooth-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'sk/bluetooth-mode)
        (sk/bluetooth-mode))
      (unless (and sk/bluetooth--process
                   (process-live-p sk/bluetooth--process))
        (sk/bluetooth-refresh)))
    (select-window (sk/window-display-right buffer))
    buffer))

(provide 'sk-bluetooth)

;;; sk-bluetooth.el ends here
