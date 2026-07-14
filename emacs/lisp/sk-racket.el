;;; sk-racket.el --- Runtime-detached Racket editing -*- lexical-binding: t; -*-

;;; Commentary:

;; Racket Mode is persistent editor tooling, but Racket itself belongs only to
;; the explicit Racket development manifest.  Opening a source file therefore
;; configures editing and a project-keyed command description without enabling
;; racket-xp-mode or starting any process.  SPC l r is the explicit boundary
;; that enters the manifest and starts both the back end and project REPL.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'sk-lisp)

(defvar company-backends)
(defvar racket--repl-session-id)
(defvar racket--xp-annotate-idle-timer)
(defvar racket-back-end-configurations)
(defvar racket-doc-index-directory)
(defvar racket-program)
(defvar racket-repl-buffer-name)
(defvar racket-repl-buffer-name-function)
(defvar racket-repl-command-file)
(defvar racket-repl-history-directory)
(defvar racket-xp-mode)
(defvar sk/cache-directory)
(defvar sk/user-directory)

(declare-function racket-add-back-end "racket-back-end")
(declare-function racket-back-end "racket-back-end")
(declare-function racket-back-end-name "racket-back-end")
(declare-function racket-expand-last-sexp "racket-stepper")
(declare-function racket-logger-mode "racket-logger")
(declare-function racket-repl-exit "racket-repl")
(declare-function racket-run "racket-repl")
(declare-function racket-run-and-switch-to-repl "racket-repl")
(declare-function racket-run-with-debugging "racket-repl")
(declare-function racket-send-definition "racket-repl")
(declare-function racket-send-last-sexp "racket-repl")
(declare-function racket-stop-back-end "racket-cmd")
(declare-function racket-xp-annotate "racket-xp")
(declare-function racket-xp-describe "racket-xp")
(declare-function racket-xp-mode "racket-xp")
(declare-function racket--back-end-process-name "racket-back-end")
(declare-function racket--cmd-ready-p "racket-cmd")
(declare-function racket--logger-activate-config "racket-logger")

(defconst sk/racket-repository-directory
  (file-name-as-directory
   (file-truename (expand-file-name ".." sk/user-directory)))
  "Absolute root of the checkout that owns the Racket wrapper.")

(defconst sk/racket-project-wrapper
  (expand-file-name "scripts/racket-project"
                    sk/racket-repository-directory)
  "Absolute project-aware wrapper for every Racket runtime action.")

(defconst sk/racket-cache-directory
  (file-name-as-directory
   (expand-file-name "racket-mode" sk/cache-directory))
  "Generated Racket Mode state below the configured Emacs cache.")

(defconst sk/racket-stop-timeout 10.0
  "Seconds allowed for each bounded Racket shutdown phase.")

