;;; sk-scheme-studio.el --- Focused Guile learning workflow -*- lexical-binding: t; -*-

;;; Commentary:

;; Keep one small, visible exercise project around normal Geiser and Guile
;; commands.  The curriculum remains immutable; only solutions and progress
;; are written to the user-owned workspace.

;;; Code:

(require 'compile)
(require 'seq)
(require 'subr-x)
(require 'sk-lisp)
(require 'sk-window-policy)

(defvar sk/scheme-studio-workspace-directory
  (file-name-as-directory (expand-file-name "~/Projects/scheme-studio"))
  "User-owned Scheme Studio exercises and progress.")

(defconst sk/scheme-studio-curriculum-directory
  (expand-file-name "scheme-studio/exercises"
                    sk/lisp-repository-directory)
  "Immutable exercise sources supplied by this checkout.")

(defconst sk/scheme-studio-current-file ".current"
  "Workspace file containing the active exercise identifier.")

(defconst sk/scheme-studio-progress-file "progress.org"
  "Workspace file containing human-readable exercise progress.")

(defun sk/scheme-studio--workspace-file (relative)
  "Return RELATIVE below the Scheme Studio workspace."
  (expand-file-name relative sk/scheme-studio-workspace-directory))

(defun sk/scheme-studio--source-file (exercise name)
  "Return exercise source NAME for EXERCISE."
  (expand-file-name name
                    (expand-file-name exercise
                                      sk/scheme-studio-curriculum-directory)))

(defun sk/scheme-studio--exercises ()
  "Return the ordered curriculum exercise identifiers."
  (unless (file-directory-p sk/scheme-studio-curriculum-directory)
    (user-error "Scheme Studio curriculum is unavailable: %s"
                sk/scheme-studio-curriculum-directory))
  (seq-filter
   (lambda (name)
     (file-directory-p
      (expand-file-name name sk/scheme-studio-curriculum-directory)))
   (directory-files sk/scheme-studio-curriculum-directory
                    nil "\\`[0-9][0-9]-")))

(defun sk/scheme-studio--title (exercise)
  "Return the documented title for EXERCISE."
  (let ((readme (sk/scheme-studio--source-file exercise "README.org")))
    (with-temp-buffer
      (insert-file-contents readme nil 0 300)
      (goto-char (point-min))
      (if (re-search-forward "^#\\+title:[[:space:]]*\\(.+\\)$" nil t)
          (string-trim (match-string 1))
        exercise))))

(defun sk/scheme-studio--write (file text)
  "Write TEXT to FILE."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert text)))

(defun sk/scheme-studio--current ()
  "Return the active exercise, falling back to the first."
  (let* ((exercises (sk/scheme-studio--exercises))
         (file (sk/scheme-studio--workspace-file
                sk/scheme-studio-current-file))
         (saved
          (when (file-readable-p file)
            (with-temp-buffer
              (insert-file-contents file)
              (string-trim (buffer-string))))))
    (or (and (member saved exercises) saved)
        (car exercises)
        (user-error "Scheme Studio curriculum has no exercises"))))

(defun sk/scheme-studio--set-current (exercise)
  "Record EXERCISE as active."
  (sk/scheme-studio--write
   (sk/scheme-studio--workspace-file sk/scheme-studio-current-file)
   (concat exercise "\n")))

(defun sk/scheme-studio--solution (exercise)
  "Return the editable solution path for EXERCISE."
  (sk/scheme-studio--workspace-file
   (format "exercises/%s/solution.scm" exercise)))

(defun sk/scheme-studio--ensure-solution (exercise)
  "Create EXERCISE's editable solution when absent."
  (let ((starter (sk/scheme-studio--source-file exercise "starter.scm"))
        (solution (sk/scheme-studio--solution exercise)))
    (unless (file-readable-p starter)
      (user-error "Scheme Studio starter is unavailable: %s" starter))
    (unless (file-exists-p solution)
      (make-directory (file-name-directory solution) t)
      (copy-file starter solution))
    solution))

(defun sk/scheme-studio--initialize ()
  "Create the explicit project workspace without overwriting user work."
  (let* ((exercises (sk/scheme-studio--exercises))
         (progress
          (sk/scheme-studio--workspace-file
           sk/scheme-studio-progress-file))
         (marker (sk/scheme-studio--workspace-file ".projectile")))
    (make-directory sk/scheme-studio-workspace-directory t)
    (unless (file-exists-p marker)
      (sk/scheme-studio--write marker ""))
    (unless (file-exists-p progress)
      (sk/scheme-studio--write
       progress
       (concat
        "#+title: Scheme Studio progress\n"
        "#+startup: overview\n\n"
        "* Exercises\n"
        (mapconcat
         (lambda (exercise)
           (format "- [ ] %s :: %s"
                   exercise (sk/scheme-studio--title exercise)))
         exercises "\n")
        "\n")))
    (let ((exercise (sk/scheme-studio--current)))
      (sk/scheme-studio--set-current exercise)
      (sk/scheme-studio--ensure-solution exercise)
      exercise)))

(defun sk/scheme-studio--completed-p (exercise)
  "Return non-nil when EXERCISE is checked in the progress file."
  (let ((progress
         (sk/scheme-studio--workspace-file
          sk/scheme-studio-progress-file)))
    (and
     (file-readable-p progress)
     (with-current-buffer (find-file-noselect progress)
       (save-restriction
         (widen)
         (goto-char (point-min))
         (re-search-forward
          (format "^- \\[X\\] %s\\(?:[[:space:]]\\|$\\)"
                  (regexp-quote exercise))
          nil t))))))

(defun sk/scheme-studio--set-complete (exercise complete)
  "Set EXERCISE's progress checkbox according to COMPLETE."
  (let ((progress
         (sk/scheme-studio--workspace-file
          sk/scheme-studio-progress-file)))
    (with-current-buffer (find-file-noselect progress)
      (save-restriction
        (widen)
        (goto-char (point-min))
        (unless
            (re-search-forward
             (format "^\\(- \\[[ X]\\]\\) %s\\(?:[[:space:]]\\|$\\)"
                     (regexp-quote exercise))
             nil t)
          (error "Scheme Studio progress omitted %s" exercise))
        (replace-match (if complete "- [X]" "- [ ]") t t nil 1)
        (save-buffer)))))

(defun sk/scheme-studio--progress-summary ()
  "Return a compact completed/total progress summary."
  (let* ((exercises (sk/scheme-studio--exercises))
         (completed (seq-count #'sk/scheme-studio--completed-p exercises)))
    (format "%d/%d complete" completed (length exercises))))

(defun sk/scheme-studio--display-documentation (exercise &optional hint)
  "Display EXERCISE documentation, selecting its hint when HINT."
  (let* ((file (sk/scheme-studio--source-file exercise "README.org"))
         (buffer (find-file-noselect file))
         (window (sk/window-display-right buffer 0.42 1)))
    (with-current-buffer buffer
      (setq buffer-read-only t)
      (goto-char (point-min))
      (when hint
        (re-search-forward "^\\* Hint" nil t)
        (beginning-of-line)))
    (set-window-point window
                      (with-current-buffer buffer (point)))
    (when hint
      (select-window window))
    window))

(defun sk/scheme-studio--open-exercise (exercise &optional start-repl)
  "Open EXERCISE and its documentation.
When START-REPL is non-nil, start or switch to its pinned Geiser REPL."
  (sk/scheme-studio--set-current exercise)
  (let* ((solution (sk/scheme-studio--ensure-solution exercise))
         (buffer (find-file-noselect solution)))
    (sk/window-display-in-main buffer t)
    (sk/scheme-studio--display-documentation exercise)
    (when start-repl
      (unless (file-executable-p sk/lisp-guix-shell)
        (user-error "Pinned Lisp shell is not executable: %s"
                    sk/lisp-guix-shell))
      (sk/lisp-repl)
      (sk/window-display-in-main buffer t))
    (message "Scheme Studio: %s (%s)"
             (sk/scheme-studio--title exercise)
             (sk/scheme-studio--progress-summary))
    buffer))

;;;###autoload
(defun sk/scheme-studio ()
  "Create or reopen the focused Scheme Studio."
  (interactive)
  (sk/scheme-studio--open-exercise
   (sk/scheme-studio--initialize) t))

(defalias 'sk/scheme-studio-create #'sk/scheme-studio)

(defun sk/scheme-studio-hint ()
  "Show the hint for the active exercise."
  (interactive)
  (sk/scheme-studio--initialize)
  (sk/scheme-studio--display-documentation
   (sk/scheme-studio--current) t))

(defun sk/scheme-studio-progress ()
  "Open the explicit Org progress file."
  (interactive)
  (sk/scheme-studio--initialize)
  (let* ((file
          (sk/scheme-studio--workspace-file
           sk/scheme-studio-progress-file))
         (buffer (find-file-noselect file))
         (window (sk/window-display-right buffer 0.42 1)))
    (select-window window)))

(defun sk/scheme-studio-reset ()
  "Restore the active starter after confirmation."
  (interactive)
  (let* ((exercise (sk/scheme-studio--initialize))
         (starter (sk/scheme-studio--source-file exercise "starter.scm"))
         (solution (sk/scheme-studio--solution exercise)))
    (when (yes-or-no-p (format "Reset %s? " exercise))
      (copy-file starter solution t)
      (sk/scheme-studio--set-complete exercise nil)
      (when-let ((buffer (find-buffer-visiting solution)))
        (with-current-buffer buffer
          (revert-buffer :ignore-auto :noconfirm)))
      (message "Scheme Studio reset: %s" exercise))))

(defun sk/scheme-studio--test-command (exercise)
  "Return the pinned test command for EXERCISE."
  (list sk/lisp-guix-shell "core" "--" "guile" "--no-auto-compile"
        "-s" (sk/scheme-studio--source-file exercise "test.scm")
        (sk/scheme-studio--solution exercise)))

(defun sk/scheme-studio--open-next (exercise)
  "Open the exercise following EXERCISE."
  (let ((next (cadr (member exercise (sk/scheme-studio--exercises)))))
    (if next
        (sk/scheme-studio--open-exercise next)
      (message "Scheme Studio curriculum complete (%s)"
               (sk/scheme-studio--progress-summary)))))

(defun sk/scheme-studio--test-sentinel (process _event)
  "Record completion when Scheme Studio test PROCESS exits."
  (when (memq (process-status process) '(exit signal))
    (let ((exercise (process-get process 'exercise))
          (advance (process-get process 'advance))
          (status (process-exit-status process))
          (buffer (process-buffer process)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert (format "\nScheme Studio test: %s\n"
                            (if (zerop status) "PASS" "FAIL"))))))
      (if (zerop status)
          (progn
            (sk/scheme-studio--set-complete exercise t)
            (when advance
              (sk/scheme-studio--open-next exercise)))
        (message "Scheme Studio test failed; inspect %s"
                 (buffer-name buffer))))))

(defun sk/scheme-studio-test (&optional advance)
  "Test the active exercise in the pinned Guix environment.
When ADVANCE is non-nil, open the next exercise after a passing test."
  (interactive)
  (let ((existing (get-buffer-process "*Scheme Studio Test*")))
    (when (and existing (process-live-p existing))
      (user-error "A Scheme Studio test is already running")))
  (let* ((exercise (sk/scheme-studio--initialize))
         (solution (sk/scheme-studio--solution exercise))
         (command (sk/scheme-studio--test-command exercise))
         (buffer (get-buffer-create "*Scheme Studio Test*")))
    (save-some-buffers
     t (lambda () (equal buffer-file-name solution)))
    (unless (file-executable-p sk/lisp-guix-shell)
      (user-error "Pinned Lisp shell is not executable: %s"
                  sk/lisp-guix-shell))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (mapconcat #'shell-quote-argument command " ") "\n\n")
        (compilation-mode)))
    (let ((process
           (make-process
            :name "scheme-studio-test"
            :buffer buffer
            :command command
            :noquery t
            :sentinel #'sk/scheme-studio--test-sentinel)))
      (process-put process 'exercise exercise)
      (process-put process 'advance advance))
    (pop-to-buffer buffer)
    buffer))

(defun sk/scheme-studio-next ()
  "Advance after the active exercise passes."
  (interactive)
  (let ((exercise (sk/scheme-studio--initialize)))
    (if (sk/scheme-studio--completed-p exercise)
        (sk/scheme-studio--open-next exercise)
      (sk/scheme-studio-test t))))

(provide 'sk-scheme-studio)

;;; sk-scheme-studio.el ends here
