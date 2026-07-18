;;; early-init.el --- First-frame and profile startup policy -*- lexical-binding: t; -*-

;; Establish creation-time visual state before Emacs constructs its first X
;; frame.  GUI-dependent mode calls remain in sk-ui after graphical startup.
;; Native-compiled Lisp is tied to the Emacs and package profile that produced
;; it, so each Guix Home profile also receives its own XDG cache.

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

(setq inhibit-startup-message t
      inhibit-startup-screen t)

(defconst sk/early-frame-parameters
  '((menu-bar-lines . 0)
    (tool-bar-lines . 0)
    (vertical-scroll-bars . nil)
    (horizontal-scroll-bars . nil)
    (left-fringe . 10)
    (right-fringe . 10)
    (fullscreen . fullboth)
    (undecorated . t))
  "Creation-time parameters for the initial and later EXWM frames.")

(dolist (parameter sk/early-frame-parameters)
  ;; Delete prior values so each creation-time property has one owner.
  (setq default-frame-alist
        (cons parameter
              (assq-delete-all (car parameter) default-frame-alist))
        initial-frame-alist
        (cons parameter
              (assq-delete-all (car parameter) initial-frame-alist))))

(require 'subr-x)

(defconst sk/theme-generated-file
  (expand-file-name
   "emacs/sk-theme-generated.el"
   (or (getenv "XDG_CONFIG_HOME")
       (expand-file-name ".config" "~")))
  "Guix Home's immutable generated Emacs theme adapter.")

(defun sk/immutable-store-file-p (file)
  "Return non-nil when readable FILE resolves below /gnu/store."
  (and (file-readable-p file)
       (condition-case nil
           (string-prefix-p "/gnu/store/" (file-truename file))
         (file-error nil))))

(defun sk/load-generated-theme (&optional file)
  "Load immutable generated theme FILE once.
FILE defaults to `sk/theme-generated-file'.  Mutable lookalikes are ignored."
  (let ((file (or file sk/theme-generated-file)))
    (when (and (not (featurep 'sk-theme-generated))
               (sk/immutable-store-file-p file))
      (load file nil 'nomessage)
      (featurep 'sk-theme-generated))))

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

;; Before P3.4 activation this file is absent and sk-ui retains the exact
;; legacy Iosevka/Modus behavior.  Never load a mutable lookalike from
;; ~/.config.  Load after native-cache redirection but before frame creation.
(sk/load-generated-theme)

(when (fboundp 'sk/startup-trace-mark)
  (sk/startup-trace-mark "early-init-exit"))

;;; early-init.el ends here
