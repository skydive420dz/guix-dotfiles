;;; racket-backend-check.el --- Connected Racket editor acceptance -*- lexical-binding: t; -*-

;;; Commentary:

;; Run only through scripts/emacs-racket-check.  That wrapper provides a
;; disposable copied project, candidate Home Emacs/Racket Mode, and the pinned
;; Racket manifest.  The test deliberately keeps the real back end and logical
;; REPL live at its failure checkpoint so the outer process can prove teardown.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'xref)
(require 'racket-mode)
(require 'racket-xp)
(require 'sk-racket)

(defvar compilation-last-buffer)
(defvar racket-debug-mode)
(defvar racket-debuggable-files)
(defvar racket--repl-prompt-mark)
(defvar racket--repl-session-id)
(defvar racket--xp-mode-status)
(defvar racket-program)
(defvar racket-repl-command-file)
(defvar racket-submodules-to-run)
(defvar sk/racket-project-root)
(defvar sk/racket-project-wrapper)

(declare-function racket--repl-prompt-mark-end "racket-repl")
(declare-function racket-debug-go "racket-debug")
(declare-function racket-xp-annotate "racket-xp")
(declare-function sk/racket--backend-command "sk-racket")
(declare-function sk/racket--backend-configuration "sk-racket")
(declare-function sk/racket--backend-process "sk-racket")
(declare-function sk/racket--backend-ready-p "sk-racket")
(declare-function sk/racket--live-repl-buffer "sk-racket")
(declare-function sk/racket--repl-buffer-name "sk-racket")
(declare-function sk/racket-debug "sk-racket")
(declare-function sk/racket-docs "sk-racket")
(declare-function sk/racket-eval-buffer "sk-racket")
(declare-function sk/racket-eval-defun "sk-racket")
(declare-function sk/racket-eval-last-sexp "sk-racket")
(declare-function sk/racket-macroexpand "sk-racket")
(declare-function sk/racket-project-check "sk-racket")
(declare-function sk/racket-repl "sk-racket")
(declare-function sk/racket-stop "sk-racket")

(defconst sk/racket-check-source-root
  (file-name-as-directory
   (file-truename
    (or (getenv "SK_EMACS_RACKET_SOURCE_ROOT")
        (error "SK_EMACS_RACKET_SOURCE_ROOT is required"))))
  "Copied repository root used by this checker.")

(defconst sk/racket-check-sandbox-root
  (file-name-as-directory
   (file-truename
    (or (getenv "SK_EMACS_RACKET_SANDBOX_ROOT")
        (error "SK_EMACS_RACKET_SANDBOX_ROOT is required"))))
  "Disposable state root used by this checker.")

(defconst sk/racket-check-project
  (file-name-as-directory
   (file-truename
    (expand-file-name "fixtures/racket" sk/racket-check-source-root)))
  "Copied tracked Racket fixture exercised by the checker.")

(defconst sk/racket-check-source-file
  (file-truename
   (expand-file-name "src/sk/fixture/main.rkt" sk/racket-check-project))
  "Tracked Racket source module used for connected editing checks.")

(defconst sk/racket-check-second-project
  (file-name-as-directory
   (file-truename
    (or (getenv "SK_EMACS_RACKET_SECOND_PROJECT")
        (error "SK_EMACS_RACKET_SECOND_PROJECT is required"))))
  "Second disposable fixture root used to prove project isolation.")

(defconst sk/racket-check-second-source-file
  (file-truename
   (expand-file-name "src/sk/fixture/main.rkt"
                     sk/racket-check-second-project))
  "Source module in the second project-isolation fixture.")

(defconst sk/racket-check-wrapper
  (file-truename
   (expand-file-name "scripts/racket-project" sk/racket-check-source-root))
  "Production Racket project wrapper from the copied repository.")

(defconst sk/racket-check-home-profile
  (file-name-as-directory
   (file-truename
    (or (getenv "SK_EMACS_RACKET_HOME_PROFILE")
        (error "SK_EMACS_RACKET_HOME_PROFILE is required"))))
  "Candidate Home profile whose Racket Mode package is under test.")

(defconst sk/racket-check-initial-processes (process-list)
  "Emacs processes that predate this checker.")

(defconst sk/racket-check-initial-buffers (buffer-list)
  "Emacs buffers that predate this checker.")

(defun sk/racket-check-assert (condition format-string &rest arguments)
  "Signal unless CONDITION is non-nil.
Format ARGUMENTS according to FORMAT-STRING for the failure message."
  (unless condition
    (error "racket-backend-check: %s"
           (apply #'format format-string arguments))))

(defun sk/racket-check-wait-for (predicate description &optional timeout)
  "Wait for PREDICATE or fail with DESCRIPTION after TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 30)))
        value)
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (setq value (or value (funcall predicate)))
    (sk/racket-check-assert value "timed out waiting for %s" description)
    value))

(defun sk/racket-check-created-processes ()
  "Return Emacs processes created by this checker."
  (cl-set-difference (process-list)
                     sk/racket-check-initial-processes
                     :test #'eq))

(defun sk/racket-check-created-buffers ()
  "Return Emacs buffers created by this checker."
  (cl-set-difference (buffer-list)
                     sk/racket-check-initial-buffers
                     :test #'eq))

(defun sk/racket-check-delete-and-reap-process (process &optional timeout)
  "Delete PROCESS and wait up to TIMEOUT seconds for its OS PID to vanish."
  (let ((pid (and (processp process) (process-id process)))
        (deadline (+ (float-time) (or timeout 10))))
    (when (processp process)
      (ignore-errors (set-process-query-on-exit-flag process nil))
      (when (process-live-p process)
        (ignore-errors (delete-process process))))
    (while (and (integerp pid)
                (process-attributes pid)
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (or (not (integerp pid))
        (null (process-attributes pid)))))

(defun sk/racket-check-cleanup ()
  "Remove only processes and buffers created by this checker."
  (dolist (process (sk/racket-check-created-processes))
    (ignore-errors (sk/racket-check-delete-and-reap-process process)))
  (dolist (buffer (sk/racket-check-created-buffers))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (set-buffer-modified-p nil)
        (setq-local kill-buffer-query-functions nil))
      (ignore-errors (kill-buffer buffer)))))

(defun sk/racket-check-output (buffer start regexp description
                                      &optional timeout)
  "Wait in BUFFER after START for REGEXP identified by DESCRIPTION.
Wait at most TIMEOUT seconds, defaulting to 30."
  (let ((deadline (+ (float-time) (or timeout 30)))
        found)
    (while (and (not found) (< (float-time) deadline))
      (setq found
            (and (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (save-excursion
                     (goto-char (min start (point-max)))
                     (re-search-forward regexp nil t)))))
      (unless found
        (accept-process-output nil 0.05)))
    (sk/racket-check-assert
     found "%s matching %S; output was %S"
     description regexp
     (and (buffer-live-p buffer)
          (with-current-buffer buffer
            (buffer-substring-no-properties
             (min start (point-max)) (point-max)))))))

(defun sk/racket-check-with-expression (source-buffer expression command
                                                      regexp description)
  "In SOURCE-BUFFER, insert EXPRESSION and invoke COMMAND.
Then wait for REGEXP in its REPL, identified by DESCRIPTION."
  (let* ((repl (with-current-buffer source-buffer
                 (sk/racket--live-repl-buffer
                  sk/racket-check-project)))
         (output-start (with-current-buffer repl (point-max)))
         insertion-start)
    (with-current-buffer source-buffer
      (goto-char (point-max))
      (setq insertion-start (point))
      (insert "\n" expression "\n")
      (unwind-protect
          (funcall command)
        (delete-region insertion-start (point-max))
        (set-buffer-modified-p nil)))
    (sk/racket-check-output repl output-start regexp description 45)))

(defun sk/racket-check-descendant-pids (parent)
  "Return every current operating-system descendant of PARENT."
  (let ((known (list parent))
        descendants changed)
    (while
        (progn
          (setq changed nil)
          (dolist (pid (list-system-processes))
            (unless (memq pid known)
              (let* ((attributes (process-attributes pid))
                     (ppid (cdr (assq 'ppid attributes))))
                (when (memq ppid known)
                  (push pid known)
                  (push pid descendants)
                  (setq changed t)))))
          changed))
    (sort descendants #'<)))

(defun sk/racket-check-record-live-descendants ()
  "Record the live backend tree for post-Emacs cleanup verification."
  (let* ((pids-file
          (or (getenv "SK_EMACS_RACKET_DESCENDANT_PIDS")
              (error "SK_EMACS_RACKET_DESCENDANT_PIDS is required")))
         (details-file
          (or (getenv "SK_EMACS_RACKET_DESCENDANT_DETAILS")
              (error "SK_EMACS_RACKET_DESCENDANT_DETAILS is required")))
         (pids (sk/racket-check-descendant-pids (emacs-pid))))
    (sk/racket-check-assert
     (>= (length pids) 2)
     "expected live Guix/Racket descendants, found %S" pids)
    (with-temp-file pids-file
      (dolist (pid pids)
        (insert (number-to-string pid) "\n")))
    (with-temp-file details-file
      (dolist (pid pids)
        (let ((attributes (process-attributes pid)))
          (insert
           (format "pid=%s ppid=%s comm=%S args=%S state=%S\n"
                   pid
                   (cdr (assq 'ppid attributes))
                   (cdr (assq 'comm attributes))
                   (cdr (assq 'args attributes))
                   (cdr (assq 'state attributes)))))))
    pids))

(defun sk/racket-check-backend-command (process)
  "Require PROCESS to use the project wrapper plus native backend args."
  (let* ((actual (process-command process))
         (prefix (sk/racket--backend-command sk/racket-check-project))
         (rest (nthcdr (length prefix) actual)))
    (sk/racket-check-assert
     (equal (seq-take actual (length prefix)) prefix)
     "backend did not use the production command prefix: %S" actual)
    (sk/racket-check-assert
     (= (length rest) 2)
     "Racket Mode backend argument count changed: %S" rest)
    (sk/racket-check-assert
     (string-match-p "/racket/main\\.rkt\\'" (car rest))
     "Racket Mode main module is unexpected: %S" (car rest))
    (sk/racket-check-assert
     (member (cadr rest) '("--use-svg" "--do-not-use-svg"))
     "Racket Mode SVG flag is unexpected: %S" (cadr rest))))

(defun sk/racket-check-xp-status (status description)
  "Wait for current buffer's XP STATUS, identified by DESCRIPTION."
  (sk/racket-check-wait-for
   (lambda () (eq racket--xp-mode-status status))
   description 60))

(defun sk/racket-check-xref (source-buffer)
  "Exercise real XP definition and reference data in SOURCE-BUFFER."
  (with-current-buffer source-buffer
    (let ((start (point-max)))
      (unwind-protect
          (progn
            (goto-char start)
            (insert "\n(define (sk-connected-answer) 42)\n"
                    "(sk-connected-answer)\n")
            (racket-xp-annotate)
            (sk/racket-check-xp-status 'ok "XP annotation for xref fixture")
            ;; Look up the definition from the annotated use.
            (goto-char start)
            (search-forward "(sk-connected-answer)" nil nil 2)
            (backward-char 2)
            (let* ((backend (xref-find-backend))
                   (identifier
                    (xref-backend-identifier-at-point backend))
                   (definitions
                    (xref-backend-definitions backend identifier)))
              (sk/racket-check-assert
               (eq backend 'racket-xp-xref)
               "XP xref backend was not selected: %S" backend)
              (sk/racket-check-assert definitions
                                      "XP returned no definition"))
            ;; Reference metadata lives on the annotated definition, so prove
            ;; the reverse direction from that occurrence separately.
            (goto-char start)
            (search-forward "(sk-connected-answer)")
            (backward-char 2)
            (let* ((backend (xref-find-backend))
                   (identifier
                    (xref-backend-identifier-at-point backend))
                   (references
                    (xref-backend-references backend identifier)))
              (sk/racket-check-assert references
                                      "XP returned no current-file references"))
            (princ "racket-backend-check: XP xref PASS\n"))
        (delete-region start (point-max))
        (set-buffer-modified-p nil)
        (racket-xp-annotate)
        (sk/racket-check-xp-status 'ok "XP recovery after xref fixture")))))

(defun sk/racket-check-xp-diagnostics (source-buffer)
  "Exercise a real XP expansion error and recovery in SOURCE-BUFFER."
  (with-current-buffer source-buffer
    (let ((start (point-max)))
      (unwind-protect
          (progn
            (goto-char start)
            (insert "\n(sk-racket-connected-missing)\n")
            (racket-xp-annotate)
            (sk/racket-check-xp-status 'err
                                       "XP unbound-identifier diagnostic")
            (princ "racket-backend-check: XP diagnostic PASS\n"))
        (delete-region start (point-max))
        (set-buffer-modified-p nil)
        (racket-xp-annotate)
        (sk/racket-check-xp-status 'ok "XP post-diagnostic recovery")))))

(defun sk/racket-check-docs-and-macroexpand (source-buffer)
  "Exercise native Racket documentation and macro expansion in SOURCE-BUFFER."
  (with-current-buffer source-buffer
    (let ((start (point-max))
          describe-before stepper-before)
      (unwind-protect
          (progn
            (goto-char start)
            (insert "\n(map add1 '(1 2))\n")
            (racket-xp-annotate)
            (sk/racket-check-xp-status 'ok "XP docs fixture annotation")
            (goto-char start)
            (search-forward "map")
            (setq describe-before
                  (seq-filter
                   (lambda (buffer)
                     (with-current-buffer buffer
                       (derived-mode-p 'racket-describe-mode)))
                   (buffer-list)))
            (sk/racket-docs)
            (sk/racket-check-wait-for
             (lambda ()
               (cl-set-difference
                (seq-filter
                 (lambda (buffer)
                   (with-current-buffer buffer
                     (derived-mode-p 'racket-describe-mode)))
                 (buffer-list))
                describe-before :test #'eq))
             "native Racket documentation buffer" 60)

            (set-buffer source-buffer)
            (goto-char (point-max))
            (insert "(when #t 42)\n")
            (setq stepper-before
                  (seq-filter
                   (lambda (buffer)
                     (with-current-buffer buffer
                       (derived-mode-p 'racket-stepper-mode)))
                   (buffer-list)))
            (sk/racket-macroexpand)
            (sk/racket-check-wait-for
             (lambda ()
               (cl-set-difference
                (seq-filter
                 (lambda (buffer)
                   (with-current-buffer buffer
                     (derived-mode-p 'racket-stepper-mode)))
                 (buffer-list))
                stepper-before :test #'eq))
             "native Racket macro stepper" 60)
            (set-buffer source-buffer)
            (princ "racket-backend-check: docs/macroexpand PASS\n"))
        (when (buffer-live-p source-buffer)
          (with-current-buffer source-buffer
            (delete-region start (point-max))
            (set-buffer-modified-p nil)
            (racket-xp-annotate)
            (sk/racket-check-xp-status
             'ok "XP recovery after docs fixture")))))))

(defun sk/racket-check-debugger (source-buffer repl-buffer)
  "Exercise one native debug break and recovery for SOURCE-BUFFER's REPL-BUFFER."
  (let ((output-start (with-current-buffer repl-buffer (point-max)))
        (prompt-before
         (with-current-buffer repl-buffer racket--repl-prompt-mark))
        (session-before
         (with-current-buffer repl-buffer racket--repl-session-id)))
    (with-current-buffer source-buffer
      ;; These values are consumed while constructing the asynchronous run.
      ;; Pinning both keeps future sibling fixtures out of this smoke test.
      (let ((racket-debuggable-files (list sk/racket-check-source-file))
            (racket-submodules-to-run '((main))))
        (sk/racket-debug)))
    (sk/racket-check-wait-for
     (lambda ()
       (with-current-buffer source-buffer
         (and (bound-and-true-p racket-debug-mode)
              buffer-read-only
              (let ((names
                     (seq-map (lambda (overlay)
                                (overlay-get overlay 'name))
                              (overlays-at (point)))))
                (and (memq 'racket-debug-break names)
                     (memq 'racket-debug-break-span names))))))
     "native Racket debugger break overlays" 90)
    ;; Ignore subsequent breakable positions so this remains a one-break smoke
    ;; test, then wait for the fixture's module+ main result and a live prompt.
    (with-current-buffer source-buffer
      (racket-debug-go))
    (sk/racket-check-output
     repl-buffer output-start "^42\\r?$"
     "debugged Racket module completion" 90)
    (sk/racket-check-wait-for
     (lambda ()
       (and (with-current-buffer source-buffer
              (and (not (bound-and-true-p racket-debug-mode))
                   (not buffer-read-only)))
            (with-current-buffer repl-buffer
              (and (eq racket--repl-session-id session-before)
                   racket--repl-prompt-mark
                   (not (eq racket--repl-prompt-mark prompt-before))
                   (racket--repl-prompt-mark-end)))))
     "post-debug Racket prompt" 60)
    (sk/racket-check-with-expression
     source-buffer "(+ 100 23)" #'sk/racket-eval-last-sexp
     "123" "post-debug Racket evaluation")
    (princ "racket-backend-check: debugger/recovery PASS\n")))

(defun sk/racket-check-project-gate (source-buffer backend-process)
  "Run SOURCE-BUFFER's fixture gate while BACKEND-PROCESS stays connected."
  (let (buffer process)
    (with-current-buffer source-buffer
      (setq buffer (sk/racket-project-check)))
    (setq buffer (or buffer compilation-last-buffer))
    (sk/racket-check-assert (buffer-live-p buffer)
                            "project check created no compilation buffer")
    (setq process (get-buffer-process buffer))
    (when process
      (sk/racket-check-wait-for
       (lambda () (not (process-live-p process)))
       "Racket project check completion" 180)
      (sk/racket-check-assert
       (= (process-exit-status process) 0)
       "Racket project check exited %s; output was %S"
       (process-exit-status process)
       (with-current-buffer buffer (buffer-string))))
    (sk/racket-check-assert
     (with-current-buffer buffer
       (save-excursion
         (goto-char (point-min))
         (re-search-forward "PASS" nil t)))
     "Racket project check omitted its PASS marker: %S"
     (with-current-buffer buffer (buffer-string)))
    (sk/racket-check-assert
     (process-live-p backend-process)
     "project check stopped the connected editor back end")
    (princ "racket-backend-check: project gate PASS\n")))

(defun sk/racket-check-state-containment ()
  "Assert that connected Racket work did not escape disposable state roots."
  (dolist (path (list (expand-file-name ".racket" (getenv "HOME"))
                      (expand-file-name ".config/racket" (getenv "HOME"))
                      (expand-file-name ".local/share/racket" (getenv "HOME"))))
    (sk/racket-check-assert
     (not (file-exists-p path))
     "Racket user state escaped into isolated HOME: %s" path))
  (sk/racket-check-assert
   (file-in-directory-p
    (file-truename racket-repl-command-file)
    (file-truename (getenv "XDG_CACHE_HOME")))
   "Racket Mode command file escaped XDG cache: %s"
   racket-repl-command-file)
  (let ((compiled
         (seq-filter
          (lambda (path)
            (and (file-directory-p path)
                 (string= (file-name-nondirectory
                           (directory-file-name path))
                          "compiled")))
          (directory-files-recursively sk/racket-check-project "." t))))
    (sk/racket-check-assert
     (null compiled)
     "compiled Racket state leaked into the source project: %S" compiled)))

(let (source-buffer second-source-buffer repl-buffer backend-process
                    unrelated-process unrelated-pid)
  (unwind-protect
      (progn
        (sk/racket-check-assert
         (file-equal-p sk/racket-project-wrapper sk/racket-check-wrapper)
         "initialized project wrapper differs: %S"
         sk/racket-project-wrapper)
        (sk/racket-check-assert
         (equal racket-program
                (list sk/racket-check-wrapper
                      "--project" "." "backend"))
         "global runtime-detached fallback changed: %S" racket-program)
        (sk/racket-check-assert
         (file-in-directory-p
          (file-truename sk/racket-check-source-root)
          (file-truename sk/racket-check-sandbox-root))
         "copied source root escaped sandbox: %s"
         sk/racket-check-source-root)

        ;; The cold acceptance point is intentionally before any explicit
        ;; Racket action.  Merely selecting racket-mode must remain process-free.
        (let ((before (process-list)))
          (setq source-buffer (find-file-noselect sk/racket-check-source-file))
          (setq second-source-buffer
                (find-file-noselect sk/racket-check-second-source-file))
          (with-current-buffer source-buffer
            (sk/racket-check-assert (derived-mode-p 'racket-mode)
                                    "tracked .rkt file missed racket-mode")
            (sk/racket-check-assert (not (bound-and-true-p racket-xp-mode))
                                    "opening source enabled XP")
            (sk/racket-check-assert
             (equal sk/racket-project-root sk/racket-check-project)
             "source buffer project root differs: %S"
             sk/racket-project-root)
            (let ((configuration
                   (sk/racket--backend-configuration
                    sk/racket-check-project)))
              (sk/racket-check-assert configuration
                                      "source hook installed no backend config")
              (sk/racket-check-assert
               (equal (plist-get configuration :racket-program)
                      (sk/racket--backend-command sk/racket-check-project))
               "project backend command differs: %S" configuration)))
          (with-current-buffer second-source-buffer
            (sk/racket-check-assert (derived-mode-p 'racket-mode)
                                    "second .rkt file missed racket-mode")
            (sk/racket-check-assert (not (bound-and-true-p racket-xp-mode))
                                    "second cold project enabled XP")
            (sk/racket-check-assert
             (equal sk/racket-project-root sk/racket-check-second-project)
             "second source project root differs: %S"
             sk/racket-project-root)
            (let ((configuration
                   (sk/racket--backend-configuration
                    sk/racket-check-second-project)))
              (sk/racket-check-assert configuration
                                      "second project installed no config")
              (sk/racket-check-assert
               (equal (plist-get configuration :racket-program)
                      (sk/racket--backend-command
                       sk/racket-check-second-project))
               "second project backend command differs: %S"
               configuration)))
          (sk/racket-check-assert
           (not (eq (sk/racket--backend-configuration
                     sk/racket-check-project)
                    (sk/racket--backend-configuration
                     sk/racket-check-second-project)))
           "two canonical roots shared one backend configuration")
          (sk/racket-check-assert
           (not (equal (sk/racket--repl-buffer-name
                        sk/racket-check-project)
                       (sk/racket--repl-buffer-name
                        sk/racket-check-second-project)))
           "two canonical roots shared one REPL name")
          (sk/racket-check-assert
           (equal before (process-list))
           "opening Racket source created a process: %S"
           (cl-set-difference (process-list) before :test #'eq)))
        (princ "racket-backend-check: cold edit PASS\n")

        (with-current-buffer source-buffer
          (sk/racket-repl))
        (setq repl-buffer
              (sk/racket-check-wait-for
               (lambda ()
                 (with-current-buffer source-buffer
                   (sk/racket--live-repl-buffer
                    sk/racket-check-project)))
               "project logical Racket REPL" 90))
        (setq backend-process
              (sk/racket-check-wait-for
               (lambda ()
                 (with-current-buffer source-buffer
                   (and (sk/racket--backend-ready-p
                         sk/racket-check-project)
                        (sk/racket--backend-process
                         sk/racket-check-project))))
               "ready Racket Mode backend" 120))
        (sk/racket-check-assert (process-live-p backend-process)
                                "Racket backend is not live")
        (sk/racket-check-backend-command backend-process)
        (with-current-buffer repl-buffer
          (sk/racket-check-wait-for
           (lambda ()
             (and racket--repl-session-id
                  racket--repl-prompt-mark
                  (racket--repl-prompt-mark-end)))
           "logical Racket prompt" 90)
          (sk/racket-check-assert
           (equal sk/racket-project-root sk/racket-check-project)
           "REPL lost its project tag: %S" sk/racket-project-root))
        (sk/racket-check-assert
         (not (with-current-buffer second-source-buffer
                (sk/racket--backend-process
                 sk/racket-check-second-project)))
         "first project eagerly started the second project's backend")
        (sk/racket-check-assert
         (not (get-buffer
               (sk/racket--repl-buffer-name
                sk/racket-check-second-project)))
         "first project created the second project's REPL")
        (let ((session-id
               (with-current-buffer repl-buffer racket--repl-session-id)))
          (with-current-buffer source-buffer
            (sk/racket-repl))
          (sk/racket-check-assert
           (eq backend-process
               (with-current-buffer source-buffer
                 (sk/racket--backend-process sk/racket-check-project)))
           "repeated project REPL command replaced the backend process")
          (sk/racket-check-assert
           (eq session-id
               (with-current-buffer repl-buffer racket--repl-session-id))
           "repeated project REPL command replaced the logical session"))
        (with-current-buffer source-buffer
          (sk/racket-check-xp-status 'ok "initial XP annotation"))

        ;; Exercise the whole-buffer shared route, not just the initial run
        ;; nested inside sk/racket-repl.  The fixture's module+ main prints 42.
        (let ((output-start (with-current-buffer repl-buffer (point-max))))
          (with-current-buffer source-buffer
            (sk/racket-eval-buffer))
          (sk/racket-check-output
           repl-buffer output-start "^42\\r?$"
           "Racket whole-module run output 42" 60))
        (princ "racket-backend-check: whole-module run PASS\n")

        (sk/racket-check-with-expression
         source-buffer "(+ 20 22)" #'sk/racket-eval-last-sexp
         "42" "Racket evaluation result 42")
        (sk/racket-check-with-expression
         source-buffer "(error 'sk-racket \"SK-RACKET-SYNTHETIC\")"
         #'sk/racket-eval-last-sexp
         "SK-RACKET-SYNTHETIC" "controlled Racket exception")
        (sk/racket-check-with-expression
         source-buffer "(+ 40 2)" #'sk/racket-eval-last-sexp
         "42" "post-exception Racket recovery")
        (sk/racket-check-with-expression
         source-buffer "(define (sk-connected-definition) 42)"
         #'sk/racket-eval-defun
         "sk-connected-definition" "Racket definition send")
        (sk/racket-check-with-expression
         source-buffer "(sk-connected-definition)"
         #'sk/racket-eval-last-sexp
         "42" "post-definition Racket evaluation")
        (princ "racket-backend-check: REPL evaluation/recovery PASS\n")

        (sk/racket-check-xp-diagnostics source-buffer)
        (sk/racket-check-xref source-buffer)
        (sk/racket-check-docs-and-macroexpand source-buffer)
        (sk/racket-check-debugger source-buffer repl-buffer)
        (sk/racket-check-project-gate source-buffer backend-process)
        (sk/racket-check-state-containment)

        ;; A separately-created Emacs child has its own process group.  It is a
        ;; live canary proving the project stop targets only the backend group.
        (setq unrelated-process
              (make-process
               :name "sk-racket-unrelated-process"
               :command (list (or (executable-find "sleep")
                                  (error "Candidate sleep is unavailable"))
                              "120")
               :connection-type 'pipe
               :noquery t))
        (setq unrelated-pid (process-id unrelated-process))
        (let* ((backend-pid (process-id backend-process))
               (backend-group
                (cdr (assq 'pgrp (process-attributes backend-pid))))
               (unrelated-group
                (cdr (assq 'pgrp (process-attributes unrelated-pid)))))
          (sk/racket-check-assert
           (and (equal backend-pid backend-group)
                (equal unrelated-pid unrelated-group)
                (not (equal backend-group unrelated-group)))
           "backend/unrelated process-group isolation failed: %S/%S %S/%S"
           backend-pid backend-group unrelated-pid unrelated-group))

        ;; Both the success and deliberate-failure paths record the real live
        ;; hierarchy.  The outer shell must prove every recorded PID and every
        ;; sandbox-token process disappeared after Emacs unwinds.
        (sk/racket-check-record-live-descendants)
        (when (equal (getenv "SK_EMACS_RACKET_CHECK_BREAK") "1")
          (error "Deliberate connected failure with Racket backend/REPL live"))

        (with-current-buffer source-buffer
          (sk/racket-stop))
        (sk/racket-check-assert
         (not (process-live-p backend-process))
         "Racket backend survived scoped stop")
        (sk/racket-check-assert
         (not (buffer-live-p repl-buffer))
         "logical Racket REPL survived scoped stop")
        (sk/racket-check-assert
         (process-live-p unrelated-process)
         "scoped Racket stop killed an unrelated Emacs process group")
        (sk/racket-check-assert
         (sk/racket-check-delete-and-reap-process unrelated-process 30)
         "unrelated process-group canary PID %s was not reaped"
         unrelated-pid)
        (sk/racket-check-assert
         (not (cl-some #'process-live-p
                       (sk/racket-check-created-processes)))
         "an Emacs process survived connected editor cleanup")
        (princ "racket-backend-check: PASS\n"))
    (when (and source-buffer (buffer-live-p source-buffer))
      (with-current-buffer source-buffer
        (when (or (sk/racket--live-repl-buffer sk/racket-check-project)
                  (let ((process
                         (ignore-errors
                           (sk/racket--backend-process
                            sk/racket-check-project))))
                    (and process (process-live-p process))))
          (ignore-errors (sk/racket-stop)))))
    (sk/racket-check-cleanup)))

;;; racket-backend-check.el ends here
