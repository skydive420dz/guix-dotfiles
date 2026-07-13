;; Read-only preflight for every project-owned Guix Home symlink.

(define arguments (command-line))
(unless (= (length arguments) 2)
  (format (current-error-port) "usage: guile ~a REPOSITORY~%" (car arguments))
  (exit 64))

(define home (or (getenv "HOME") (error "HOME is required")))
(define repo (canonicalize-path (cadr arguments)))

(primitive-load (string-append repo "/guix/home/repo-links.scm"))
(primitive-load (string-append repo "/guix/home/repo-links-manifest.scm"))

((module-ref (current-module) 'sk:check-repo-links)
 home
 repo
 (module-ref (current-module) '%guixpc-repo-links))

(format #t "guix-home-links-preflight: PASS (~a links)~%"
        (length (module-ref (current-module) '%guixpc-repo-links)))
