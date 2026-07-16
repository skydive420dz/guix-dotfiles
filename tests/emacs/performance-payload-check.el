;;; performance-payload-check.el --- Isolated P2.1 payload checks -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)

(defvar counsel--linux-apps-cache nil)
(defvar counsel--linux-apps-cached-files nil)
(defvar counsel--linux-apps-cache-timestamp nil)
(defvar counsel--linux-apps-cache-format-function nil)
(defvar counsel-linux-apps-faulty nil)
(defvar counsel-linux-apps-directories nil)
(defvar sk/exwm-launch-intents nil)
(defvar exwm--connection t)
(defvar exwm-wm-mode t)
(defvar server-process nil)
(defvar sk/user-directory nil)
(defvar sk/native-comp-profile-key nil)
(defvar sk/performance-test-cache-states nil)
(defvar sk/performance-test-discovery-calls 0)
(defvar sk/performance-test-list-calls 0)
(defvar sk/performance-test-launch-called nil)
(defvar sk/performance-test-inject-buffer nil)
(defconst sk/performance-test-side-effect-buffer
  " *sk-performance-launcher-side-effect*")

(defun sk/log--message-around (original format-string &rest arguments)
  (apply original format-string arguments))

(defun sk/exwm-launch-app ()
  (setq sk/performance-test-launch-called t)
  (error "launcher UI must not run in the measurement payload"))

(defun sk/performance-test-read-one (file)
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((form (read (current-buffer))))
      (condition-case nil
          (progn
            (read (current-buffer))
            (error "payload contains more than one form: %s" file))
        (end-of-file form)))))

(defun sk/performance-test-json (encoded)
  (json-parse-string encoded
                     :object-type 'alist
                     :array-type 'list
                     :null-object nil
                     :false-object :false))

