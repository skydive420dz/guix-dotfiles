(define-module (sk git-home)
  #:use-module (gnu home services)
  #:use-module (gnu home services gnupg)
  #:use-module (gnu packages gnupg)
  #:use-module (gnu services)
  #:use-module (guix gexp)
  #:export (%sk-git-user-name
            %sk-git-user-email
            %sk-git-signing-key
            %sk-gpg-default-cache-ttl
            %sk-gpg-max-cache-ttl
            sk:git-gpg-home-services))

;;; Declarative Git identity and GnuPG client policy for guixpc.
;;;
;;; Keyrings and private keys remain mutable, private user data.  These
;;; services own only non-secret policy files.

(define %sk-git-user-name "Rafael Oliveira")
(define %sk-git-user-email "r0liveira@icloud.com")
(define %sk-git-signing-key
  "6B094D15B02E54B0F6B5E9E86F83FC62D232E5EC")

(define %sk-gpg-default-cache-ttl 600)
(define %sk-gpg-max-cache-ttl 7200)

(define %sk-git-config
  (plain-file
   "sk-git-config"
   (string-append
    "[user]\n"
    "\tname = " %sk-git-user-name "\n"
    "\temail = " %sk-git-user-email "\n"
    "\tsigningKey = " %sk-git-signing-key "\n"
    "\tuseConfigOnly = true\n"
    "[commit]\n"
    "\tgpgSign = true\n"
    "[gpg]\n"
    "\tformat = openpgp\n"
    "[init]\n"
    "\tdefaultBranch = main\n"
    "[pull]\n"
    "\tff = only\n"
    "[fetch]\n"
    "\tprune = true\n"
    "[merge]\n"
    "\tconflictStyle = zdiff3\n")))

(define %sk-gpg-common-config
  (plain-file "sk-gpg-common.conf" "use-keyboxd\n"))

(define (sk:git-gpg-home-services)
  "Return the non-secret Git and GnuPG policy services for Guix Home."
  (list
   (simple-service 'sk-git-xdg-configuration
                   home-xdg-configuration-files-service-type
                   `(("git/config" ,%sk-git-config)))
   (simple-service 'sk-gpg-common-configuration
                   home-files-service-type
                   `((".gnupg/common.conf" ,%sk-gpg-common-config)))
   (service
    home-gpg-agent-service-type
    (home-gpg-agent-configuration
     (gnupg gnupg)
     ;; Guix's default pinentry package selects GTK 2 when a display is
     ;; usable and retains its curses fallback for a real SSH terminal.
     (pinentry-program (file-append pinentry "/bin/pinentry"))
     ;; OpenSSH remains the sole owner of SSH keys and its authentication
     ;; agent contract.
     (ssh-support? #f)
     (default-cache-ttl %sk-gpg-default-cache-ttl)
     (max-cache-ttl %sk-gpg-max-cache-ttl)))))
