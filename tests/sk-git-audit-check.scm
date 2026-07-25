(use-modules (ice-9 textual-ports))

(define arguments (command-line))
(unless (= (length arguments) 3)
  (error "usage: sk-git-audit-check.scm REPOSITORY REPORT"))

(define repo (list-ref arguments 1))
(define report-path (list-ref arguments 2))
(primitive-load (string-append repo "/scripts/sk-git-audit"))

(define checks 0)
(define failures 0)

(define (check condition label)
  (set! checks (+ checks 1))
  (unless condition
    (set! failures (+ failures 1))
    (format (current-error-port) "FAIL: ~a~%" label)))

(define (check-equal actual expected label)
  (check (equal? actual expected) label))

(define (field record key)
  (let ((entry (assq key record)))
    (and entry (pair? (cdr entry)) (cadr entry))))

(define parsed
  (parse-status
   (string-append
    "# branch.oid 0123456789abcdef0123456789abcdef01234567\n"
    "# branch.head (detached)\n"
    "1 M. N... 100644 100644 100644 a a staged\n"
    "1 .M N... 100644 100644 100644 a a unstaged\n"
    "2 R. N... 100644 100644 100644 a a R100 renamed\told\n"
    "u UU N... 100644 100644 100644 100644 a a a conflict\n"
    "? private-path\n")))