(let* ((source-root
        (file-name-as-directory
         (file-truename
          (or (getenv "SK_EMACS_PERFORMANCE_SOURCE_ROOT")
              (error "SK_EMACS_PERFORMANCE_SOURCE_ROOT is required")))))
       (state-file
        (expand-file-name "scripts/emacs-performance-state.el" source-root))
       (launcher-file
        (expand-file-name "scripts/emacs-performance-launcher.el" source-root))
       (state-form (sk/performance-test-read-one state-file))
       (launcher-form (sk/performance-test-read-one launcher-file))
       ;; `load-history' is committed only after this fixture finishes loading.
       ;; Model the already-loaded live sk-exwm module explicitly so the state
       ;; payload exercises its real `symbol-file' provenance check.
       (fixture-sk-exwm-history
        (list (expand-file-name "emacs/lisp/sk-exwm.el" source-root)
              '(defun . sk/exwm-launch-app)))
       (server (make-pipe-process :name "sk-performance-server-fixture"
                                  :noquery t)))
  (unwind-protect
      (progn
        (push fixture-sk-exwm-history load-history)
        (provide 'exwm)
        (provide 'counsel)
        (setq server-process server
              sk/user-directory source-root
              user-init-file state-file
              sk/native-comp-profile-key
              (file-name-nondirectory
               (directory-file-name
                (file-truename "~/.guix-home/profile")))
              counsel--linux-apps-cache '(ambient-cache)
              counsel--linux-apps-cached-files '(ambient.desktop)
              counsel--linux-apps-cache-timestamp '(1 2 3 4)
              counsel--linux-apps-cache-format-function 'fixture-format
              counsel-linux-apps-faulty '(ambient-fault)
              counsel-linux-apps-directories '("/one" "/two" "/one")
              sk/exwm-launch-intents nil)
        (advice-add #'message :around #'sk/log--message-around)

        (let* ((state-json (eval state-form t))
               (state (sk/performance-test-json state-json)))
          (unless (equal (alist-get 'protocol state)
                         "sk-emacs-performance-state-v1")
            (error "state payload protocol is invalid: %S" state))
          (dolist (key '(pid source_root user_init_file sk_exwm_file
                        running_executable home_profile
                        counsel_cache_fingerprint))
            (unless (alist-get key state)
              (error "state payload omitted %s" key))))

        (let ((ambient-cache counsel--linux-apps-cache)
              (ambient-files counsel--linux-apps-cached-files)
              (ambient-timestamp counsel--linux-apps-cache-timestamp)
              (ambient-format counsel--linux-apps-cache-format-function)
              (ambient-faulty counsel-linux-apps-faulty)
              (messages-before
               (with-current-buffer (get-buffer-create "*Messages*")
                 (buffer-string)))
              (sk/performance-test-cache-states nil)
              (sk/performance-test-discovery-calls 0)
              (sk/performance-test-list-calls 0)
              (sk/performance-test-launch-called nil))
          (cl-letf (((symbol-function
                      'counsel-linux-apps-list-desktop-files)
                     (lambda ()
                       (cl-incf sk/performance-test-discovery-calls)
                       '(("one.desktop" . "/fixture/one.desktop")
                         ("two.desktop" . "/fixture/two.desktop"))))
                    ((symbol-function 'counsel-linux-apps-list)
                     (lambda ()
                       (cl-incf sk/performance-test-list-calls)
                       (message "suppressed P2.1 launcher fixture message")
                       (push (copy-tree counsel--linux-apps-cache)
                             sk/performance-test-cache-states)
                       (setq counsel--linux-apps-cache '(warmed-cache)
                             counsel--linux-apps-cached-files
                             '(one.desktop two.desktop)
                             counsel--linux-apps-cache-timestamp '(5 6 7 8))
                       '(("One" . "one.desktop")
                         ("Two" . "two.desktop"))))
                    ((symbol-function 'sk/exwm-supported-desktop-entry-p)
                     (lambda (_candidate _files)
                       (when sk/performance-test-inject-buffer
                         (get-buffer-create
                          sk/performance-test-side-effect-buffer))
                       t))
                    ((symbol-function 'ivy-read)
                     (lambda (&rest _arguments)
                       (error "launcher payload called Ivy")))
                    ((symbol-function 'start-process)
                     (lambda (&rest _arguments)
                       (error "launcher payload started a process")))
                    ((symbol-function 'make-process)
                     (lambda (&rest _arguments)
                       (error "launcher payload made a process")))
                    ((symbol-function 'call-process)
                     (lambda (&rest _arguments)
                       (error "launcher payload called a process")))
                    ((symbol-function 'sk/exwm-register-launch-intent)
                     (lambda (&rest _arguments)
                       (error "launcher payload registered an intent"))))
            (let* ((launcher-json (eval launcher-form t))
                   (launcher (sk/performance-test-json launcher-json))
                   (samples (alist-get 'samples launcher)))
              (unless (equal (alist-get 'protocol launcher)
                             "sk-emacs-performance-launcher-v1")
                (error "launcher payload protocol is invalid: %S" launcher))
              (unless (= (length samples) 5)
                (error "launcher payload returned %s samples" (length samples)))
              (unless (and (equal (alist-get 'initial_cache_populated launcher)
                                  "true")
                           (= (alist-get 'initial_cached_files_count launcher) 1))
                (error "launcher payload omitted initial cache identity"))
              (dolist (sample samples)
                (dolist (key '(buffer_delta frame_delta process_delta
                               intent_delta))
                  (unless (zerop (alist-get key sample))
                    (error "clean launcher sample changed %s: %S" key sample))))
              (unless (and (= sk/performance-test-discovery-calls 5)
                           (= sk/performance-test-list-calls 5))
                (error "launcher preparation did not run exactly five times"))
              (unless
                  (equal (nreverse sk/performance-test-cache-states)
                         '((ambient-cache) (warmed-cache) (warmed-cache)
                           (warmed-cache) (warmed-cache)))
                (error "launcher cache did not evolve natural-to-repeated: %S"
                       sk/performance-test-cache-states))
              (when sk/performance-test-launch-called
                (error "launcher UI ran during payload check")))
            (unless
                (equal messages-before
                       (with-current-buffer (get-buffer "*Messages*")
                         (buffer-string)))
              (error "launcher fixture message escaped suppression"))
            (let* ((sk/performance-test-inject-buffer t)
                   (side-effect-json (eval launcher-form t))
                   (side-effect (sk/performance-test-json side-effect-json))
                   (first (car (alist-get 'samples side-effect))))
              (unless (= (alist-get 'buffer_delta first) 1)
                (error "real payload did not report injected buffer side effect"))
              (kill-buffer sk/performance-test-side-effect-buffer)))
          (unless (and (equal counsel--linux-apps-cache ambient-cache)
                       (equal counsel--linux-apps-cached-files ambient-files)
                       (equal counsel--linux-apps-cache-timestamp
                              ambient-timestamp)
                       (equal counsel--linux-apps-cache-format-function
                              ambient-format)
                       (equal counsel-linux-apps-faulty ambient-faulty))
            (error "launcher payload did not restore ambient Counsel state")))

        (princ "emacs-performance-payload-check: PASS\n"))
    (setq load-history (delq fixture-sk-exwm-history load-history))
    (advice-remove #'message #'sk/log--message-around)
    (when (get-buffer sk/performance-test-side-effect-buffer)
      (kill-buffer sk/performance-test-side-effect-buffer))
    (when (process-live-p server)
      (delete-process server))))
