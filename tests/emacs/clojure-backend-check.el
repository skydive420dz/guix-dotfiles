;;; clojure-backend-check.el --- Connected Clojure editor acceptance -*- lexical-binding: t; -*-

;;; Commentary:

;; Run only through scripts/emacs-clojure-check.  That wrapper provides a
;; disposable copied project, candidate Home Emacs, and the exact JVM manifest.

;;; Code:

(require 'cl-lib)
(require 'flycheck)
(require 'subr-x)
(require 'xref)

(defvar lsp-session-file)
(defvar lsp-server-install-dir)
(defvar lsp-clojure-workspace-cache-dir)
(defvar lsp-clojure-custom-server-command)
(defvar lsp-enable-suggest-server-download)
(defvar lsp-enable-file-watchers)
(defvar lsp-keep-workspace-alive)
(defvar lsp-log-io)
(defvar lsp-restart)
(defvar sk/clojure-guix-shell)
(defvar sk/clojure-project-wrapper)

(declare-function clojure-mode "clojure-mode")
(declare-function flycheck-buffer "flycheck")
(declare-function flycheck-clear "flycheck")
(declare-function flycheck-error-message "flycheck")
(declare-function flycheck-running-p "flycheck")
(declare-function lsp "lsp-mode")
(declare-function lsp-diagnostics "lsp-mode")
(declare-function lsp-request "lsp-mode")
(declare-function lsp-workspaces "lsp-mode")
(declare-function lsp-workspace-shutdown "lsp-mode")
(declare-function lsp--locations-to-xref-items "lsp-mode")
(declare-function lsp--make-reference-params "lsp-mode")
(declare-function lsp--text-document-position-params "lsp-mode")
(declare-function lsp--workspace-proc "lsp-mode")
(declare-function lsp--workspace-root "lsp-mode")
(declare-function lsp--workspace-status "lsp-mode")
(declare-function sk/clojure--repl-buffer-name "sk-clojure")
(declare-function sk/clojure--require-repl "sk-clojure")
(declare-function sk/clojure--send-string "sk-clojure")
(declare-function sk/clojure-reload-namespace "sk-clojure")
(declare-function sk/clojure-repl "sk-clojure")
(declare-function sk/clojure-stop "sk-clojure")
(declare-function sk/format-buffer "sk-format")
(declare-function sk/lisp-eval-last-sexp "sk-lisp")

(defconst sk/clojure-check-source-root
  (file-name-as-directory
   (file-truename
    (or (getenv "SK_EMACS_CLOJURE_SOURCE_ROOT")
        (error "SK_EMACS_CLOJURE_SOURCE_ROOT is required"))))
  "Copied repository root used by this checker.")

(defconst sk/clojure-check-sandbox-root
  (file-name-as-directory
   (file-truename
    (or (getenv "SK_EMACS_CLOJURE_SANDBOX_ROOT")
        (error "SK_EMACS_CLOJURE_SANDBOX_ROOT is required"))))
  "Disposable state root used by this checker.")

(defconst sk/clojure-check-project
  (file-name-as-directory
   (file-truename
    (expand-file-name "fixtures/clojure" sk/clojure-check-source-root)))
  "Copied Clojure fixture root.")

(defconst sk/clojure-check-wrapper
  (file-truename
   (expand-file-name "scripts/clojure-project"
                     sk/clojure-check-source-root))
  "Direct project wrapper from the copied repository.")

(defconst sk/clojure-check-shell
  (file-truename
   (expand-file-name "scripts/guix-lisp-shell"
                     sk/clojure-check-source-root))
  "Production Guix shell wrapper from the copied repository.")

(defconst sk/clojure-check-home-profile
  (file-name-as-directory
   (file-truename
    (or (getenv "SK_EMACS_CLOJURE_HOME_PROFILE")
        (error "SK_EMACS_CLOJURE_HOME_PROFILE is required"))))
  "Candidate Home profile whose editor tools must be exercised.")

(defconst sk/clojure-check-initial-processes (process-list)
  "Emacs processes that predate this checker.")

(defconst sk/clojure-check-initial-buffers (buffer-list)
  "Emacs buffers that predate this checker.")

(defun sk/clojure-check-assert (condition format-string &rest arguments)
  "Signal unless CONDITION holds, formatting ARGUMENTS with FORMAT-STRING."
  (unless condition
    (error "clojure-backend-check: %s"
           (apply #'format format-string arguments))))

(defun sk/clojure-check-wait-for (predicate description &optional timeout)
  "Wait for PREDICATE or fail with DESCRIPTION after TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 30))))
    (while (and (not (funcall predicate))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (sk/clojure-check-assert (funcall predicate)
                             "timed out waiting for %s" description)))

(defun sk/clojure-check-created-processes ()
  "Return Emacs process objects created by this checker."
  (cl-set-difference (process-list)
                     sk/clojure-check-initial-processes
                     :test #'eq))

(defun sk/clojure-check-created-buffers ()
  "Return Emacs buffers created by this checker."
  (cl-set-difference (buffer-list)
                     sk/clojure-check-initial-buffers
                     :test #'eq))

(defun sk/clojure-check-cleanup ()
  "Stop and remove only processes and buffers created by this checker."
  (dolist (process (sk/clojure-check-created-processes))
    (when (processp process)
      (ignore-errors (set-process-query-on-exit-flag process nil))
      (when (process-live-p process)
        (ignore-errors (delete-process process)))))
  (accept-process-output nil 0.05)
  (dolist (buffer (sk/clojure-check-created-buffers))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (set-buffer-modified-p nil)
        (setq-local kill-buffer-query-functions nil))
      (ignore-errors (kill-buffer buffer)))))

(defun sk/clojure-check-output (buffer start regexp description
                                       &optional timeout)
  "Wait in BUFFER after START for REGEXP identified by DESCRIPTION."
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
    (sk/clojure-check-assert
     found "%s matching %S; output was %S"
     description regexp
     (and (buffer-live-p buffer)
          (with-current-buffer buffer
            (buffer-substring-no-properties
             (min start (point-max)) (point-max))))))
  (with-current-buffer buffer
    (buffer-substring-no-properties (min start (point-max)) (point-max))))

(defun sk/clojure-check-send (source-buffer expression regexp description)
  "Send EXPRESSION from SOURCE-BUFFER and wait for REGEXP DESCRIPTION."
  (let* ((repl (with-current-buffer source-buffer
                 (sk/clojure--require-repl)))
         (start (with-current-buffer repl (point-max))))
    (with-current-buffer source-buffer
      (sk/clojure--send-string expression))
    (sk/clojure-check-output repl start regexp description 30)))

(defun sk/clojure-check-repl ()
  "Start and exercise the project-keyed Guix Clojure comint workflow."
  (let* ((source-file
          (expand-file-name "src/sk/fixture/core.clj"
                            sk/clojure-check-project))
         (source-buffer (find-file-noselect source-file))
         (root sk/clojure-check-project)
         repl process)
    (with-current-buffer source-buffer
      (clojure-mode)
      (setq-local default-directory root
                  sk/clojure-project-root root)
      (sk/clojure-repl)
      (setq repl (sk/clojure--require-repl)
            process (get-buffer-process repl)))
    (sk/clojure-check-assert (process-live-p process)
                             "Clojure REPL process is not live")
    (sk/clojure-check-assert
     (equal (process-get process 'sk/clojure-project-root) root)
     "Clojure REPL process lost its project root")
    (sk/clojure-check-assert
     (string= (buffer-name repl) (sk/clojure--repl-buffer-name root))
     "Clojure REPL buffer is not project-keyed: %s" (buffer-name repl))
    (sk/clojure-check-assert
     (equal (process-command process) (sk/clojure--command "repl"))
     "Clojure REPL did not use the production Guix command shape: %S"
     (process-command process))
    (sk/clojure-check-output repl (point-min) "user=>" "Clojure prompt" 30)

    ;; Switching from the same project must reuse its one live process.
    (with-current-buffer source-buffer
      (sk/clojure-repl)
      (sk/clojure-check-assert
       (eq process (get-buffer-process (sk/clojure--require-repl)))
       "second project REPL command created another process"))

    ;; Exercise the shared Lisp evaluation command, not merely raw comint.
    (let ((source-end (with-current-buffer source-buffer (point-max)))
          (output-start (with-current-buffer repl (point-max))))
      (unwind-protect
          (with-current-buffer source-buffer
            (goto-char (point-max))
            (insert "\n(+ 20 22)")
            (sk/lisp-eval-last-sexp))
        (with-current-buffer source-buffer
          (delete-region source-end (point-max))
          (set-buffer-modified-p nil)))
      (sk/clojure-check-output
       repl output-start "42[\r\n]"
       "Clojure evaluation result 42" 30))

    (sk/clojure-check-send
     source-buffer
     "(throw (ex-info \"SK-CLOJURE-SYNTHETIC\" {}))"
     "SK-CLOJURE-SYNTHETIC" "controlled Clojure exception")
    (sk/clojure-check-send
     source-buffer "(+ 20 22)" "42[\r\n]"
     "Clojure post-exception recovery")

    (let ((output-start (with-current-buffer repl (point-max))))
      (with-current-buffer source-buffer
        (sk/clojure-reload-namespace))
      (sk/clojure-check-output
       repl output-start "nil[\r\n]"
       "Clojure namespace reload" 30))
    (sk/clojure-check-send
     source-buffer "(sk.fixture.core/fixture-answer)"
     "42[\r\n]" "post-reload fixture evaluation")

    (princ "clojure-backend-check: comint/Java live PASS\n")
    (list :source source-buffer :repl repl :process process)))

(defun sk/clojure-check-formatter (source-buffer)
  "Exercise real Home cljfmt buffer replacement in SOURCE-BUFFER."
  (sk/clojure-check-assert
   (file-equal-p (executable-find "cljfmt")
                 (expand-file-name "bin/cljfmt"
                                   sk/clojure-check-home-profile))
   "cljfmt did not resolve from candidate Home: %S"
   (executable-find "cljfmt"))
  (with-current-buffer source-buffer
    (let ((original (buffer-substring-no-properties (point-min) (point-max))))
      (unwind-protect
          (progn
            (erase-buffer)
            (insert "(defn answer [](+ 40 2))\n")
            (sk/format-buffer)
            (sk/clojure-check-assert
             (equal (buffer-string) "(defn answer [] (+ 40 2))\n")
             "real cljfmt buffer output was %S" (buffer-string))
            (princ "clojure-backend-check: cljfmt buffer PASS\n"))
        (erase-buffer)
        (insert original)
        (set-buffer-modified-p nil)))))

(defun sk/clojure-check-flycheck (source-buffer)
  "Exercise the real Home clj-kondo Flycheck checker in SOURCE-BUFFER."
  (sk/clojure-check-assert
   (file-equal-p (executable-find "clj-kondo")
                 (expand-file-name "bin/clj-kondo"
                                   sk/clojure-check-home-profile))
   "clj-kondo did not resolve from candidate Home: %S"
   (executable-find "clj-kondo"))
  (with-current-buffer source-buffer
    (let ((original (buffer-substring-no-properties (point-min) (point-max)))
          (marker "sk-clojure-flycheck-missing"))
      (unwind-protect
          (progn
            (erase-buffer)
            (insert "(ns sk.fixture.core)\n\n(" marker ")\n")
            (setq-local flycheck-checker 'sk-clojure-clj-kondo)
            (flycheck-mode 1)
            (flycheck-buffer)
            (sk/clojure-check-wait-for
             (lambda ()
               (and (not (flycheck-running-p))
                    (memq flycheck-last-status-change
                          '(finished errored))))
             "real clj-kondo Flycheck completion" 45)
            (sk/clojure-check-assert
             (eq flycheck-last-status-change 'finished)
             "clj-kondo Flycheck ended in %S"
             flycheck-last-status-change)
            (sk/clojure-check-assert
             (cl-some
              (lambda (entry)
                (string-match-p
                 (regexp-quote marker)
                 (or (flycheck-error-message entry) "")))
              flycheck-current-errors)
             "real clj-kondo Flycheck omitted %s: %S"
             marker
             (mapcar #'flycheck-error-message flycheck-current-errors))
            (princ "clojure-backend-check: Flycheck/clj-kondo PASS\n"))
        (when (flycheck-running-p)
          (flycheck-stop))
        (flycheck-clear)
        (erase-buffer)
        (insert original)
        (set-buffer-modified-p nil)))))

(defun sk/clojure-check-descendant-pids (parent)
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

(defun sk/clojure-check-record-live-descendants ()
  "Record the live backend process tree for post-Emacs cleanup checks."
  (let* ((pids-file
          (or (getenv "SK_EMACS_CLOJURE_DESCENDANT_PIDS")
              (error "SK_EMACS_CLOJURE_DESCENDANT_PIDS is required")))
         (details-file
          (or (getenv "SK_EMACS_CLOJURE_DESCENDANT_DETAILS")
              (error "SK_EMACS_CLOJURE_DESCENDANT_DETAILS is required")))
         (pids (sk/clojure-check-descendant-pids (emacs-pid))))
    (sk/clojure-check-assert
     (>= (length pids) 2)
     "expected live Guix/JVM descendants, found %S" pids)
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

(defun sk/clojure-check-request-xrefs (method params description)
  "Request METHOD with PARAMS until xrefs exist, identified by DESCRIPTION."
  (let ((deadline (+ (float-time) 45))
        items last-error)
    (while (and (null items) (< (float-time) deadline))
      (condition-case error-data
          (setq items
                (lsp--locations-to-xref-items
                 (lsp-request method (funcall params))))
        (error (setq last-error error-data)))
      (unless items
        (accept-process-output nil 0.2)))
    (sk/clojure-check-assert
     items "%s returned no locations (last error %S)" description last-error)
    items))

(defun sk/clojure-check-xref-files (items)
  "Return the file groups represented by xref ITEMS."
  (mapcar (lambda (item)
            (xref-location-group (xref-item-location item)))
          items))

(defun sk/clojure-check-diagnostic-contains-p (marker)
  "Return non-nil when current workspace diagnostics contain MARKER."
  (let (found)
    (maphash
     (lambda (_path diagnostics)
       (when (cl-some
              (lambda (diagnostic)
                (string-match-p (regexp-quote marker)
                                (prin1-to-string diagnostic)))
              diagnostics)
         (setq found t)))
     (lsp-diagnostics t))
    found))

(defun sk/clojure-check-lsp (source-buffer repl-process)
  "Exercise clojure-lsp while REPL-PROCESS remains live."
  ;; The checker deliberately runs with -Q, so load the candidate package's
  ;; generated autoload table explicitly before lsp-mode invokes optional
  ;; lens, modeline, and breadcrumb helpers.  A normal Guix Home session loads
  ;; this table through site-start.
  (require 'lsp-mode-autoloads)
  (require 'lsp-mode)
  (require 'lsp-clojure)
  (let* ((root sk/clojure-check-project)
         (server-install-dir
          (expand-file-name "lsp-server-downloads/"
                            (getenv "XDG_CACHE_HOME")))
         (lsp-session-file
          (expand-file-name "lsp-session" (getenv "XDG_STATE_HOME")))
         (lsp-server-install-dir server-install-dir)
         (lsp-clojure-workspace-cache-dir
          (expand-file-name "clojure-workspace/"
                            (getenv "XDG_CACHE_HOME")))
         (lsp-enable-suggest-server-download nil)
         (lsp-enable-file-watchers nil)
         (lsp-keep-workspace-alive nil)
         (lsp-log-io nil)
         (external-cache
          (expand-file-name "clojure-lsp/" (getenv "XDG_CACHE_HOME")))
         (diagnostic-file
          (expand-file-name "src/sk/fixture/connected_negative.clj" root))
         workspace server-process diagnostic-buffer)
    (with-temp-file diagnostic-file
      (insert "(ns sk.fixture.connected-negative)\n\n"
              "(sk-clojure-missing-symbol)\n"))
    (unwind-protect
        (with-current-buffer source-buffer
          (setq-local default-directory root
                      sk/clojure-project-root root)
          (goto-char (point-min))
          (lsp)
          (sk/clojure-check-wait-for
           (lambda ()
             (and (car (lsp-workspaces))
                  (eq (lsp--workspace-status (car (lsp-workspaces)))
                      'initialized)))
           "initialized clojure-lsp workspace" 90)
          (setq workspace (car (lsp-workspaces))
                server-process (lsp--workspace-proc workspace))
          (sk/clojure-check-assert (process-live-p server-process)
                                   "clojure-lsp process is not live")
          (sk/clojure-check-assert
           (equal (process-command server-process)
                  (sk/clojure--command "lsp"))
           "lsp-mode did not launch the production Guix command shape: %S"
           (process-command server-process))
          (sk/clojure-check-assert
           (file-equal-p (lsp--workspace-root workspace) root)
           "clojure-lsp workspace root differs: %s"
           (lsp--workspace-root workspace))

          (goto-char (point-min))
          (search-forward "(fixture-add value value)")
          (search-backward "fixture-add")
          (let* ((definitions
                  (sk/clojure-check-request-xrefs
                   "textDocument/definition"
                   #'lsp--text-document-position-params
                   "Clojure definition request"))
                 (files (sk/clojure-check-xref-files definitions)))
            (sk/clojure-check-assert
             (cl-some (lambda (file)
                        (string-match-p "core\\.clj\\'" file))
                      files)
             "Clojure definition did not resolve to core.clj: %S" files))

          (let* ((references
                  (sk/clojure-check-request-xrefs
                   "textDocument/references"
                   (lambda () (lsp--make-reference-params nil nil))
                   "Clojure references request"))
                 (files (sk/clojure-check-xref-files references)))
            (sk/clojure-check-assert
             (cl-some (lambda (file)
                        (string-match-p
                         "core\\(?:_test\\)?\\.clj\\'" file))
                      files)
             "Clojure references did not resolve inside the fixture: %S"
             files))

          ;; Attach a real invalid source file from the disposable copy.  This
          ;; exercises publishDiagnostics without relying on batch-mode idle
          ;; timer scheduling for an unsaved synthetic edit.
          (setq diagnostic-buffer (find-file-noselect diagnostic-file))
          (with-current-buffer diagnostic-buffer
            (clojure-mode)
            (setq-local default-directory root
                        sk/clojure-project-root root)
            (lsp))
          (sk/clojure-check-wait-for
           (lambda ()
             (sk/clojure-check-diagnostic-contains-p
              "sk-clojure-missing-symbol"))
           "clojure-lsp unresolved-symbol diagnostic" 45)

          (sk/clojure-check-assert
           (process-live-p repl-process)
           "Clojure REPL stopped before the live failure checkpoint")
          (sk/clojure-check-record-live-descendants)
          (when (equal (getenv "SK_EMACS_CLOJURE_CHECK_BREAK") "1")
            (error
             "deliberate connected failure with REPL and clojure-lsp live")))
      (when workspace
        (ignore-errors (lsp-workspace-shutdown workspace)))
      (when server-process
        (sk/clojure-check-wait-for
         (lambda () (not (process-live-p server-process)))
         "clean clojure-lsp shutdown" 45)))

    (let ((downloaded
           (and (file-directory-p server-install-dir)
                (directory-files-recursively server-install-dir "." t))))
      (sk/clojure-check-assert
       (null downloaded)
       "lsp-mode downloaded a server despite the explicit command: %S"
       downloaded))
    (dolist (path (list (expand-file-name ".m2" (getenv "HOME"))
                        (expand-file-name ".clojure" (getenv "HOME"))))
      (sk/clojure-check-assert
       (not (file-exists-p path))
       "Maven/tools.deps state escaped into isolated HOME: %s" path))
    (sk/clojure-check-assert
     (and (file-directory-p external-cache)
          (file-in-directory-p (file-truename external-cache)
                               (file-truename (getenv "XDG_CACHE_HOME")))
          (not (file-in-directory-p (file-truename external-cache) root)))
     "clojure-lsp analysis state was not externalized under XDG cache: %s"
     external-cache)
    ;; clojure-lsp itself can create a small project-local index even when its
    ;; durable analysis and kondo state are redirected.  lsp-mode kills its
    ;; command transport immediately after the protocol shutdown, so promising
    ;; trap-based deletion here would be false.  Require these paths to remain
    ;; inside the disposable project and explicitly ignored instead.
    (let ((ignore-file (expand-file-name ".gitignore" root)))
      (sk/clojure-check-assert (file-readable-p ignore-file)
                               "copied project lacks .gitignore")
      (dolist (relative '(".lsp/.cache/" ".clj-kondo/.cache/" "target/"))
        (let ((path (expand-file-name relative root)))
          (when (file-exists-p path)
            (sk/clojure-check-assert
             (file-in-directory-p (file-truename path) root)
             "project-local cache escaped the disposable root: %s" path)
            (with-temp-buffer
              (insert-file-contents ignore-file)
              (sk/clojure-check-assert
               (re-search-forward
                (concat "^" (regexp-quote relative) "$") nil t)
               "generated project path is not ignored: %s" relative))))))
    (princ "clojure-backend-check: lsp-mode/clojure-lsp PASS\n")))

(let ((lsp-restart 'ignore)
      repl-state source-buffer repl-buffer repl-process)
  (unwind-protect
      (progn
        (sk/clojure-check-assert
         (file-equal-p sk/clojure-guix-shell sk/clojure-check-shell)
         "initialized Guix shell wrapper differs: %S"
         sk/clojure-guix-shell)
        (sk/clojure-check-assert
         (file-equal-p sk/clojure-project-wrapper sk/clojure-check-wrapper)
         "initialized Clojure project wrapper differs: %S"
         sk/clojure-project-wrapper)
        (sk/clojure-check-assert
         (equal lsp-clojure-custom-server-command
                (list sk/clojure-check-shell "jvm" "--"
                      sk/clojure-check-wrapper "lsp"))
         "configured clojure-lsp command shape changed: %S"
         lsp-clojure-custom-server-command)
        (setq repl-state (sk/clojure-check-repl)
              source-buffer (plist-get repl-state :source)
              repl-buffer (plist-get repl-state :repl)
              repl-process (plist-get repl-state :process))
        (sk/clojure-check-formatter source-buffer)
        (sk/clojure-check-flycheck source-buffer)
        (sk/clojure-check-lsp source-buffer repl-process)
        (with-current-buffer source-buffer
          (sk/clojure-stop))
        (sk/clojure-check-assert (not (process-live-p repl-process))
                                 "Clojure process survived graceful stop")
        (sk/clojure-check-assert (not (buffer-live-p repl-buffer))
                                 "Clojure REPL survived graceful stop")
        (let ((deadline (+ (float-time) 10)))
          (while (and (cl-some #'process-live-p
                               (sk/clojure-check-created-processes))
                      (< (float-time) deadline))
            (accept-process-output nil 0.05)))
        (sk/clojure-check-assert
         (not (cl-some #'process-live-p
                       (sk/clojure-check-created-processes)))
         "Clojure editor processes survived acceptance: %S"
         (mapcar (lambda (process)
                   (list (process-name process)
                         (process-status process)
                         (process-command process)))
                 (cl-remove-if-not
                  #'process-live-p (sk/clojure-check-created-processes))))
        (princ "clojure-backend-check: PASS\n"))
    (when (and source-buffer repl-process (process-live-p repl-process)
               (buffer-live-p source-buffer))
      (with-current-buffer source-buffer
        (ignore-errors (sk/clojure-stop))))
    (sk/clojure-check-cleanup)))

;;; clojure-backend-check.el ends here