(check-equal (field parsed 'head-state) 'detached
             "detached state parses")
(check-equal (field parsed 'branch) 'detached
             "detached branch is normalized")
(check-equal (field parsed 'head) "0123456789ab"
             "HEAD is shortened")
(check-equal (field parsed 'staged) 2
             "staged entries are counted")
(check-equal (field parsed 'unstaged) 1
             "unstaged entries are counted")
(check-equal (field parsed 'untracked) 1
             "untracked entries are counted without paths")
(check-equal (field parsed 'conflicts) 1
             "conflicts are counted without paths")

(define unborn
  (parse-status
   "# branch.oid (initial)\n# branch.head main\n? unseen\n"))
(check-equal (field unborn 'head-state) 'unborn
             "unborn state parses")
(check-equal (field unborn 'branch) "main"
             "unborn branch name is retained")
(check-equal (field unborn 'head) 'none
             "unborn repository has no synthetic HEAD")
(check-equal (field unborn 'upstream-present) 'no
             "missing upstream presence is explicit")
(check-equal (field unborn 'upstream-name) 'none
             "missing upstream name is explicit")
(check-equal (field unborn 'cached-ahead) 'unknown
             "missing ahead state is explicit")

(define unborn-tracking
  (parse-status
   (string-append
    "# branch.oid (initial)\n"
    "# branch.head topic\n"
    "# branch.upstream origin/main\n")))
(check-equal (field unborn-tracking 'upstream-present) 'yes
             "unborn configured upstream presence parses")
(check-equal (field unborn-tracking 'upstream-name) "origin/main"
             "unborn configured upstream name parses")
(check-equal (field unborn-tracking 'cached-ahead) 'unknown
             "unborn upstream without branch.ab remains unknown")

(define malformed
  (parse-status "# branch.head main\n"))
(check-equal (field malformed 'head-state) 'unknown
             "missing OID is not misclassified as unborn")
(check-equal (field malformed 'head) 'unknown
             "missing OID has unknown HEAD")

(define no-locks
  '((index no) (head no) (config no)
    (packed-refs no) (shallow no)))
(check-equal
 (repository-state malformed no-locks 0 'absent)
 'unavailable
 "malformed required status cannot be called clean")

(define tracking
  (parse-status
   (string-append
    "# branch.oid 0123456789abcdef0123456789abcdef01234567\n"
    "# branch.head main\n"
    "# branch.upstream origin/main\n"
    "# branch.ab +3 -2\n")))
(check-equal (field tracking 'head-state) 'branch
             "normal branch state parses")
(check-equal (field tracking 'cached-ahead) 3
             "cached divergence ahead count parses")
(check-equal (field tracking 'cached-behind) 2
             "cached divergence behind count parses")

(define saved-runner sk:command-runner)
(define fixture-oid
  "0123456789abcdef0123456789abcdef01234567")
(define (signature-for commit-text)
  (set! sk:command-runner
        (lambda (_program _arguments)
          (command-result 'ok commit-text)))
  (head-signature "/unused" 'branch fixture-oid))

(check-equal
 (signature-for
  "tree a\nauthor a\ngpgsig -----BEGIN PGP SIGNATURE-----\n more\n\nbody\n")
 'present
 "OpenPGP signature header is detected")
(check-equal
 (signature-for
  "tree a\nauthor a\ngpgsig-sha256 -----BEGIN SSH SIGNATURE-----\n more\n\nbody\n")
 'present
 "SHA-256 transition signature header is detected")
(check-equal
 (signature-for
  "tree a\nmergetag object b\n nested gpgsig text\n\nbody\n")
 'absent
 "mergetag content is not misclassified")
(check-equal
 (signature-for
  "tree a\nauthor a\n\nmessage containing gpgsig false-positive\n")
 'absent
 "commit message is excluded from signature detection")
(check-equal (head-signature "/unused" 'unborn 'none)
             'not-applicable
             "unborn signature state is not applicable")
(check-equal (head-signature "/unused" 'unknown 'none)
             'unknown
             "unknown HEAD has unknown signature state")
(set! sk:command-runner saved-runner)

(define report
  (call-with-input-file report-path
    (lambda (port)
      (let ((form (read port))
            (tail (read port)))
        (check (eof-object? tail)
               "report contains exactly one Scheme form")
        form))))
(check-equal (car report) 'sk-git-audit/v1
             "report is versioned")
(check-equal (field (cdr report) 'overall) 'attention
             "dirty fixture attracts attention")
(check-equal (field (cdr report) 'repositories) 1
             "bare remote outside the root is not enrolled")

(define items-entry (assq 'items (cdr report)))
(define items (and items-entry (cdr items-entry)))
(check-equal (length items) 1
             "one worktree is reported")

(define item (car items))
(check-equal (field item 'path) "work"
             "only a root-relative repository path is emitted")
(check-equal (field item 'state) 'attention
             "known locks attract attention")
(check-equal (field item 'branch) "main"
             "branch is reported")
(check-equal (field item 'upstream-present) 'yes
             "upstream presence is reported")
(check-equal (field item 'upstream-name) "origin/main"
             "upstream name is reported without a URL")
(check-equal (field item 'cached-ahead) 0
             "cached ahead count is reported")
(check-equal (field item 'cached-behind) 0
             "cached behind count is reported")
(check-equal (field item 'staged) 1
             "fixture staged count is exact")
(check-equal (field item 'unstaged) 1
             "fixture unstaged count is exact")
(check-equal (field item 'untracked) 2
             "fixture untracked file count is exact")
(check-equal (field item 'conflicts) 0
             "fixture conflict count is exact")
(check-equal (field item 'remotes) 1
             "remote names are reduced to a count")
(check-equal (field item 'head-signature) 'absent
             "unsigned fixture is detected without verification")
(check-equal
 (field item 'locks)
 '((index yes) (head no) (config no)
   (packed-refs yes) (shallow no))
 "known locks are reported as fixed booleans")

(let ((rendered
       (call-with-output-string
         (lambda (port) (write report port)))))
  (check (not (string-contains rendered "fixture.invalid"))
         "identity is not emitted")
  (check (not (string-contains rendered "tracked.txt"))
         "worktree paths are not emitted")
  (check (not (string-contains rendered "origin.git"))
         "remote URLs are not emitted")
  (check (not (string-contains rendered "/tmp/"))
         "absolute fixture root is not emitted"))

(if (zero? failures)
    (begin
      (format #t "sk-git-audit Scheme checks: ~a passed~%" checks)
      (exit 0))
    (begin
      (format (current-error-port)
              "sk-git-audit Scheme checks: ~a failure(s) of ~a~%"
              failures checks)
      (exit 1)))
