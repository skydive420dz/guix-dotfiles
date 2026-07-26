;;; sk-audio.el --- Bounded WirePlumber control panel -*- lexical-binding: t; -*-

;;; Commentary:
;; Present the repository's Guile wpctl client and retain pipemixer as the
;; explicit fallback.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'sk-window-policy)
(require 'sk-bluetooth)

(defvar sk/user-directory)
(declare-function evil-define-key "evil-core")

(define-error 'sk/audio-invalid-output "Invalid sk-audio output")

(defconst sk/audio-buffer-name "*SK Audio*")
(defconst sk/audio-program
  (expand-file-name
   "scripts/sk-audio"
   (file-name-directory
    (directory-file-name (file-truename sk/user-directory)))))
(defconst sk/audio-pipemixer-program
  (expand-file-name "~/.guix-home/profile/bin/pipemixer"))

(defvar-local sk/audio--snapshot nil)

(defun sk/audio--invalid (detail)
  "Signal invalid collector output with DETAIL."
  (signal 'sk/audio-invalid-output (list detail)))

(defun sk/audio--value (record key)
  "Return scalar KEY from RECORD or reject it."
  (let ((entries (seq-filter (lambda (entry) (eq (car-safe entry) key))
                             record)))
    (unless (and (= (length entries) 1)
                 (= (length (car entries)) 2))
      (sk/audio--invalid "invalid record field"))
    (cadar entries)))

(defun sk/audio--valid-scalar-p (value type)
  "Return non-nil when VALUE satisfies TYPE."
  (pcase type
    ('string (stringp value))
    ('natural (and (integerp value) (>= value 0)))
    ('volume (or (eq value 'unknown)
                 (and (integerp value) (<= 0 value 1000))))
    (`(enum . ,members) (memq value members))
    (_ nil)))

(defconst sk/audio--object-schema
  '((id natural)
    (name string)
    (description string)
    (kind (enum sink source stream))
    (default (enum yes no))
    (volume volume)
    (muted (enum yes no unknown))))

(defun sk/audio--validate-record (record)
  "Validate one audio object RECORD."
  (unless (and (proper-list-p record)
               (= (length record) (length sk/audio--object-schema))
               (cl-every (lambda (entry)
                           (and (proper-list-p entry)
                                (= (length entry) 2)
                                (symbolp (car entry))))
                         record))
    (sk/audio--invalid "invalid object record"))
  (dolist (field sk/audio--object-schema)
    (unless (sk/audio--valid-scalar-p
             (sk/audio--value record (car field)) (cadr field))
      (sk/audio--invalid "invalid object value"))))

(defun sk/audio--parse (output)
  "Read and validate one audio snapshot from OUTPUT."
  (unless (stringp output)
    (sk/audio--invalid "output is not text"))
  (with-temp-buffer
    (insert output)
    (goto-char (point-min))
    (let ((form
           (let ((read-circle nil)
                 (read-eval nil))
             (condition-case nil
                 (read (current-buffer))
               (error (sk/audio--invalid "unreadable expression"))))))
      (skip-chars-forward " \t\r\n")
      (unless (eobp)
        (sk/audio--invalid "trailing output"))
      (unless (and (proper-list-p form)
                   (= (length form) 2)
                   (eq (car form) 'sk-audio/v1)
                   (eq (car-safe (cadr form)) 'objects)
                   (proper-list-p (cdr (cadr form))))
        (sk/audio--invalid "invalid top-level form"))
      (let ((objects (cdr (cadr form))))
        (dolist (record objects)
          (sk/audio--validate-record record))
        (let ((ids (mapcar (lambda (record)
                             (sk/audio--value record 'id))
                           objects)))
          (unless (= (length ids)
                     (length (delete-dups (copy-sequence ids))))
            (sk/audio--invalid "duplicate object id"))))
      form)))

(defun sk/audio--objects ()
  "Return object records from the current snapshot."
  (unless sk/audio--snapshot
    (user-error "Audio status is not ready; press g"))
  (cdr (cadr sk/audio--snapshot)))

(defun sk/audio--display (function)
  "Replace the panel contents by calling FUNCTION."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (funcall function)
    (goto-char (point-min))))

(defun sk/audio--text (value)
  "Return VALUE as compact display text."
  (if (symbolp value) (symbol-name value) (format "%s" value)))

(defun sk/audio--volume-text (value)
  "Return normalized display text for volume VALUE."
  (if (integerp value) (format "%d%%" value) "unknown"))

(defun sk/audio--render-section (title kind objects)
  "Render TITLE for objects of KIND from OBJECTS."
  (let ((matching
         (seq-filter
          (lambda (record)
            (eq (sk/audio--value record 'kind) kind))
          objects)))
    (insert title "\n")
    (if matching
        (progn
          (insert (format "  %-1s %-28s %5s %8s %7s  %s\n"
                          "*" "Name" "ID" "Volume" "Muted" "PipeWire name"))
          (dolist (record matching)
            (insert
             (format
              "  %-1s %-28s %5d %8s %7s  %s\n"
              (if (eq (sk/audio--value record 'default) 'yes) "*" "")
              (truncate-string-to-width
               (sk/audio--value record 'description) 28 nil nil t)
              (sk/audio--value record 'id)
              (sk/audio--volume-text
               (sk/audio--value record 'volume))
              (sk/audio--text (sk/audio--value record 'muted))
              (sk/audio--value record 'name)))))
      (insert "  None\n"))
    (insert "\n")))

(defun sk/audio--render (snapshot)
  "Render validated SNAPSHOT in the current panel."
  (setq sk/audio--snapshot snapshot)
  (let ((objects (cdr (cadr snapshot))))
    (sk/audio--display
     (lambda ()
       (insert "SK Audio\n\n")
       (sk/audio--render-section "Outputs" 'sink objects)
       (sk/audio--render-section "Inputs" 'source objects)
       (sk/audio--render-section "Streams" 'stream objects)
       (insert
        "g refresh   + / - default volume   m mute target\n"
        "v set target volume   d set default   b Bluetooth\n"
        "p pipemixer fallback   q quit\n")))))

(defun sk/audio--message (heading detail)
  "Render HEADING and DETAIL in the panel."
  (setq sk/audio--snapshot nil)
  (sk/audio--display
   (lambda ()
     (insert heading "\n\n" detail
             "\n\nPress g to retry or p for pipemixer.\n"))))

(defun sk/audio--error-text (file)
  "Return trimmed contents of FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (string-trim (buffer-string))))

(defun sk/audio--run (arguments heading)
  "Run the bounded Guile client with ARGUMENTS while displaying HEADING."
  (unless (file-executable-p sk/audio-program)
    (user-error "Audio client is not executable: %s" sk/audio-program))
  ;; ponytail: synchronous calls are bounded and normally sub-second; move to
  ;; make-process only if a measured WirePlumber stall makes the panel janky.
  (let ((target (current-buffer))
        (error-file (make-temp-file "sk-audio-error-")))
    (sk/audio--display (lambda () (insert heading "\n")))
    (redisplay)
    (unwind-protect
        (with-temp-buffer
          (let ((status
                 (condition-case nil
                     (apply #'call-process sk/audio-program nil
                            (list t error-file) nil arguments)
                   (error 'failed)))
                (output (buffer-string)))
            (with-current-buffer target
              (if (and (integerp status) (zerop status))
                  (condition-case nil
                      (sk/audio--render (sk/audio--parse output))
                    (error
                     (sk/audio--message
                      "SK Audio unavailable"
                      "The Guile client returned invalid data.")))
                (let ((detail (sk/audio--error-text error-file)))
                  (sk/audio--message
                   "Audio action failed"
                   (if (string-empty-p detail)
                       "WirePlumber rejected or timed out the request."
                     (truncate-string-to-width detail 2000))))))))
      (delete-file error-file))))

(defun sk/audio-refresh ()
  "Collect one fresh WirePlumber snapshot."
  (interactive)
  (sk/audio--run '("status") "Refreshing audio status..."))

(defun sk/audio--select (prompt kinds)
  "Select an audio object using PROMPT and allowed KINDS."
  (let* ((objects
          (seq-filter
           (lambda (record)
             (memq (sk/audio--value record 'kind) kinds))
           (sk/audio--objects)))
         (choices
          (mapcar
           (lambda (record)
             (cons
              (format "%s%s — %s — id %d"
                      (if (eq (sk/audio--value record 'default) 'yes)
                          "* " "")
                      (sk/audio--value record 'description)
                      (sk/audio--text (sk/audio--value record 'kind))
                      (sk/audio--value record 'id))
              record))
           objects)))
    (unless choices
      (user-error "No matching audio object; refresh or connect it first"))
    (cdr (assoc (completing-read prompt choices nil t) choices))))

(defun sk/audio-volume-up ()
  "Raise the default output by five percent, capped at 100 percent."
  (interactive)
  (sk/audio--run '("step" "up") "Raising default volume..."))

(defun sk/audio-volume-down ()
  "Lower the default output by five percent."
  (interactive)
  (sk/audio--run '("step" "down") "Lowering default volume..."))

(defun sk/audio-toggle-mute ()
  "Toggle mute for one selected endpoint or stream."
  (interactive)
  (let ((record (sk/audio--select
                 "Mute target: " '(sink source stream))))
    (sk/audio--run
     (list "mute" (number-to-string (sk/audio--value record 'id)))
     "Toggling mute...")))

(defun sk/audio-set-volume ()
  "Set an exact 0--100 percent volume for one endpoint or stream."
  (interactive)
  (let* ((record (sk/audio--select
                  "Volume target: " '(sink source stream)))
         (current (sk/audio--value record 'volume))
         (value (read-number
                 "Volume percent (0-100): "
                 (if (integerp current) (min current 100) 50))))
    (unless (and (integerp value) (<= 0 value 100))
      (user-error "Volume must be an integer between 0 and 100"))
    (sk/audio--run
     (list "volume"
           (number-to-string (sk/audio--value record 'id))
           (number-to-string value))
     "Setting volume...")))

(defun sk/audio-set-default ()
  "Choose the default output or input endpoint."
  (interactive)
  (let ((record (sk/audio--select "Default endpoint: " '(sink source))))
    (sk/audio--run
     (list "default" (number-to-string (sk/audio--value record 'id)))
     "Setting default endpoint...")))

(defun sk/audio-pipemixer ()
  "Open the retained pipemixer fallback in the utility terminal."
  (interactive)
  (unless (file-executable-p sk/audio-pipemixer-program)
    (user-error "pipemixer is not executable: %s"
                sk/audio-pipemixer-program))
  (let ((explicit-shell-file-name sk/audio-pipemixer-program))
    (sk/window-open-term)))

(defvar sk/audio-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'sk/audio-refresh)
    (define-key map (kbd "+") #'sk/audio-volume-up)
    (define-key map (kbd "-") #'sk/audio-volume-down)
    (define-key map (kbd "m") #'sk/audio-toggle-mute)
    (define-key map (kbd "v") #'sk/audio-set-volume)
    (define-key map (kbd "d") #'sk/audio-set-default)
    (define-key map (kbd "b") #'sk/bluetooth)
    (define-key map (kbd "p") #'sk/audio-pipemixer)
    (define-key map (kbd "q") #'quit-window)
    map))

(define-derived-mode sk/audio-mode special-mode "SK-Audio"
  "Major mode for bounded WirePlumber status and actions."
  (setq-local buffer-read-only t truncate-lines t))

(with-eval-after-load 'evil
  (evil-define-key '(normal motion) sk/audio-mode-map
    (kbd "g") #'sk/audio-refresh
    (kbd "+") #'sk/audio-volume-up
    (kbd "-") #'sk/audio-volume-down
    (kbd "m") #'sk/audio-toggle-mute
    (kbd "v") #'sk/audio-set-volume
    (kbd "d") #'sk/audio-set-default
    (kbd "b") #'sk/bluetooth
    (kbd "p") #'sk/audio-pipemixer
    (kbd "q") #'quit-window))

;;;###autoload
(defun sk/audio ()
  "Open the audio utility panel and collect one fresh snapshot."
  (interactive)
  (let ((buffer (get-buffer-create sk/audio-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'sk/audio-mode)
        (sk/audio-mode))
      (sk/audio-refresh))
    (select-window (sk/window-display-right buffer))
    buffer))

(provide 'sk-audio)

;;; sk-audio.el ends here
