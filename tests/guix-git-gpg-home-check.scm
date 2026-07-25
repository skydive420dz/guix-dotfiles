(use-modules (gnu home services gnupg)
             (gnu services)
             (guix gexp)
             (ice-9 textual-ports)
             (sk git-home)
             (srfi srfi-1)
             (srfi srfi-13))

(define arguments (command-line))
(unless (= (length arguments) 2)
  (error "expected repository path" arguments))

(define repo (canonicalize-path (cadr arguments)))
(define checks 0)

(define (assert condition message)
  (set! checks (+ checks 1))
  (unless condition (error message)))

(define (read-repository-file relative)
  (call-with-input-file (string-append repo "/" relative) get-string-all))

(assert (string=? %sk-git-user-name "Rafael Oliveira")
        "unexpected declarative Git name")
(assert (string=? %sk-git-user-email "r0liveira@icloud.com")
        "unexpected declarative Git email")
(assert
 (string=?
  %sk-git-signing-key
  "6B094D15B02E54B0F6B5E9E86F83FC62D232E5EC")
 "unexpected declarative Git signing fingerprint")
(assert (= %sk-gpg-default-cache-ttl 600)
        "unexpected GPG default cache TTL")
(assert (= %sk-gpg-max-cache-ttl 7200)
        "unexpected GPG maximum cache TTL")

(define services (sk:git-gpg-home-services))
(assert (= (length services) 3)
        "Git/GPG Home policy must contain exactly three services")

(define agent-services
  (filter
   (lambda (candidate)
     (eq? (service-kind candidate) home-gpg-agent-service-type))
   services))
(assert (= (length agent-services) 1)
        "Git/GPG Home policy must have one GPG agent owner")

(define agent-configuration (service-value (car agent-services)))
(assert (not
         (home-gpg-agent-configuration-ssh-support?
          agent-configuration))
        "GPG agent must not take ownership of SSH authentication")
(assert
 (= (home-gpg-agent-configuration-default-cache-ttl
     agent-configuration)
    600)
 "GPG agent default cache TTL drifted")
(assert
 (= (home-gpg-agent-configuration-max-cache-ttl
     agent-configuration)
    7200)
 "GPG agent maximum cache TTL drifted")
(assert
 (file-like?
  (home-gpg-agent-configuration-pinentry-program
   agent-configuration))
 "GPG agent pinentry must be an immutable file-like")

(define module-source
  (read-repository-file "guix/modules/sk/git-home.scm"))
(define home-source
  (read-repository-file "guix/home/guixpc.scm"))
(define fish-source
  (read-repository-file "shell/config.fish"))

(for-each
 (lambda (text)
   (assert (string-contains module-source text)
           (string-append "Git/GPG module lost policy: " text)))
 '("\"git/config\""
   "\".gnupg/common.conf\""
   "\"use-keyboxd\\n\""
   "\"\\tuseConfigOnly = true\\n\""
   "\"\\tgpgSign = true\\n\""
   "\"\\tformat = openpgp\\n\""
   "\"\\tdefaultBranch = main\\n\""
   "\"\\tff = only\\n\""
   "\"\\tprune = true\\n\""
   "\"\\tconflictStyle = zdiff3\\n\""
   "(file-append pinentry \"/bin/pinentry\")"
   "(ssh-support? #f)"))

(assert (not (string-contains module-source "\"[tag]\\n\""))
        "tag-signing policy entered C7 without approval")
(assert (not (string-contains module-source "core.editor"))
        "Git editor policy entered C7 without approval")
(assert
 (not
  (string-contains
   module-source
   "(file-append gnupg \"/bin/gpg\")"))
        "Git executable pinning entered C7 without approval")
(assert (string-contains home-source "(sk git-home)")
        "Guix Home does not import the Git/GPG adapter")
(assert (string-contains home-source "(sk:git-gpg-home-services)")
        "Guix Home does not install the Git/GPG services")

(for-each
 (lambda (text)
   (assert (string-contains fish-source text)
           (string-append "Fish lost GPG/read-only behavior: " text)))
 '("function __sk_prepare_gpg_terminal"
   "status is-interactive"
   "set -gx GPG_TTY"
   "gpgconf --list-dirs agent-socket"
   "test -S \"$agent_socket\""
   "gpg-connect-agent --no-autostart"
   "updatestartuptty /bye"
   "GIT_OPTIONAL_LOCKS=0 git status --porcelain"))

(assert (not (string-contains fish-source "set -gx TERM"))
        "Fish must not override truthful TERM negotiation")

(format #t "guix-git-gpg-home-check: PASS (~a assertions)~%" checks)
