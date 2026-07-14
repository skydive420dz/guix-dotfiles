;;; fennel-backend-check.el --- Connected Fennel editor acceptance -*- lexical-binding: t; -*-

;;; Commentary:

;; Run only through scripts/emacs-fennel-check.  The shell wrapper supplies two
;; disposable copies of the tracked fixture, candidate Home Emacs packages,
;; and isolated XDG state.  This file exercises the real protocol REPL and
;; fennel-ls while keeping cleanup project-scoped and failure-safe.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'xref)
(require 'fennel-mode)
(require 'fennel-proto-repl)
(require 'lsp-mode)
(require 'lsp-diagnostics)
(require 'sk-fennel)

(defvar compilation-last-buffer)
(defvar fennel-proto-repl--buffer)
(defvar fennel-proto-repl-minor-mode)
(defvar lsp-mode)
(defvar sk/fennel-project-root)
(defvar sk/fennel-project-wrapper)

(declare-function fennel-proto-repl-send-message-sync "fennel-proto-repl")
(declare-function lsp--fix-path-casing "lsp-mode")
(declare-function lsp--workspace-diagnostics "lsp-mode")
(declare-function lsp--workspace-proc "lsp-mode")
(declare-function lsp--workspace-status "lsp-mode")
(declare-function lsp--workspace-server-id "lsp-mode")
(declare-function lsp-diagnostics "lsp-mode")
(declare-function lsp-workspaces "lsp-mode")
(declare-function sk/fennel--command "sk-fennel")
(declare-function sk/fennel--live-repl-buffer "sk-fennel")
(declare-function sk/fennel--repl-buffer-name "sk-fennel")
(declare-function sk/fennel--server-process "sk-fennel")

(defconst sk/fennel-check-source-root
  (file-name-as-directory
   (file-truename
    (or (getenv "SK_EMACS_FENNEL_SOURCE_ROOT")
        (error "SK_EMACS_FENNEL_SOURCE_ROOT is required"))))
  "Copied repository root used by this checker.")

(defconst sk/fennel-check-sandbox-root
  (file-name-as-directory
   (file-truename
    (or (getenv "SK_EMACS_FENNEL_SANDBOX_ROOT")
        (error "SK_EMACS_FENNEL_SANDBOX_ROOT is required"))))
  "Disposable state root used by this checker.")

(defconst sk/fennel-check-project
  (file-name-as-directory
   (file-truename
    (expand-file-name "fixtures/fennel" sk/fennel-check-source-root)))
  "First disposable Fennel fixture root.")

(defconst sk/fennel-check-second-project
  (file-name-as-directory
   (file-truename
    (or (getenv "SK_EMACS_FENNEL_SECOND_PROJECT")
        (error "SK_EMACS_FENNEL_SECOND_PROJECT is required"))))
  "Second disposable Fennel fixture root.")

(defconst sk/fennel-check-source-file
  (file-truename
   (expand-file-name "src/sk/fixture/main.fnl" sk/fennel-check-project))
  "First fixture source file.")

(defconst sk/fennel-check-second-source-file
  (file-truename
   (expand-file-name "src/sk/fixture/main.fnl"
                     sk/fennel-check-second-project))
  "Second fixture source file.")

(defconst sk/fennel-check-wrapper
  (file-truename
   (expand-file-name "scripts/fennel-project" sk/fennel-check-source-root))
  "Production wrapper in the copied candidate repository.")

(defconst sk/fennel-check-phase
  (or (getenv "SK_EMACS_FENNEL_PHASE") "success")
  "Checker phase, either success or deliberate-failure.")

(defconst sk/fennel-check-initial-processes (process-list)
  "Emacs processes that predate this checker.")

(defconst sk/fennel-check-initial-buffers (buffer-list)
  "Emacs buffers that predate this checker.")

(defconst sk/fennel-check-warning
  "--WARNING: plugin fennel-ls does not support Fennel version 1.6.1"
  "The one pinned fennel-ls compatibility warning accepted by this slice.")

(defun sk/fennel-check-assert (condition format-string &rest arguments)
  "Signal unless CONDITION holds, formatting ARGUMENTS with FORMAT-STRING."
  (unless condition
    (error "fennel-backend-check: %s"
           (apply #'format format-string arguments))))

(defun sk/fennel-check-wait-for (predicate description &optional timeout)
  "Wait for PREDICATE or fail with DESCRIPTION after TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 45)))
        value)
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (setq value (or value (funcall predicate)))
    (sk/fennel-check-assert value "timed out waiting for %s" description)
    value))

(defun sk/fennel-check-created-processes ()
  "Return Emacs processes created after this checker began."
  (cl-set-difference (process-list) sk/fennel-check-initial-processes
                     :test #'eq))

(defun sk/fennel-check-created-buffers ()
  "Return Emacs buffers created after this checker began."
  (cl-set-difference (buffer-list) sk/fennel-check-initial-buffers
                     :test #'eq))

(defun sk/fennel-check-delete-process (process)
  "Delete PROCESS without queries and wait briefly for its PID to disappear."
  (let ((pid (and (processp process) (process-id process)))
        (deadline (+ (float-time) 10)))
    (when (processp process)
      (ignore-errors (set-process-query-on-exit-flag process nil))
      (when (process-live-p process)
        (ignore-errors (delete-process process))))
    (while (and (integerp pid)
                (process-attributes pid)
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (or (not (integerp pid)) (null (process-attributes pid)))))

(defun sk/fennel-check-cleanup ()
  "Remove only processes and buffers created by this checker."
  (dolist (process (sk/fennel-check-created-processes))
    (ignore-errors (sk/fennel-check-delete-process process)))
  (dolist (buffer (sk/fennel-check-created-buffers))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (set-buffer-modified-p nil)
        (setq-local kill-buffer-query-functions nil))
      (ignore-errors (kill-buffer buffer)))))

(defun sk/fennel-check-workspace (buffer)
  "Return BUFFER's fennel-ls workspace, or nil."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (and (bound-and-true-p lsp-mode)
           (seq-find
            (lambda (workspace)
              (eq (lsp--workspace-server-id workspace) 'fennel-ls))
            (lsp-workspaces))))))

(defun sk/fennel-check-start-lsp (buffer root)
  "Start and return BUFFER's real fennel-ls workspace for ROOT."
  (with-current-buffer buffer
    (let ((default-directory root))
      (lsp)))
  (sk/fennel-check-wait-for
   (lambda ()
     (when-let ((workspace (sk/fennel-check-workspace buffer)))
       (and (eq (lsp--workspace-status workspace) 'initialized)
            workspace)))
   (format "initialized fennel-ls for %s" root) 90))

(defun sk/fennel-check-workspace-process (workspace)
  "Return WORKSPACE's live stdio process."
  (let ((process (lsp--workspace-proc workspace)))
    (and (processp process) (process-live-p process) process)))

(defun sk/fennel-check-diagnostics (buffer workspace)
  "Return current fennel-ls diagnostics for BUFFER in WORKSPACE."
  (with-current-buffer buffer
    (gethash (lsp--fix-path-casing buffer-file-name)
             (lsp--workspace-diagnostics workspace))))

(defun sk/fennel-check-diagnostic-message (diagnostic)
  "Return DIAGNOSTIC's message across pinned lsp-mode representations."
  (cond
   ((fboundp 'lsp:diagnostic-message)
    (lsp:diagnostic-message diagnostic))
   ((hash-table-p diagnostic)
    (gethash "message" diagnostic))
   ((listp diagnostic)
    (or (plist-get diagnostic :message)
        (alist-get 'message diagnostic)))
   (t nil)))

(defun sk/fennel-check-repl-eval (buffer source &optional error-callback)
  "Synchronously evaluate SOURCE through BUFFER's linked protocol REPL."
  (with-current-buffer buffer
    (fennel-proto-repl-send-message-sync
     :eval source error-callback #'ignore 10)))

(defun sk/fennel-check-descendant-pids (parent)
  "Return every current operating-system descendant of PARENT."
  (let ((known (list parent)) descendants changed)
    (while
        (progn
          (setq changed nil)
          (dolist (pid (list-system-processes))
            (unless (memq pid known)
              (let ((ppid (cdr (assq 'ppid (process-attributes pid)))))
                (when (memq ppid known)
                  (push pid known)
                  (push pid descendants)
                  (setq changed t)))))
          changed))
    (sort descendants #'<)))

(defun sk/fennel-check-record-descendants ()
  "Record live descendants for the outer shell's post-Emacs proof."
  (let* ((pids-file
          (or (getenv "SK_EMACS_FENNEL_DESCENDANT_PIDS")
              (error "SK_EMACS_FENNEL_DESCENDANT_PIDS is required")))
         (details-file
          (or (getenv "SK_EMACS_FENNEL_DESCENDANT_DETAILS")
              (error "SK_EMACS_FENNEL_DESCENDANT_DETAILS is required")))
         (pids (sk/fennel-check-descendant-pids (emacs-pid))))
    (sk/fennel-check-assert
     (>= (length pids) 3)
     "expected live Guix/Fennel descendants, found %S" pids)
    (with-temp-file pids-file
      (dolist (pid pids) (insert (number-to-string pid) "\n")))
    (with-temp-file details-file
      (dolist (pid pids)
        (let ((attributes (process-attributes pid)))
          (insert (format "pid=%s ppid=%s pgrp=%s comm=%S args=%S\n"
                          pid
                          (cdr (assq 'ppid attributes))
                          (cdr (assq 'pgrp attributes))
                          (cdr (assq 'comm attributes))
                          (cdr (assq 'args attributes)))))))
    pids))

(defun sk/fennel-check-xrefs (buffer workspace)
  "Exercise real definition and same-file references in BUFFER via WORKSPACE."
  (with-current-buffer buffer
    ;; The tracked dependency call must resolve into math.fnl.
    (goto-char (point-min))
    (search-forward "math.add")
    (backward-char 3)
    (let* ((backend (xref-find-backend))
           (identifier (xref-backend-identifier-at-point backend))
           (definitions (xref-backend-definitions backend identifier))
           (marker (and definitions
                        (xref-location-marker
                         (xref-item-location (car definitions))))))
      (sk/fennel-check-assert (eq backend 'xref-lsp)
                              "fennel-ls xref backend changed: %S" backend)
      (sk/fennel-check-assert
       (and marker
            (string-suffix-p
             "/src/sk/fixture/math.fnl"
             (buffer-file-name (marker-buffer marker))))
       "definition did not resolve to math.fnl: %S" definitions))

    ;; Add a same-file definition and use, then query references from the use.
    (let ((start (point-max)))
      (unwind-protect
          (progn
            (goto-char start)
            (insert "\n(local sk-connected-value 42)\n"
                    "(print sk-connected-value)\n")
            (sk/fennel-check-wait-for
             (lambda ()
               ;; A clean publish after didChange proves the server consumed
               ;; the appended, valid source before xref is queried.
               (null (sk/fennel-check-diagnostics buffer workspace)))
             "clean diagnostics for same-file reference fixture")
            (goto-char (point-max))
            (search-backward "sk-connected-value")
            (let* ((backend (xref-find-backend))
                   (identifier (xref-backend-identifier-at-point backend))
                   (references
                    (xref-backend-references backend identifier))
                   (same-file-positions
                    (delete-dups
                     (delq
                      nil
                      (mapcar
                       (lambda (item)
                         (let ((marker
                                (xref-location-marker
                                 (xref-item-location item))))
                           (and marker
                                (file-equal-p
                                 (buffer-file-name (marker-buffer marker))
                                 sk/fennel-check-source-file)
                                (marker-position marker))))
                       references)))))
              (sk/fennel-check-assert references
                                      "fennel-ls returned no references")
              (sk/fennel-check-assert
               (>= (length same-file-positions) 2)
               "fennel-ls did not return distinct definition/use positions: %S"
               references)))
        (delete-region start (point-max))
        (set-buffer-modified-p nil)))
    (princ "fennel-backend-check: LSP xref PASS\n")))

(defun sk/fennel-check-lsp-diagnostics (buffer workspace)
  "Exercise a real unknown-identifier diagnostic and recovery."
  (with-current-buffer buffer
    (let ((start (point-max)))
      (unwind-protect
          (progn
            (goto-char start)
            (insert "\n(print sk-fennel-connected-missing)\n")
            (let ((diagnostics
                   (sk/fennel-check-wait-for
                    (lambda ()
                      (let ((items
                             (sk/fennel-check-diagnostics buffer workspace)))
                        (and (seq-some
                              (lambda (diagnostic)
                                (string-match-p
                                 "unknown identifier"
                                 (or (sk/fennel-check-diagnostic-message
                                      diagnostic)
                                     "")))
                              items)
                             items)))
                    "fennel-ls unknown-identifier diagnostic" 60)))
              (sk/fennel-check-assert diagnostics
                                      "diagnostic publish was empty")))
        (delete-region start (point-max))
        (set-buffer-modified-p nil))
      (sk/fennel-check-wait-for
       (lambda () (null (sk/fennel-check-diagnostics buffer workspace)))
       "fennel-ls diagnostic recovery" 60))
    (princ "fennel-backend-check: LSP diagnostics/recovery PASS\n")))

(defun sk/fennel-check-docs (buffer)
  "Exercise real fennel-ls hover data and the shared docs command in BUFFER."
  (with-current-buffer buffer
    (goto-char (point-min))
    (search-forward "require")
    (backward-char 2)
    (let ((hover (lsp-request "textDocument/hover"
                              (lsp--text-document-position-params))))
      (sk/fennel-check-assert hover "fennel-ls returned no hover data"))
    ;; The user command must remain usable after the direct protocol proof.
    (save-window-excursion (sk/fennel-docs))
    (princ "fennel-backend-check: LSP docs PASS\n")))

(defun sk/fennel-check-protocol (buffer)
  "Exercise protocol evaluation, errors, command routing, and macro expansion."
  (let ((result (sk/fennel-check-repl-eval buffer "(+ 20 22)")))
    (sk/fennel-check-assert (equal result '("42"))
                            "protocol evaluation differed: %S" result))
  (let (failure)
    (sk/fennel-check-assert
     (null
      (sk/fennel-check-repl-eval
       buffer "(error :SK-FENNEL-SYNTHETIC)"
       (lambda (&rest data) (setq failure data))))
     "failing protocol evaluation unexpectedly returned values")
    (sk/fennel-check-assert
     (string-match-p "SK-FENNEL-SYNTHETIC" (format "%S" failure))
     "protocol error callback omitted the synthetic error: %S" failure))
  (sk/fennel-check-assert
   (equal (sk/fennel-check-repl-eval buffer "(+ 40 2)") '("42"))
   "protocol REPL did not recover after an error")

  ;; Give each public evaluation route its own observable side effect.  The
  ;; synchronous probes only observe those effects; they cannot make a no-op
  ;; public command pass accidentally.
  (with-current-buffer buffer
    (let ((start (point-max)))
      (unwind-protect
          (progn
            (goto-char start)
            (insert "\n(tset _G :sk-buffer-route 11)\n")
            (sk/fennel-eval-buffer)
            (sk/fennel-check-wait-for
             (lambda ()
               (equal (sk/fennel-check-repl-eval
                       buffer "(. _G :sk-buffer-route)")
                      '("11")))
             "public buffer evaluation side effect")
            (delete-region start (point-max))

            (goto-char start)
            (insert
             "\n(fn sk-connected-defun [] (tset _G :sk-defun-route 22))\n")
            (goto-char (1- (point-max)))
            (sk/fennel-eval-defun)
            (sk/fennel-check-wait-for
             (lambda ()
               (equal
                (sk/fennel-check-repl-eval
                 buffer
                 "(do (sk-connected-defun) (. _G :sk-defun-route))")
                '("22")))
             "public defun evaluation side effect")
            (delete-region start (point-max))

            (goto-char start)
            (insert "\n(tset _G :sk-last-route 33)\n")
            (sk/fennel-eval-last-sexp)
            (sk/fennel-check-wait-for
             (lambda ()
               (equal (sk/fennel-check-repl-eval
                       buffer "(. _G :sk-last-route)")
                      '("33")))
             "public last-sexp evaluation side effect"))
        (delete-region start (point-max))
        (set-buffer-modified-p nil))))

  (let ((expansion
         (sk/fennel-check-repl-eval
          buffer "(macrodebug (when true 42) true)")))
    (sk/fennel-check-assert
     (and (= (length expansion) 1)
          (string-match-p
           (regexp-quote "(if true (do 42))") (car expansion)))
     "real protocol macro expansion differed: %S" expansion))
  (with-current-buffer buffer
    (let ((start (point-max)) dispatched)
      (unwind-protect
          (progn
            (goto-char start)
            (insert "\n(when true 42)\n")
            ;; `fennel-proto-repl-macroexpand' expands the sexp *at* point;
            ;; leave point on the opening delimiter, not after the form.
            (goto-char (1+ start))
            ;; The pinned command intentionally ignores macrodebug's return
            ;; value and exposes the expansion only as a print operation.  The
            ;; synchronous request above proves the real result; this narrow
            ;; substitution proves the public command dispatches that same
            ;; protocol operation instead of a classic inferior Lisp path.
            (cl-letf (((symbol-function 'fennel-proto-repl-send-message)
                       (lambda (&rest arguments)
                         (setq dispatched arguments)
                         0)))
              (sk/fennel-macroexpand))
            (sk/fennel-check-assert
             (and (eq (car dispatched) :eval)
                  (string-match-p
                   (regexp-quote "(macrodebug (when true 42))")
                   (cadr dispatched)))
             "public macro command bypassed protocol dispatch: %S"
             dispatched))
        (delete-region start (point-max))
        (set-buffer-modified-p nil))))
  (princ "fennel-backend-check: protocol eval/error/macro PASS\n"))

(defun sk/fennel-check-format (buffer)
  "Exercise manifest-owned stdin formatting without saving BUFFER."
  (with-current-buffer buffer
    (let ((original (buffer-string)))
      (unwind-protect
          (progn
            (erase-buffer)
            (insert "(local answer      42)\n(print   answer)\n")
            (sk/fennel-format-buffer)
            (sk/fennel-check-assert
             (equal (buffer-string) "(local answer 42)\n(print answer)\n")
             "wrapper formatting differed: %S" (buffer-string)))
        (erase-buffer)
        (insert original)
        (set-buffer-modified-p nil))))
  (princ "fennel-backend-check: wrapper format PASS\n"))

(defun sk/fennel-check-project-gate (buffer repl-process lsp-process)
  "Run BUFFER's project check while REPL-PROCESS and LSP-PROCESS stay live."
  (let (compilation process)
    (with-current-buffer buffer
      (setq compilation (sk/fennel-project-check)))
    (setq compilation (or compilation compilation-last-buffer))
    (sk/fennel-check-assert (buffer-live-p compilation)
                            "project check created no compilation buffer")
    (setq process (get-buffer-process compilation))
    (when process
      (sk/fennel-check-wait-for
       (lambda () (not (process-live-p process)))
       "Fennel project check completion" 240)
      (sk/fennel-check-assert
       (= (process-exit-status process) 0)
       "project check exited %s: %s"
       (process-exit-status process)
       (with-current-buffer compilation (buffer-string))))
    (let ((lines
           (with-current-buffer compilation
             (split-string (buffer-string) "\n" t))))
      (dolist (line lines)
        (when (string-prefix-p "--WARNING:" line)
          (sk/fennel-check-assert
           (equal line sk/fennel-check-warning)
           "unexpected fennel-ls warning: %S" line)))
      (sk/fennel-check-assert
       (seq-some (lambda (line)
                   (string-match-p "fennel-project: check: PASS" line))
                 lines)
       "project check omitted its PASS marker: %S" lines))
    (sk/fennel-check-assert (process-live-p repl-process)
                            "project check stopped the REPL")
    (sk/fennel-check-assert (process-live-p lsp-process)
                            "project check stopped fennel-ls")
    (princ "fennel-backend-check: project check PASS\n")))

(let (source second-source repl second-repl repl-process second-repl-process
             workspace second-workspace lsp-process second-lsp-process canary)
  (unwind-protect
      (progn
        (sk/fennel-check-assert
         (file-equal-p sk/fennel-project-wrapper sk/fennel-check-wrapper)
         "initialized wrapper differs: %S" sk/fennel-project-wrapper)
        (sk/fennel-check-assert
         (file-in-directory-p sk/fennel-check-source-root
                              sk/fennel-check-sandbox-root)
         "candidate source escaped its sandbox")

        ;; Cold opening must remain a pure editing action in both roots.
        (let ((before (process-list)))
          (setq source (find-file-noselect sk/fennel-check-source-file)
                second-source
                (find-file-noselect sk/fennel-check-second-source-file))
          (dolist (entry `((,source . ,sk/fennel-check-project)
                           (,second-source . ,sk/fennel-check-second-project)))
            (with-current-buffer (car entry)
              (sk/fennel-check-assert (derived-mode-p 'fennel-mode)
                                      "tracked .fnl missed fennel-mode")
              (sk/fennel-check-assert
               (equal sk/fennel-project-root (cdr entry))
               "source root differed: %S != %S"
               sk/fennel-project-root (cdr entry))
              (sk/fennel-check-assert
               (not (bound-and-true-p fennel-proto-repl-minor-mode))
               "cold source enabled protocol interaction")
              (sk/fennel-check-assert (not (bound-and-true-p lsp-mode))
                                      "cold source enabled LSP")))
          (sk/fennel-check-assert
           (equal before (process-list))
           "cold Fennel editing created processes: %S"
           (cl-set-difference (process-list) before :test #'eq)))
        (sk/fennel-check-assert
         (not (equal (sk/fennel--repl-buffer-name sk/fennel-check-project)
                     (sk/fennel--repl-buffer-name
                      sk/fennel-check-second-project)))
         "two roots shared one protocol REPL name")
        (princ "fennel-backend-check: cold two-root edit PASS\n")

        ;; Start both independent protocol REPLs.
        (with-current-buffer source (sk/fennel-repl))
        (setq repl
              (sk/fennel-check-wait-for
               (lambda ()
                 (sk/fennel--live-repl-buffer sk/fennel-check-project))
               "first project protocol REPL" 120)
              repl-process (sk/fennel--server-process repl))
        (with-current-buffer second-source (sk/fennel-repl))
        (setq second-repl
              (sk/fennel-check-wait-for
               (lambda ()
                 (sk/fennel--live-repl-buffer
                  sk/fennel-check-second-project))
               "second project protocol REPL" 120)
              second-repl-process (sk/fennel--server-process second-repl))
        (sk/fennel-check-assert
         (and (not (eq repl second-repl))
              (not (eq repl-process second-repl-process)))
         "two roots shared a protocol REPL")
        (sk/fennel-check-assert
         (equal (process-command repl-process)
                (sk/fennel--command sk/fennel-check-project "repl"))
         "first REPL bypassed wrapper: %S" (process-command repl-process))
        (sk/fennel-check-assert
         (equal (process-command second-repl-process)
                (sk/fennel--command sk/fennel-check-second-project "repl"))
         "second REPL bypassed wrapper: %S"
         (process-command second-repl-process))
        (princ "fennel-backend-check: two-root protocol isolation PASS\n")

        ;; Start both independent fennel-ls stdio workspaces.
        (setq workspace
              (sk/fennel-check-start-lsp source sk/fennel-check-project)
              second-workspace
              (sk/fennel-check-start-lsp second-source
                                         sk/fennel-check-second-project)
              lsp-process (sk/fennel-check-workspace-process workspace)
              second-lsp-process
              (sk/fennel-check-workspace-process second-workspace))
        (sk/fennel-check-assert
         (and lsp-process second-lsp-process
              (not (eq workspace second-workspace))
              (not (eq lsp-process second-lsp-process)))
         "two roots shared an LSP workspace/process")
        (sk/fennel-check-assert
         (equal (process-command lsp-process)
                (sk/fennel--command sk/fennel-check-project "lsp"))
         "first LSP bypassed wrapper: %S" (process-command lsp-process))
        (sk/fennel-check-assert
         (equal (process-command second-lsp-process)
                (sk/fennel--command sk/fennel-check-second-project "lsp"))
         "second LSP bypassed wrapper: %S"
         (process-command second-lsp-process))
        (princ "fennel-backend-check: two-root LSP isolation PASS\n")

        ;; The deliberate phase is intentionally short but leaves every real
        ;; backend live at the signal point.  The unwind path below must scope
        ;; cleanup correctly, and the outer shell verifies every recorded PID.
        (when (equal sk/fennel-check-phase "deliberate-failure")
          (sk/fennel-check-record-descendants)
          (with-temp-file
              (or (getenv "SK_EMACS_FENNEL_FAILURE_MARKER")
                  (error "SK_EMACS_FENNEL_FAILURE_MARKER is required"))
            (insert "triggered\n"))
          (error "Deliberate connected Fennel failure"))

        (sk/fennel-check-protocol source)
        (sk/fennel-check-lsp-diagnostics source workspace)
        (sk/fennel-check-xrefs source workspace)
        (sk/fennel-check-docs source)
        (sk/fennel-check-format source)
        (sk/fennel-check-project-gate source repl-process lsp-process)

        ;; An unrelated process group and the second project's live backends
        ;; are canaries for project-only cleanup.
        (setq canary
              (make-process
               :name "sk-fennel-unrelated-process"
               :command (list (or (executable-find "sleep")
                                  (error "candidate sleep is unavailable"))
                              "120")
               :connection-type 'pipe :noquery t))
        (sk/fennel-check-record-descendants)
        (with-current-buffer source (sk/fennel-stop))
        (sk/fennel-check-assert (not (process-live-p repl-process))
                                "first REPL survived scoped stop")
        (sk/fennel-check-assert (not (process-live-p lsp-process))
                                "first LSP survived scoped stop")
        (sk/fennel-check-assert (process-live-p second-repl-process)
                                "first stop killed second project REPL")
        (sk/fennel-check-assert (process-live-p second-lsp-process)
                                "first stop killed second project LSP")
        (sk/fennel-check-assert (process-live-p canary)
                                "first stop killed unrelated process group")
        (with-current-buffer second-source (sk/fennel-stop))
        (sk/fennel-check-assert (not (process-live-p second-repl-process))
                                "second REPL survived scoped stop")
        (sk/fennel-check-assert (not (process-live-p second-lsp-process))
                                "second LSP survived scoped stop")
        (sk/fennel-check-assert (process-live-p canary)
                                "second stop killed unrelated process group")
        (sk/fennel-check-assert (sk/fennel-check-delete-process canary)
                                "unrelated process canary was not reaped")
        (princ "fennel-backend-check: scoped cleanup canaries PASS\n")
        (princ "fennel-backend-check: PASS\n"))
    ;; This path runs after both ordinary completion and the deliberate error.
    (dolist (buffer (list source second-source))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (let ((root sk/fennel-project-root))
            (when (and root
                       (or (sk/fennel--live-repl-buffer root)
                           (sk/fennel-check-workspace buffer)))
              (ignore-errors (sk/fennel-stop)))))))
    (sk/fennel-check-cleanup)))

;;; fennel-backend-check.el ends here