(dolist (directory '("doc-index" "history"))
  (make-directory (expand-file-name directory sk/racket-cache-directory) t))

;; Set these before Racket Mode is loaded.  Defcustom will preserve the values,
;; and every path that package writes remains outside the source checkout.
(setq racket-doc-index-directory
      (file-name-as-directory
       (expand-file-name "doc-index" sk/racket-cache-directory))
      racket-repl-history-directory
      (file-name-as-directory
       (expand-file-name "history" sk/racket-cache-directory))
      racket-repl-command-file
      (expand-file-name "repl.rkt" sk/racket-cache-directory)
      ;; A project configuration replaces "." with its canonical absolute
      ;; root.  This fallback still routes manual package commands through the
      ;; runtime-detached wrapper instead of searching PATH for Racket.
      racket-program
      (list sk/racket-project-wrapper "--project" "." "backend")
      racket-repl-buffer-name-function #'sk/racket--set-repl-buffer-name)

(defvar-local sk/racket-project-root nil
  "Canonical project root associated with this Racket or REPL buffer.")

(defun sk/racket--canonical-root (&optional required)
  "Return this buffer's canonical Racket root, or signal when REQUIRED."
  (or sk/racket-project-root
      (sk/lisp--project-root required)))

(defun sk/racket--project-key (root)
  "Return the shared readable key for canonical project ROOT."
  (if (fboundp 'sk/lisp--project-key)
      (sk/lisp--project-key root)
    (format "%s-%s"
            (file-name-nondirectory (directory-file-name root))
            (substring (secure-hash 'sha1 root) 0 8))))

(defun sk/racket--repl-buffer-name (root)
  "Return the unique Racket REPL buffer name for ROOT."
  (format "*Racket REPL <%s>*" (sk/racket--project-key root)))

(defun sk/racket--logger-buffer-name (root)
  "Return Racket Mode's logger buffer name for project ROOT."
  (format "*Racket Logger <%s>*"
          (file-name-as-directory (file-truename root))))

(defun sk/racket--prepare-logger-buffer (root)
  "Create ROOT's logger buffer without starting or selecting a back end.
The pinned package otherwise creates this buffer from a timer context; its
configuration callback would then select the fallback slash back end."
  (require 'racket-logger)
  (let ((buffer (get-buffer-create (sk/racket--logger-buffer-name root))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'racket-logger-mode)
        (racket-logger-mode))
      (setq default-directory root)
      (setq-local sk/racket-project-root root))
    buffer))

(defun sk/racket--set-repl-buffer-name ()
  "Select a deterministic REPL name without consulting or starting a back end."
  (let* ((root (sk/lisp--project-root))
         (identity (or root
                       (file-name-as-directory
                        (file-truename default-directory)))))
    (when root
      (setq-local sk/racket-project-root root))
    (setq-local racket-repl-buffer-name
                (sk/racket--repl-buffer-name identity))))

(defun sk/racket--command (root action &rest arguments)
  "Return the project wrapper command for ROOT, ACTION, and ARGUMENTS."
  (let ((root (file-name-as-directory (file-truename root))))
    (append (list sk/racket-project-wrapper "--project" root action)
            arguments)))

(defun sk/racket--backend-command (root)
  "Return Racket Mode's production back-end command prefix for ROOT."
  (sk/racket--command root "backend"))

(defun sk/racket--backend-configuration (root)
  "Return the exact Racket Mode back-end configuration for ROOT, or nil."
  (let ((root (file-name-as-directory (file-truename root))))
    (cl-find-if
     (lambda (configuration)
       (equal root
              (file-name-as-directory
               (file-truename (plist-get configuration :directory)))))
     racket-back-end-configurations)))

(defun sk/racket--ensure-project-back-end (&optional root)
  "Install and return a process-free Racket Mode configuration for ROOT."
  (unless (fboundp 'racket-add-back-end)
    (user-error "Racket Mode is not available"))
  (let* ((root (file-name-as-directory
                (file-truename
                 (or root (sk/racket--canonical-root t)))))
         (command (sk/racket--backend-command root))
         (configuration (sk/racket--backend-configuration root)))
    (if (and configuration
             (equal (plist-get configuration :racket-program) command))
        configuration
      (racket-add-back-end root :racket-program command))))

(defun sk/racket--backend-process (&optional root)
  "Return the Racket Mode back-end process selected for ROOT, or nil."
  (let* ((root (file-name-as-directory
                (file-truename
                 (or root (sk/racket--canonical-root t)))))
         (default-directory root)
         (back-end (sk/racket--ensure-project-back-end root)))
    ;; Racket Mode has no public process accessor.  Keep this pinned-package
    ;; compatibility boundary isolated in one helper.
    (when (fboundp 'racket--back-end-process-name)
      (get-process (racket--back-end-process-name back-end)))))

(defun sk/racket--backend-ready-p (&optional root)
  "Return non-nil when ROOT's project back end is ready for commands."
  (let* ((root (or root (sk/racket--canonical-root)))
         (process (and root (sk/racket--backend-process root))))
    (and (processp process)
         (process-live-p process)
         (let ((default-directory root))
           (and (fboundp 'racket--cmd-ready-p)
                (racket--cmd-ready-p))))))

(defun sk/racket--live-repl-buffer (&optional root)
  "Return ROOT's live logical Racket REPL buffer, or nil."
  (let* ((root (or root (sk/racket--canonical-root)))
         (buffer (and root
                      (get-buffer (sk/racket--repl-buffer-name root)))))
    (and buffer
         (buffer-live-p buffer)
         (with-current-buffer buffer
           (and (derived-mode-p 'racket-repl-mode)
                racket--repl-session-id
                (equal root sk/racket-project-root)
                buffer)))))

(defun sk/racket--require-edit-buffer ()
  "Require a Racket source buffer owned by a marked project."
  (unless (derived-mode-p 'racket-mode)
    (user-error "Racket command requires a Racket source buffer"))
  (sk/racket--canonical-root t))

(defun sk/racket--require-repl ()
  "Return the current project's live Racket REPL or signal clearly."
  (let* ((root (sk/racket--canonical-root t))
         (buffer (sk/racket--live-repl-buffer root)))
    (unless (and buffer (sk/racket--backend-ready-p root))
      (user-error "No project Racket REPL is active; run SPC l r first"))
    buffer))

(defun sk/racket--require-xp ()
  "Require active XP analysis and a ready project back end."
  (sk/racket--require-edit-buffer)
  (sk/racket--require-repl)
  (unless (bound-and-true-p racket-xp-mode)
    (user-error "Racket XP analysis is inactive; run SPC l r first")))

(defun sk/racket-mode-setup ()
  "Configure Racket editing without starting Racket or XP analysis."
  (eldoc-mode 1)
  (when (fboundp 'company-mode)
    (company-mode 1)
    (setq-local company-backends
                '((company-capf company-yasnippet)
                  company-files
                  company-keywords
                  company-dabbrev-code)))
  (when-let ((root (sk/lisp--project-root)))
    (setq-local sk/racket-project-root root
                racket-repl-buffer-name
                (sk/racket--repl-buffer-name root))
    ;; This mutates only Racket Mode's configuration list; it neither enables
    ;; XP nor creates a process.
    (sk/racket--ensure-project-back-end root)))

(defun sk/racket-repl-mode-setup ()
  "Apply the shared structural editing policy to a Racket REPL buffer."
  (eldoc-mode 1)
  (when (fboundp 'puni-mode)
    (puni-mode 1)))

(use-package racket-mode
  :if (locate-library "racket-mode")
  :demand t
  :hook ((racket-mode . sk/racket-mode-setup)
         (racket-repl-mode . sk/racket-repl-mode-setup))
  :config
  ;; Loading these front-end libraries is process-free.  Their modes remain
  ;; disabled until the explicit project command below.
  (require 'racket-xp)
  (require 'racket-stepper))

(defun sk/racket-repl ()
  "Start or switch to the explicit Guix Racket REPL for this project."
  (interactive)
  (let* ((root (sk/racket--require-edit-buffer))
         (existing (sk/racket--live-repl-buffer root)))
    (unless (file-executable-p sk/racket-project-wrapper)
      (user-error "Racket project wrapper is not executable: %s"
                  sk/racket-project-wrapper))
    (sk/racket--ensure-project-back-end root)
    ;; Pre-create the per-backend logger in the correct project context.  This
    ;; is buffer-only and prevents Racket Mode's asynchronous logger callback
    ;; from accidentally starting its fallback slash backend.
    (let ((logger (sk/racket--prepare-logger-buffer root)))
      (unless (bound-and-true-p racket-xp-mode)
        (racket-xp-mode 1))
      ;; Pre-creation deliberately bypasses the package's automatic activation
      ;; because that callback runs from the new logger buffer.  Activate now,
      ;; after setting its project context and opening the correct back end.
      (with-current-buffer logger
        (racket--logger-activate-config))
      (if existing
          (pop-to-buffer existing)
        (racket-run-and-switch-to-repl)
        ;; Racket Mode creates the logical REPL buffer synchronously even though
        ;; its run request completes asynchronously.  Tag it immediately so no
        ;; other project's command can claim it during startup.
        (when-let ((buffer (get-buffer (sk/racket--repl-buffer-name root))))
          (with-current-buffer buffer
            (setq-local sk/racket-project-root root)))))))

(defun sk/racket-eval-buffer ()
  "Run the current Racket module as the REPL's source of truth."
  (interactive)
  (sk/racket--require-repl)
  (racket-run))

(defun sk/racket-eval-defun ()
  "Send the current Racket top-level definition to the project REPL."
  (interactive)
  (sk/racket--require-repl)
  (racket-send-definition))

(defun sk/racket-eval-last-sexp ()
  "Send the Racket expression before point to the project REPL."
  (interactive)
  (sk/racket--require-repl)
  (racket-send-last-sexp))

(defun sk/racket-docs ()
  "Describe the Racket identifier at point using active XP analysis."
  (interactive)
  (sk/racket--require-xp)
  (racket-xp-describe))

(defun sk/racket-definition ()
  "Visit the Racket definition at point through the XP xref back end."
  (interactive)
  (sk/racket--require-xp)
  (call-interactively #'xref-find-definitions))

(defun sk/racket-references ()
  "Show current-file Racket references through the XP xref back end."
  (interactive)
  (sk/racket--require-xp)
  (call-interactively #'xref-find-references))

(defun sk/racket-macroexpand ()
  "Expand the Racket expression before point in the native stepper."
  (interactive)
  (sk/racket--require-xp)
  (racket-expand-last-sexp))

(defun sk/racket-debug ()
  "Re-run the current Racket module with native debug instrumentation."
  (interactive)
  (sk/racket--require-repl)
  (racket-run-with-debugging))

(defun sk/racket-refresh-diagnostics ()
  "Request immediate XP re-annotation for the current Racket buffer."
  (interactive)
  (sk/racket--require-xp)
  (racket-xp-annotate))

(defun sk/racket-format-buffer ()
  "Apply Racket Mode's native indentation to the whole buffer."
  (interactive)
  (sk/racket--require-edit-buffer)
  (indent-region (point-min) (point-max)))

(defun sk/racket-project-check ()
  "Run the current Racket project's manifest-owned check action."
  (interactive)
  (let* ((root (sk/racket--canonical-root t))
         (default-directory root)
         (command (mapconcat #'shell-quote-argument
                             (sk/racket--command root "check") " "))
         (compilation-buffer-name-function
          (lambda (_mode)
            (format "*racket-check-%s*" (sk/racket--project-key root)))))
    (unless (file-executable-p sk/racket-project-wrapper)
      (user-error "Racket project wrapper is not executable: %s"
                  sk/racket-project-wrapper))
    (compile command)))

(defun sk/racket--project-buffers (root)
  "Return Racket source and REPL buffers tagged for ROOT."
  (seq-filter
   (lambda (buffer)
     (and (buffer-live-p buffer)
          (with-current-buffer buffer
            (and (derived-mode-p 'racket-mode 'racket-repl-mode
                                 'racket-logger-mode)
                 (equal sk/racket-project-root root)))))
   (buffer-list)))

(defun sk/racket--wait-for (predicate timeout)
  "Wait at most TIMEOUT seconds for PREDICATE, returning its value."
  (let ((deadline (+ (float-time) timeout))
        value)
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (or value (funcall predicate))))

(defun sk/racket--process-group-members (process-group)
  "Return operating-system processes that still belong to PROCESS-GROUP."
  (seq-filter
   (lambda (pid)
     (equal process-group
            (cdr (assq 'pgrp (process-attributes pid)))))
   (list-system-processes)))

(defun sk/racket--terminate-backend-group (process)
  "Gracefully terminate PROCESS's isolated operating-system process group.
Return non-nil only after every member of the validated group has drained."
  (let* ((pid (and (processp process) (process-id process)))
         (attributes (and (integerp pid) (process-attributes pid)))
         (process-group (cdr (assq 'pgrp attributes))))
    ;; Emacs 30 creates subprocesses as new process-group leaders.  Signal the
    ;; negative group ID only after proving that invariant; otherwise leave the
    ;; pinned package's public stop command to perform its normal fallback.
    (when (and (process-live-p process)
               (integerp pid)
               (> pid 1)
               (equal process-group pid))
      (ignore-errors (signal-process (- pid) 15))
      (or (sk/racket--wait-for
           (lambda () (null (sk/racket--process-group-members pid)))
           sk/racket-stop-timeout)
          (progn
            (ignore-errors (signal-process (- pid) 9))
            (sk/racket--wait-for
             (lambda () (null (sk/racket--process-group-members pid)))
             sk/racket-stop-timeout))))))

(defun sk/racket--disable-project-xp (root)
  "Disable XP and cancel pending annotation timers only for ROOT."
  (dolist (buffer (sk/racket--project-buffers root))
    (with-current-buffer buffer
      (when (bound-and-true-p racket-xp-mode)
        (racket-xp-mode -1))
      (when (and (boundp 'racket--xp-annotate-idle-timer)
                 (timerp racket--xp-annotate-idle-timer))
        (cancel-timer racket--xp-annotate-idle-timer)
        (setq racket--xp-annotate-idle-timer nil)))))

(defun sk/racket-stop ()
  "Stop only the current project's logical REPL and Racket Mode back end."
  (interactive)
  (let* ((root (sk/racket--canonical-root t))
         (repl (sk/racket--live-repl-buffer root))
         (logger (get-buffer (sk/racket--logger-buffer-name root)))
         (process (sk/racket--backend-process root))
         (session-stopped (not repl))
         (process-stopped (not (and process (process-live-p process))))
         (process-group-stopped process-stopped))
    (unless (or repl (not process-stopped))
      (user-error "No Racket backend is active for %s" root))
    ;; First ask the logical REPL session to exit while its transport is live.
    (when repl
      (if (and process (process-live-p process))
          (progn
            (with-current-buffer repl
              ;; A broken logical session must not prevent the transport
              ;; fallback below from running.
              (ignore-errors (racket-repl-exit)))
            (setq session-stopped
                  (sk/racket--wait-for
                   (lambda ()
                     (or (not (buffer-live-p repl))
                         (with-current-buffer repl
                           (null racket--repl-session-id))))
                   sk/racket-stop-timeout)))
        ;; Racket Mode cannot acknowledge a logical exit after its transport
        ;; has crashed.  The stale local buffer is still safe to remove below.
        (setq session-stopped t)))

    ;; XP can auto-request the back end.  Disable it in this project only, and
    ;; cancel any already-scheduled annotations before closing the transport.
    (sk/racket--disable-project-xp root)
    (when (and process (process-live-p process))
      ;; Let the wrapper, pinned Guix, and Racket unwind together.  The public
      ;; command below then clears Racket Mode's process/buffer bookkeeping; if
      ;; TERM did not drain the isolated group, Emacs 30's `delete-process'
      ;; provides the group-wide SIGKILL fallback.
      (setq process-group-stopped
            (sk/racket--terminate-backend-group process))
      (let ((default-directory root))
        (ignore-errors (racket-stop-back-end)))
      (setq process-stopped
            (sk/racket--wait-for
             (lambda () (not (process-live-p process)))
             sk/racket-stop-timeout))
      (unless process-stopped
        (set-process-query-on-exit-flag process nil)
        (delete-process process)
        (setq process-stopped
              (sk/racket--wait-for
               (lambda () (not (process-live-p process)))
               1.0))))
    ;; When PID/PGRP validation is unavailable, the pinned package's public
    ;; stop path is the documented process-group fallback.  A drained Emacs
    ;; process therefore completes that fallback instead of reporting a false
    ;; timeout after successful cleanup.
    (setq process-group-stopped
          (or process-group-stopped process-stopped))
    (when (buffer-live-p repl)
      (with-current-buffer repl
        (set-buffer-modified-p nil)
        (setq-local kill-buffer-query-functions nil))
      (kill-buffer repl))
    (setq session-stopped (not (buffer-live-p repl)))
    (when (buffer-live-p logger)
      (with-current-buffer logger
        (set-buffer-modified-p nil)
        (setq-local kill-buffer-query-functions nil))
      (kill-buffer logger))
    (unless (and session-stopped process-stopped process-group-stopped)
      (user-error "Racket shutdown exceeded its bounded cleanup timeout"))
    (message "Stopped Racket backend for %s"
             (file-name-nondirectory (directory-file-name root)))))

(provide 'sk-racket)

;;; sk-racket.el ends here
