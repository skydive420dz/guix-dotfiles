;;; early-init.el --- Profile-scoped native compilation cache -*- lexical-binding: t; -*-

;; Native-compiled Lisp is tied to the Emacs and package profile that produced
;; it.  Keep each Guix Home profile in its own XDG cache instead of allowing an
;; older ~/.emacs.d/eln-cache to shadow the current profile's Lisp sources.

;; P2.2's startup observer is opt-in and one-shot.  Ordinary sessions take only
;; this exact string comparison; they do not load the observer or install any
;; hook/advice.  An attributed session retains its trace in memory for a later
;; read-only client extraction.
(when (equal (getenv "SK_EMACS_STARTUP_TRACE") "p2.2-v1")
  (let* ((observer-started (current-time))
         (gc-count-start gcs-done)
         (gc-elapsed-start gc-elapsed)
         ;; The live entrypoint is a ~/.emacs.d symlink into this repository.
         ;; Resolve that link before locating the adjacent lisp directory;
         ;; user-emacs-directory deliberately remains ~/.emacs.d here.
         (early-init-source
          (file-truename
           (or load-file-name buffer-file-name
               (locate-user-emacs-file "early-init.el"))))
         (early-init-source-directory
          (file-name-directory early-init-source)))
    (load (expand-file-name "lisp/sk-startup-trace.el"
                            early-init-source-directory)
          nil t)
    (sk/startup-trace-bootstrap observer-started
                                gc-count-start gc-elapsed-start)))

(defun sk/native-comp--profile-key (&optional profile)
  "Return PROFILE's resolved basename, or nil when it is unavailable.
PROFILE defaults to the current Guix Home package profile."
  (let ((profile (or profile
                     (expand-file-name "~/.guix-home/profile"))))
    (condition-case nil
        (when (file-exists-p profile)
          (file-name-nondirectory
           (directory-file-name (file-truename profile))))
      (file-error nil))))

(defun sk/native-comp--running-emacs-key ()
  "Return a collision-resistant cache key for the running Emacs."
  (let* ((executable
          (expand-file-name (or invocation-name "emacs")
                            (or invocation-directory default-directory)))
         (resolved-executable
          (condition-case nil
              (file-truename executable)
            (file-error executable)))
         (identity
          (mapconcat #'identity
                     (list emacs-version system-configuration
                           resolved-executable)
                     "\0"))
         (version
          (replace-regexp-in-string "[^[:alnum:]._-]" "_" emacs-version)))
    (format "emacs-%s-%s" version (secure-hash 'sha256 identity))))

(defun sk/native-comp--cache-key (&optional profile)
  "Return PROFILE's key or the running-Emacs fallback.
PROFILE defaults to the current Guix Home package profile."
  (or (sk/native-comp--profile-key profile)
      (sk/native-comp--running-emacs-key)))

(defconst sk/native-comp-profile-key
  (sk/native-comp--cache-key)
  "Cache identity for the current Guix Home profile or running Emacs.")

(defconst sk/native-comp-cache-directory
  (let ((xdg-cache-home (getenv "XDG_CACHE_HOME")))
    (file-name-as-directory
     (expand-file-name
      sk/native-comp-profile-key
      (expand-file-name
       "emacs/eln-cache/"
       (if (and xdg-cache-home
                (file-name-absolute-p xdg-cache-home))
           xdg-cache-home
         "~/.cache/")))))
  "Profile-scoped directory for user native-comp artifacts.")

(defconst sk/native-comp-legacy-cache-directory
  (file-name-as-directory
   (expand-file-name "eln-cache" user-emacs-directory))
  "Legacy native-comp directory that must never remain a fallback.")

(when (and (fboundp 'startup-redirect-eln-cache)
           (boundp 'native-comp-eln-load-path))
  (make-directory sk/native-comp-cache-directory t)
  (startup-redirect-eln-cache sk/native-comp-cache-directory)
  ;; `startup-redirect-eln-cache' puts the selected cache first.  Delete any
  ;; legacy fallback explicitly while retaining every Guix-provided
  ;; native-site-lisp entry and its ordering.
  (setq native-comp-eln-load-path
        (delete sk/native-comp-legacy-cache-directory
                native-comp-eln-load-path)))

(when (fboundp 'sk/startup-trace-mark)
  (sk/startup-trace-mark "early-init-exit"))

;;; early-init.el ends here
