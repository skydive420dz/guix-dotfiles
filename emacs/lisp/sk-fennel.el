;;; sk-fennel.el --- Disposable project-scoped Fennel tooling -*- lexical-binding: t; -*-

;;; Commentary:

;; Home owns only Fennel Mode.  The interpreter, fnlfmt, and fennel-ls remain
;; inside the authenticated Fennel manifest and are entered through the tracked
;; project wrapper.  Opening a .fnl file is therefore process-free; the protocol
;; REPL and language server are separate explicit actions.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'sk-lisp)
(require 'sk-lsp)

(defvar company-backends)
(defvar fennel-mode-map)
(defvar fennel-program)
(defvar fennel-proto-repl--buffer)
(defvar fennel-proto-repl--process-buffer)
(defvar fennel-proto-repl-kill-process-buffers)
(defvar fennel-proto-repl-minor-mode)
(defvar fennel-proto-repl-minor-mode-map)
(defvar fennel-proto-repl-project-integration)
(defvar fennel-proto-repl-sync-timeout)
(defvar lsp-mode)
(defvar lsp-lens-enable)
(defvar sk/user-directory)

(declare-function fennel-proto-repl "fennel-proto-repl")
(declare-function fennel--xref-backend "fennel-mode")
(declare-function fennel-proto-repl--link-buffer "fennel-proto-repl")
(declare-function fennel-proto-repl--process-buffer "fennel-proto-repl")
(declare-function fennel-proto-repl-eval-buffer "fennel-proto-repl")
(declare-function fennel-proto-repl-eval-defun "fennel-proto-repl")
(declare-function fennel-proto-repl-eval-last-sexp "fennel-proto-repl")
(declare-function fennel-proto-repl-minor-mode "fennel-proto-repl")
(declare-function fennel-proto-repl-macroexpand "fennel-proto-repl")
(declare-function fennel-proto-repl-send-message "fennel-proto-repl")
(declare-function lsp--workspace-cmd-proc "lsp-mode")
(declare-function lsp--workspace-proc "lsp-mode")
(declare-function lsp--workspace-root "lsp-mode")
(declare-function lsp--workspace-server-id "lsp-mode")
(declare-function lsp-workspace-shutdown "lsp-mode")
(declare-function lsp-workspaces "lsp-mode")
(declare-function lsp-fennel--ls-command "lsp-fennel")
(declare-function sk/code-definition "sk-lsp")
(declare-function sk/code-docs "sk-lsp")
(declare-function sk/code-references "sk-lsp")
(declare-function sk/format--external "sk-format")

(defconst sk/fennel-repository-directory
  (file-name-as-directory
   (file-truename (expand-file-name ".." sk/user-directory)))
  "Absolute root of the checkout that owns the Fennel wrapper.")

(defconst sk/fennel-project-wrapper
  (expand-file-name "scripts/fennel-project"
                    sk/fennel-repository-directory)
  "Absolute project-aware wrapper for every Fennel tool action.")

(defconst sk/fennel-stop-timeout 10.0
  "Seconds allowed for each bounded Fennel shutdown phase.")

(defvar-local sk/fennel-project-root nil
  "Canonical project root associated with this Fennel buffer.")

(defun sk/fennel--canonical-root (&optional required)
  "Return this buffer's canonical Fennel root, or signal when REQUIRED."
  (or sk/fennel-project-root
      (sk/lisp--project-root required)))

(defun sk/fennel--command (root action &rest arguments)
  "Return the Fennel wrapper command for ROOT, ACTION, and ARGUMENTS."
  (let ((root (file-name-as-directory (file-truename root))))
    (append (list sk/fennel-project-wrapper "--project" root action)
            arguments)))

(defun sk/fennel--command-string (root action &rest arguments)
  "Return a safely quoted command string for ROOT, ACTION, and ARGUMENTS."
  (mapconcat #'shell-quote-argument
             (apply #'sk/fennel--command root action arguments)
             " "))

(defun sk/fennel--repl-buffer-name (root)
  "Return the deterministic protocol REPL buffer name for ROOT."
  (format "*Fennel REPL <%s>*" (sk/lisp--project-key root)))

(defun sk/fennel--server-process (repl-buffer)
  "Return REPL-BUFFER's live manifest-owned server process, or nil."
  (when (buffer-live-p repl-buffer)
    (with-current-buffer repl-buffer
      (when-let* ((process-buffer
                   (and (boundp 'fennel-proto-repl--process-buffer)
                        fennel-proto-repl--process-buffer))
                  (process-buffer (get-buffer process-buffer))
                  (process (get-buffer-process process-buffer)))
        (and (process-live-p process) process)))))

(defun sk/fennel--live-repl-buffer (&optional root)
  "Return ROOT's live, correctly tagged protocol REPL buffer, or nil."
  (let* ((root (or root (sk/fennel--canonical-root)))
         (buffer (and root (get-buffer (sk/fennel--repl-buffer-name root))))
         (process (and buffer (sk/fennel--server-process buffer))))
    (and buffer
         process
         (with-current-buffer buffer
           (and (derived-mode-p 'fennel-proto-repl-mode)
                (equal root sk/fennel-project-root)
                (equal root
                       (process-get process 'sk/fennel-project-root))
                buffer)))))

(defun sk/fennel--assert-wrapper ()
  "Require the tracked Fennel wrapper to be executable."
  (unless (file-executable-p sk/fennel-project-wrapper)
    (user-error "Fennel project wrapper is not executable: %s"
                sk/fennel-project-wrapper)))

(defun sk/fennel--require-edit-buffer ()
  "Require a Fennel source buffer in a marked project and return its root."
  (unless (derived-mode-p 'fennel-mode)
    (user-error "Fennel command requires a Fennel source buffer"))
  (sk/fennel--canonical-root t))

(defun sk/fennel--link-buffer (buffer repl root)
  "Link Fennel source BUFFER to project REPL at ROOT without starting one."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (unless (derived-mode-p 'fennel-mode)
        (user-error "A project Fennel REPL can link only Fennel source buffers"))
      (setq-local sk/fennel-project-root root
                  fennel-program
                  (sk/fennel--command-string root "repl")
                  inferior-lisp-program fennel-program
                  fennel-proto-repl--buffer repl)
      (fennel-proto-repl--link-buffer repl)
      (fennel-proto-repl-minor-mode 1))))

(defun sk/fennel--require-repl ()
  "Return and link the current project's live protocol REPL, or signal."
  (let* ((root (sk/fennel--canonical-root t))
         (repl (sk/fennel--live-repl-buffer root)))
    (unless repl
      (user-error "No project Fennel REPL is active; run SPC l r first"))
    (unless (eq (current-buffer) repl)
      (sk/fennel--link-buffer (current-buffer) repl root))
    repl))

(defun sk/fennel-mode-setup ()
  "Configure Fennel editing without starting a runtime or language server."
  (eldoc-mode 1)
  (when (fboundp 'company-mode)
    (company-mode 1)
    (setq-local company-backends
                '((company-capf company-yasnippet)
                  company-files
                  company-keywords
                  company-dabbrev-code)))
  ;; The package's static xref backend queries a classic global inferior Lisp
  ;; process.  Keep it disabled; the explicit protocol REPL and fennel-ls own
  ;; navigation after their respective boundaries are crossed.
  (remove-hook 'xref-backend-functions #'fennel--xref-backend t)
  ;; The pinned Fennel server advertises code lenses, but the Guix lsp-mode
  ;; autoload boundary does not load `lsp-lens--enable' in isolated -Q runs.
  ;; Lenses are outside this slice; disable only this buffer's optional hook.
  (setq-local lsp-lens-enable nil)
  (when-let ((root (sk/lisp--project-root)))
    (setq-local sk/fennel-project-root root
                fennel-program (sk/fennel--command-string root "repl")
                inferior-lisp-program fennel-program)))

;; This fallback still crosses the tracked wrapper if an upstream command is
;; invoked outside a marked source buffer.  Project buffers replace "." with
;; their canonical root, and the reviewed keymap below replaces every classic
;; REPL/evaluation entry point with guarded project commands.
(setq fennel-program
      (sk/fennel--command-string
       (file-name-as-directory sk/fennel-repository-directory) "repl"))

(use-package fennel-mode
  :if (locate-library "fennel-mode")
  :demand t
  :hook (fennel-mode . sk/fennel-mode-setup)
  :config
  (require 'fennel-proto-repl)
  (setq fennel-proto-repl-project-integration nil
        fennel-proto-repl-kill-process-buffers t
        fennel-proto-repl-sync-timeout 2.0)
  ;; Do not leave the package's global classic REPL or bare fnlfmt paths on
  ;; reachable default keys.
  (dolist (binding `(("C-c C-z" . ,#'sk/fennel-repl)
                     ("C-c C-b" . ,#'sk/fennel-eval-buffer)
                     ("C-c C-e" . ,#'sk/fennel-eval-defun)
                     ("C-M-x" . ,#'sk/fennel-eval-defun)
                     ("C-x C-e" . ,#'sk/fennel-eval-last-sexp)
                     ("C-c C-p" . ,#'sk/fennel-macroexpand)
                     ("C-c C-t" . ,#'sk/fennel-format-buffer)
                     ("C-c C-l" . ,#'sk/fennel-project-check)
                     ("C-c C-f" . ,#'sk/fennel-docs)
                     ("C-c C-d" . ,#'sk/fennel-docs)
                     ("C-c C-v" . ,#'sk/fennel-docs)
                     ("C-c C-q" . ,#'sk/fennel-stop)))
    (define-key fennel-mode-map (kbd (car binding)) (cdr binding)))
  ;; These upstream major-mode bindings target the classic global inferior
  ;; process and have no project-scoped equivalent in this configuration.
  (dolist (key '("C-c C-k" "C-c C-n" "C-c C-r"))
    (define-key fennel-mode-map (kbd key) nil))
  (dolist (binding `(("C-c C-z" . ,#'sk/fennel-repl)
                     ("C-c C-b" . ,#'sk/fennel-eval-buffer)
                     ("C-c C-e" . ,#'sk/fennel-eval-defun)
                     ("C-M-x" . ,#'sk/fennel-eval-defun)
                     ("C-x C-e" . ,#'sk/fennel-eval-last-sexp)
                     ("C-c C-p" . ,#'sk/fennel-macroexpand)
                     ("C-c C-t" . ,#'sk/fennel-format-buffer)
                     ("C-c C-l" . ,#'sk/fennel-project-check)
                     ("C-c C-f" . ,#'sk/fennel-docs)
                     ("C-c C-d" . ,#'sk/fennel-docs)
                     ("C-c C-v" . ,#'sk/fennel-docs)
                     ("C-c C-a" . ,#'sk/fennel-docs)
                     ("C-c C-q" . ,#'sk/fennel-stop)))
    (define-key fennel-proto-repl-minor-mode-map
                (kbd (car binding)) (cdr binding)))
  ;; Do not let the higher-priority protocol minor map restore bare fnlfmt,
  ;; arbitrary cross-project linking, or unreviewed evaluation/reload routes.
  (dolist (key '("C-c C-k" "C-c C-n" "C-c C-S-p" "C-c C-r"
                 "C-c C-S-l"))
    (define-key fennel-proto-repl-minor-mode-map (kbd key) nil))
  ;; The protocol REPL's own quit command stops only its server process and can
  ;; leave the sibling fennel-ls workspace behind.  Route its visible lifecycle
  ;; keys through the same project-scoped contract as source buffers.
  (define-key fennel-proto-repl-mode-map (kbd "C-c C-z") #'sk/fennel-repl)
  (define-key fennel-proto-repl-mode-map (kbd "C-c C-q") #'sk/fennel-stop))

(defun sk/fennel-repl ()
  "Start or switch to this project's manifest-owned protocol REPL."
  (interactive)
  (unless (derived-mode-p 'fennel-mode 'fennel-proto-repl-mode)
    (user-error "Start or visit a Fennel REPL from a Fennel buffer"))
  (let* ((root (sk/fennel--canonical-root t))
         (source (current-buffer))
         (existing (sk/fennel--live-repl-buffer root)))
    (sk/fennel--assert-wrapper)
    (if existing
        (progn
          (unless (eq source existing)
            (sk/fennel--link-buffer source existing root))
          (pop-to-buffer existing))
      (unless (derived-mode-p 'fennel-mode)
        (user-error "Start a Fennel REPL from a Fennel source buffer"))
      (let* ((default-directory root)
             (command (sk/fennel--command-string root "repl"))
             (requested (get-buffer-create
                         (sk/fennel--repl-buffer-name root)))
             (repl
              (with-current-buffer source
                (setq-local sk/fennel-project-root root
                            fennel-program command)
                (fennel-proto-repl command requested))))
        ;; Upstream uses a PID-based initialization name.  Restore the stable
        ;; project key only after the protocol handshake has completed.
        (with-current-buffer repl
          (rename-buffer (sk/fennel--repl-buffer-name root) t)
          (setq default-directory root)
          (setq-local sk/fennel-project-root root
                      fennel-program command)
          (let ((process (sk/fennel--server-process repl)))
            (unless process
              (error "Fennel protocol REPL initialized without a server"))
            (process-put process 'sk/fennel-project-root root)))
        (sk/fennel--link-buffer source repl root)
        (pop-to-buffer repl)))))

(defun sk/fennel-eval-buffer ()
  "Evaluate the current Fennel buffer in its explicit protocol REPL."
  (interactive)
  (sk/fennel--require-edit-buffer)
  (sk/fennel--require-repl)
  (fennel-proto-repl-eval-buffer))

(defun sk/fennel-eval-defun ()
  "Evaluate the current Fennel top-level form in the protocol REPL."
  (interactive)
  (sk/fennel--require-edit-buffer)
  (sk/fennel--require-repl)
  (fennel-proto-repl-eval-defun))

(defun sk/fennel-eval-last-sexp ()
  "Evaluate the Fennel expression before point in the protocol REPL."
  (interactive)
  (sk/fennel--require-edit-buffer)
  (sk/fennel--require-repl)
  (fennel-proto-repl-eval-last-sexp))

(defun sk/fennel-macroexpand ()
  "Macroexpand the Fennel expression at point in the protocol REPL."
  (interactive)
  (sk/fennel--require-edit-buffer)
  (sk/fennel--require-repl)
  (fennel-proto-repl-macroexpand))

(defun sk/fennel--lsp-command ()
  "Return the current project's manifest-owned fennel-ls command."
  (sk/fennel--command (sk/fennel--canonical-root t) "lsp"))

(with-eval-after-load 'lsp-fennel
  ;; lsp-mode's pinned client otherwise calls `executable-find' and would
  ;; bypass the authenticated manifest if a mutable fennel-ls appeared on PATH.
  (unless (advice-member-p #'sk/fennel--lsp-command
                           #'lsp-fennel--ls-command)
    (advice-add #'lsp-fennel--ls-command :override
                #'sk/fennel--lsp-command)))

(defun sk/fennel--require-lsp (operation)
  "Require this buffer's active fennel-ls workspace for OPERATION."
  (unless (and (bound-and-true-p lsp-mode)
               (fboundp 'lsp-workspaces)
               (seq-some
                (lambda (workspace)
                  (eq (lsp--workspace-server-id workspace) 'fennel-ls))
                (lsp-workspaces)))
    (user-error
     "Fennel %s requires fennel-ls; start it with SPC c l" operation)))

(defun sk/fennel-docs ()
  "Show Fennel documentation through the active fennel-ls workspace."
  (interactive)
  (sk/fennel--require-lsp "documentation")
  (sk/code-docs))

(defun sk/fennel-definition ()
  "Visit a Fennel definition through the active fennel-ls workspace."
  (interactive)
  (sk/fennel--require-lsp "definition lookup")
  (sk/code-definition))

(defun sk/fennel-references ()
  "Show same-file Fennel references through active fennel-ls."
  (interactive)
  (sk/fennel--require-lsp "reference lookup")
  (sk/code-references))

(defun sk/fennel-format-buffer ()
  "Format this buffer with manifest-owned fnlfmt through the project wrapper."
  (interactive)
  (let ((root (sk/fennel--require-edit-buffer)))
    (sk/fennel--assert-wrapper)
    (let ((default-directory root))
      (sk/format--external sk/fennel-project-wrapper
                           "--project" root "format" "-"))))

(defun sk/fennel-project-check ()
  "Run this Fennel project's manifest-owned, Makefile-defined check gate."
  (interactive)
  (let* ((root (sk/fennel--require-edit-buffer))
         (default-directory root)
         (command (sk/fennel--command-string root "check"))
         (compilation-buffer-name-function
          (lambda (_mode)
            (format "*fennel-check-%s*" (sk/lisp--project-key root)))))
    (sk/fennel--assert-wrapper)
    (compile command)))

(defun sk/fennel-debug ()
  "Report the deliberately unsupported Fennel debugger contract."
  (interactive)
  (user-error "Fennel debugging is unsupported in the Guix-only workflow"))

(defun sk/fennel--project-buffers (root)
  "Return Fennel buffers tagged for ROOT."
  (seq-filter
   (lambda (buffer)
     (and (buffer-live-p buffer)
          (with-current-buffer buffer
            (and (derived-mode-p 'fennel-mode 'fennel-proto-repl-mode)
                 (equal sk/fennel-project-root root)))))
   (buffer-list)))

(defun sk/fennel--project-workspaces (root)
  "Return unique fennel-ls workspaces associated with ROOT's buffers."
  (let (workspaces)
    (when (fboundp 'lsp-workspaces)
      (dolist (buffer (sk/fennel--project-buffers root))
        (with-current-buffer buffer
          (when (bound-and-true-p lsp-mode)
            (dolist (workspace (lsp-workspaces))
              (when (and (eq (lsp--workspace-server-id workspace)
                             'fennel-ls)
                         (file-equal-p
                          (file-name-as-directory
                           (file-truename (lsp--workspace-root workspace)))
                          root))
                (cl-pushnew workspace workspaces :test #'eq)))))))
    workspaces))

(defun sk/fennel--wait-for (predicate timeout)
  "Wait at most TIMEOUT seconds for PREDICATE, returning its value."
  (let ((deadline (+ (float-time) timeout))
        value)
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (or value (funcall predicate))))

(defun sk/fennel--process-group-members (process-group)
  "Return operating-system processes still in PROCESS-GROUP."
  (seq-filter
   (lambda (pid)
     (equal process-group
            (cdr (assq 'pgrp (process-attributes pid)))))
   (list-system-processes)))

(defun sk/fennel--terminate-process-group (process)
  "Boundedly terminate PROCESS and its validated process group."
  (let* ((pid (and (processp process) (process-id process)))
         (attributes (and (integerp pid) (process-attributes pid)))
         (process-group (cdr (assq 'pgrp attributes))))
    (when (process-live-p process)
      (if (and (integerp pid) (> pid 1) (equal process-group pid))
          (progn
            (ignore-errors (signal-process (- pid) 15))
            (unless (sk/fennel--wait-for
                     (lambda ()
                       (null (sk/fennel--process-group-members pid)))
                     sk/fennel-stop-timeout)
              (ignore-errors (signal-process (- pid) 9))
              (sk/fennel--wait-for
               (lambda ()
                 (null (sk/fennel--process-group-members pid)))
               sk/fennel-stop-timeout)))
        (set-process-query-on-exit-flag process nil)
        (delete-process process)))
    (or (not (process-live-p process))
        (sk/fennel--wait-for
         (lambda () (not (process-live-p process))) 1.0))))

(defun sk/fennel--stop-workspace (workspace)
  "Gracefully stop one fennel-ls WORKSPACE with a bounded group fallback."
  (let ((process (or (lsp--workspace-cmd-proc workspace)
                     (lsp--workspace-proc workspace))))
    (ignore-errors (lsp-workspace-shutdown workspace))
    (unless (or (not (processp process))
                (sk/fennel--wait-for
                 (lambda () (not (process-live-p process)))
                 sk/fennel-stop-timeout))
      (sk/fennel--terminate-process-group process))
    (or (not (processp process)) (not (process-live-p process)))))

(defun sk/fennel--stop-repl (repl)
  "Gracefully stop and remove project REPL, returning non-nil when drained."
  (let* ((process (and (buffer-live-p repl)
                       (sk/fennel--server-process repl)))
         (process-buffer (and (processp process) (process-buffer process))))
    (when (and (buffer-live-p repl)
               (processp process)
               (process-live-p process))
      (with-current-buffer repl
        (ignore-errors
          (fennel-proto-repl-send-message :exit "" #'ignore)))
      (unless (sk/fennel--wait-for
               (lambda () (not (process-live-p process))) 1.0)
        (sk/fennel--terminate-process-group process)))
    (when (and (processp process) (process-live-p process))
      (set-process-query-on-exit-flag process nil)
      (delete-process process))
    (when (buffer-live-p repl)
      (with-current-buffer repl
        (set-buffer-modified-p nil)
        (setq-local kill-buffer-query-functions nil))
      (kill-buffer repl))
    (when (buffer-live-p process-buffer)
      (kill-buffer process-buffer))
    (or (not (processp process)) (not (process-live-p process)))))

(defun sk/fennel-stop ()
  "Stop only this project's Fennel REPL and fennel-ls workspace."
  (interactive)
  (let* ((root (sk/fennel--canonical-root t))
         (repl (get-buffer (sk/fennel--repl-buffer-name root)))
         (workspaces (sk/fennel--project-workspaces root)))
    (unless (or repl workspaces)
      (user-error "No Fennel backend is active for %s" root))
    (unless (seq-every-p #'sk/fennel--stop-workspace workspaces)
      (user-error "Fennel language-server shutdown exceeded its timeout"))
    (unless (or (not repl) (sk/fennel--stop-repl repl))
      (user-error "Fennel REPL shutdown exceeded its timeout"))
    (dolist (buffer (sk/fennel--project-buffers root))
      (with-current-buffer buffer
        (when (bound-and-true-p fennel-proto-repl-minor-mode)
          (fennel-proto-repl-minor-mode -1))
        (setq-local fennel-proto-repl--buffer nil)))
    (message "Stopped Fennel backends for %s"
             (file-name-nondirectory (directory-file-name root)))))

(provide 'sk-fennel)

;;; sk-fennel.el ends here
