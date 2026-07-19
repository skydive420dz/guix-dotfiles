;;; Real-filesystem fixtures for the D4a synthetic reconciler.

(use-modules (gcrypt hash)
             (guix base16)
             (guix build syscalls)
             (guix build utils)
             (rnrs bytevectors)
             ((sk system-pruning-boundary) #:prefix boundary:)
             ((sk system-pruning-reconciliation) #:prefix reconciliation:)
             (srfi srfi-1))

(define %program "guix-system-pruning-reconciliation-check")
(define %sha (make-string 64 #\a))
(define %checks 0)

(define %expected-reconciliation-phases
  '("legacy-remove-transaction-directory"
    "legacy-remove-quarantine"
    "legacy-remove-initial-journal-temporary"
    "write-exact-old-grub-backup"
    "append-BACKUP-DONE"
    "remove-known-GRUB-temporary"
    "remove-known-bootcfg-temporary"))

(define (fail format-string . arguments)
  (format (current-error-port)
          "~a: FAIL: ~a~%"
          %program
          (apply format #f format-string arguments))
  (exit 1))

(define (check condition label)
  (set! %checks (+ %checks 1))
  (unless condition (fail "~a" label)))

(check (equal? reconciliation:sk:reconciliation-phase-labels
               %expected-reconciliation-phases)
       "closed reconciliation phase labels drifted")

(define (write-text! path text mode)
  (mkdir-p (dirname path))
  (call-with-output-file path (lambda (port) (display text port)))
  (chmod path mode))

(define (mkdir-exact! path)
  (mkdir-p path)
  (chmod path #o700))

(define (replace-symlink! raw path)
  (when (file-exists? path) (delete-file path))
  (mkdir-p (dirname path))
  (symlink raw path))

(define %phases
  '("program-temporary-root"
    "program-root"
    "transaction-base"
    "transaction-lock"
    "system-lock"
    "durable-root:candidate-g1"
    "grub-replace"
    "bootcfg-promote"
    "link-exclude:1"
    "journal-COMMITTED"
    "journal-COMPLETE"
    "program-root-remove"))

(define (manifest)
  `((schema . "p5.2b-system-prune-boundary/v1")
    (mode . "FIXTURE-ONLY")
    (authorization . "NOT-GRANTED")
    (manifest-sha . ,%sha)
    (program-root
     . (,(string-append
          "/var/guix/gcroots/p52b-system-prune-program-" %sha)
        "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system-pruning-loaded.scm"))
    (roots
     . (("candidate" "candidate-g1" "1"
         "/gnu/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-system")
        ("bootcfg-old" "old-bootcfg" "-"
         "/gnu/store/cccccccccccccccccccccccccccccccc-grub.cfg")
        ("bootcfg-new" "new-bootcfg" "-"
         "/gnu/store/dddddddddddddddddddddddddddddddd-grub.cfg")))
    (phases . ,%phases)))

(define (fixture-config root)
  (let* ((old-target (string-append root "/store/old-grub.cfg"))
         (new-target (string-append root "/store/new-grub.cfg")))
    (reconciliation:sk:make-reconciliation-config
     root
     (manifest)
     '("old grub\n" 420)
     '("new grub\n" 420)
     (list "../../../store/old-grub.cfg" old-target)
     (list "../../../store/new-grub.cfg" new-target)
     (getuid))))

(define (config-ref config key)
  (cdr (assq key config)))

(define (path-ref config key)
  (cdr (assq key (config-ref config 'paths))))

(define (setup-baseline! config)
  (let ((root (config-ref config 'root)))
    (chmod root #o700)
    (write-text!
     (string-append root "/.p52b-system-pruning-reconciliation")
     "p5.2b-system-pruning-reconciliation/v1\n"
     #o600)
    (write-text! (cadr (config-ref config 'old-bootcfg)) "old target\n" #o600)
    (write-text! (cadr (config-ref config 'new-bootcfg)) "new target\n" #o600)
    (write-text! (path-ref config 'grub)
                 (car (config-ref config 'old-grub))
                 (cadr (config-ref config 'old-grub)))
    (replace-symlink! (car (config-ref config 'old-bootcfg))
                      (path-ref config 'bootcfg))))

(define (with-fixture thunk)
  (let* ((template
          (string-copy
           (string-append (or (getenv "TMPDIR") "/tmp")
                          "/p52b-reconciliation.XXXXXX")))
         (root (mkdtemp! template))
         (config (fixture-config root)))
    (dynamic-wind
      (lambda () (setup-baseline! config))
      (lambda () (thunk config))
      (lambda () (delete-file-recursively root)))))

(define (render-history history)
  (boundary:sk:render-journal (manifest) history))

(define (test-sha256 text)
  (bytevector->base16-string
   (bytevector-hash
    (string->utf8 text)
    (hash-algorithm sha256))))

;; Test-only construction of hash-valid but automaton-illegal bytes.
(define (render-unchecked-chain config history)
  (let* ((sha (cdr (assq 'manifest-sha (config-ref config 'manifest))))
         (header
          (string-append
           "schema\tp5.2b-system-prune-journal/v1\n"
           "manifest\t" sha "\n"
           "mode\tFIXTURE-ONLY\n"
           "transaction\t" sha "\n")))
    (let loop ((remaining history)
               (sequence 1)
               (previous (test-sha256 header))
               (result header))
      (if (null? remaining)
          result
          (let* ((item (car remaining))
                 (payload
                  (string-join
                   (list (number->string sequence)
                         (car item)
                         (cadr item)
                         previous)
                   "\t"))
                 (digest (test-sha256 payload)))
            (loop
             (cdr remaining)
             (+ sequence 1)
             digest
             (string-append
              result "event\t" payload "\t" digest "\n")))))))

(define (history-through trace name)
  (let ((index
         (list-index (lambda (item) (string=? (car item) name)) trace)))
    (unless index (fail "trace lacks fixture event: ~a" name))
    (take trace (+ index 1))))

(define (setup-program-prefix! config)
  (let ((program (cdr (assq 'program-root (config-ref config 'manifest)))))
    (mkdir-p (dirname (path-ref config 'program-root)))
    (symlink (cadr program) (path-ref config 'program-root))))

(define (setup-base! config)
  (mkdir-exact! (path-ref config 'transaction-base)))

(define (setup-lock! config key)
  (write-text! (path-ref config key) "" #o600))

(define (setup-namespace! config)
  (mkdir-exact! (path-ref config 'root-namespace)))

(define (setup-durable-prefix! config count)
  (for-each
   (lambda (entry)
     (symlink (caddr entry) (cadr entry)))
   (take (path-ref config 'durable-roots) count)))

(define (setup-complete-bootstrap! config)
  (setup-program-prefix! config)
  (setup-base! config)
  (setup-lock! config 'transaction-lock)
  (setup-lock! config 'system-lock)
  (setup-namespace! config)
  (setup-durable-prefix! config
                         (length (path-ref config 'durable-roots)))
  (mkdir-exact! (path-ref config 'transaction-dir))
  (mkdir-exact! (path-ref config 'quarantine)))

(define (write-journal! config history)
  (write-text! (path-ref config 'journal)
               (render-history history)
               #o600))

(define (write-raw-journal! config text)
  (write-text! (path-ref config 'journal) text #o600))

(define (normal-run config)
  (let ((labels '()))
    (let ((classification
           (reconciliation:sk:reconcile-synthetic!
            config
            (lambda (label thunk)
              (check (member label
                             reconciliation:sk:reconciliation-phase-labels)
                     "runner received an unregistered reconciliation phase")
              (set! labels (append labels (list label)))
              (thunk)))))
      (list classification
            labels
            (reconciliation:sk:observe-reconciliation config)))))

(define (check-restartable setup label)
  (let ((reference #f)
        (effects #f))
    (with-fixture
     (lambda (config)
       (setup config)
       (let ((result (normal-run config)))
         (set! reference (list (car result) (caddr result)))
         (set! effects (length (cadr result)))
         (check (> effects 0)
                (string-append label " did not execute an effect")))))
    (for-each
     (lambda (stop-after)
       (with-fixture
        (lambda (config)
          (setup config)
          (let ((count 0))
            (catch 'fixture-stop
              (lambda ()
                (reconciliation:sk:reconcile-synthetic!
                 config
                 (lambda (_label thunk)
                   (set! count (+ count 1))
                   (thunk)
                   (when (= count stop-after)
                     (throw 'fixture-stop)))))
              (lambda _ #t)))
          (let ((result (normal-run config)))
            (check
             (equal? (list (car result) (caddr result)) reference)
             (format #f "~a did not converge after effect ~a"
                     label stop-after))))))
     (iota effects 1))))

(define (check-legacy-converges setup label)
  (check-restartable setup label)
  (with-fixture
   (lambda (config)
     (setup config)
     (let ((first (normal-run config)))
       (check (equal? (car first) '("NO-LEGACY-GAP" "-" ()))
              (string-append label " did not converge to NO-LEGACY-GAP"))
       (let ((second (normal-run config)))
         (check (equal? (car second) '("NO-LEGACY-GAP" "-" ()))
                (string-append label " changed class on second invocation"))
         (check (null? (cadr second))
                (string-append label " repeated an effect after convergence")))))))

(define (assert-no-effect config label)
  (let ((calls 0))
    (let ((classification
           (reconciliation:sk:reconcile-synthetic!
            config
            (lambda (_label thunk)
              (set! calls (+ calls 1))
              (thunk)))))
      (check (zero? calls) (string-append label " unexpectedly mutated"))
      classification)))

;; Closed configuration and lexical capability boundary.
(with-fixture
 (lambda (config)
   (check
    (equal? (reconciliation:sk:assert-reconciliation-config config) config)
    "closed reconciliation config was rejected")
   (let* ((paths (config-ref config 'paths))
          (bad-paths
           (map (lambda (entry)
                  (if (eq? (car entry) 'grub)
                      (cons 'grub "/boot/grub/grub.cfg")
                      entry))
                paths))
          (bad-config
           (map (lambda (entry)
                  (if (eq? (car entry) 'paths)
                      (cons 'paths bad-paths)
                      entry))
                config)))
     (check
      (catch reconciliation:sk:reconciliation-error-key
        (lambda ()
          (reconciliation:sk:assert-reconciliation-config bad-config)
          #f)
        (lambda _ #t))
      "live /boot path escaped the fixture-root capability"))))

;; Every production bootstrap prefix is classification/resume-only.
(with-fixture
 (lambda (config)
   (check
    (string=? (car (assert-no-effect config "empty bootstrap"))
              "INITIAL-ELIGIBLE")
    "empty bootstrap was not initial-eligible")
   (setup-program-prefix! config)
   (check (string=? (cadr (assert-no-effect config "program prefix"))
                    "transaction-base")
          "program prefix chose the wrong resume point")
   (setup-base! config)
   (check (string=? (cadr (assert-no-effect config "base prefix"))
                    "transaction-lock")
          "base prefix chose the wrong resume point")
   (setup-lock! config 'transaction-lock)
   (check (string=? (cadr (assert-no-effect config "transaction lock prefix"))
                    "system-lock")
          "transaction lock prefix chose the wrong resume point")
   (setup-lock! config 'system-lock)
   (check (string=? (cadr (assert-no-effect config "System lock prefix"))
                    "root-namespace")
          "System lock prefix chose the wrong resume point")
   (setup-namespace! config)
   (for-each
    (lambda (count)
      (let ((classification
             (assert-no-effect config "durable-root prefix")))
        (if (< count (length (path-ref config 'durable-roots)))
            (begin
              (check
               (string=? (cadr classification)
                         (string-append
                          "durable-root:"
                          (car (list-ref
                                (path-ref config 'durable-roots) count))))
               "durable-root prefix chose the wrong successor")
              (let ((entry
                     (list-ref (path-ref config 'durable-roots) count)))
                (symlink (caddr entry) (cadr entry))))
            (check (string=? (cadr classification) "transaction-directory")
                   "complete roots did not advance to transaction dir"))))
    (iota (+ (length (path-ref config 'durable-roots)) 1)))
   (mkdir-exact! (path-ref config 'transaction-dir))
   (check (string=? (cadr (assert-no-effect config "transaction dir prefix"))
                    "quarantine")
          "transaction directory did not advance to quarantine")
   (mkdir-exact! (path-ref config 'quarantine))
   (check (string=? (cadr (assert-no-effect config "quarantine prefix"))
                    "initial-journal")
          "quarantine did not advance to initial journal")
   (let* ((initial (config-ref config 'initial-journal))
          (prefix (substring initial 0 (- (string-length initial) 1))))
     (for-each
      (lambda (bytes label)
        (write-text! (path-ref config 'journal-temporary) bytes #o600)
        (check
         (string=? (cadr (assert-no-effect config label))
                   "reconcile-initial-journal")
         (string-append label " was not classification-only")))
      (list prefix initial)
      '("full canonical initial-journal prefix"
        "full canonical initial-journal equal")))))

;; Legacy rootless rows: directory, quarantine, and both initial-temp forms.
(check-legacy-converges
 (lambda (config)
   (setup-base! config)
   (mkdir-exact! (path-ref config 'transaction-dir)))
 "legacy transaction-directory-only")
(check-legacy-converges
 (lambda (config)
   (setup-base! config)
   (mkdir-exact! (path-ref config 'transaction-dir))
   (mkdir-exact! (path-ref config 'quarantine)))
 "legacy empty quarantine")
(for-each
 (lambda (bytes label)
   (check-legacy-converges
    (lambda (config)
      (setup-base! config)
      (mkdir-exact! (path-ref config 'transaction-dir))
      (mkdir-exact! (path-ref config 'quarantine))
      (write-text! (path-ref config 'journal-temporary) bytes #o600))
    label))
 (list
  (let ((initial
         (boundary:sk:render-journal (manifest) '(("BEGIN" "-")))))
    (substring initial 0 (- (string-length initial) 1)))
  (boundary:sk:render-journal (manifest) '(("BEGIN" "-"))))
 '("legacy initial-journal prefix" "legacy initial-journal equal"))

;; BEGIN backup reconciliation: absent, exact prefix, and complete.
(for-each
 (lambda (backup label)
   (check-restartable
    (lambda (config)
      (setup-complete-bootstrap! config)
      (write-journal! config '(("BEGIN" "-")))
      (case backup
        ((partial)
         (write-text! (path-ref config 'backup) "old" #o644))
        ((exact)
         (write-text! (path-ref config 'backup)
                      (car (config-ref config 'old-grub))
                      #o644))))
    label))
 '(absent partial exact)
 '("BEGIN absent backup" "BEGIN partial backup" "BEGIN exact backup"))

;; Each unique active known temporary is bound and removed durably.
(define %forward
  (car (boundary:sk:legal-journal-traces (manifest))))
(define %rollback
  (find
   (lambda (trace)
     (and (member '("BOOTCFG-PROMOTE-DONE" "-") trace)
          (member '("BOOTCFG-RESTORE-INTENT" "-") trace)))
   (boundary:sk:legal-journal-traces (manifest))))

;; A valid SHA-256 chain cannot disguise an illegal D4 event order.
(for-each
 (lambda (history label)
   (with-fixture
    (lambda (config)
      (setup-complete-bootstrap! config)
      (write-text! (path-ref config 'backup)
                   (car (config-ref config 'old-grub))
                   #o644)
      (write-raw-journal!
       config (render-unchecked-chain config history))
      (let ((classification (assert-no-effect config label)))
        (check (string=? (car classification) "REVIEW-REQUIRED")
               (string-append label " was not rejected before effects"))))))
 (list
  '(("BEGIN" "-") ("BEGIN" "-"))
  (append (take %forward 2) (drop %forward 3))
  (append (take %forward 3)
          (list (list-ref %forward 4) (list-ref %forward 3)))
  (append %forward '(("BACKUP-DONE" "-"))))
 '("hash-valid duplicate journal event"
   "hash-valid skipped journal event"
   "hash-valid reordered journal event"
   "hash-valid terminal journal suffix"))

(for-each
 (lambda (kind label)
   (check-restartable
    (lambda (config)
      (setup-complete-bootstrap! config)
      (write-text! (path-ref config 'backup)
                   (car (config-ref config 'old-grub))
                   #o644)
      (case kind
        ((grub-forward)
         (write-journal! config
                         (history-through %forward "GRUB-REPLACE-INTENT"))
         (write-text! (path-ref config 'grub-temporary)
                      (car (config-ref config 'new-grub))
                      #o644))
        ((bootcfg-forward)
         (write-journal! config
                         (history-through %forward "BOOTCFG-PROMOTE-INTENT"))
         (write-text! (path-ref config 'grub)
                      (car (config-ref config 'new-grub))
                      #o644)
         (replace-symlink! (car (config-ref config 'new-bootcfg))
                           (path-ref config 'bootcfg-temporary)))
        ((grub-rollback)
         (write-journal! config
                         (history-through %rollback "GRUB-RESTORE-INTENT"))
         (write-text! (path-ref config 'grub)
                      (car (config-ref config 'new-grub))
                      #o644)
         (replace-symlink! (car (config-ref config 'new-bootcfg))
                           (path-ref config 'bootcfg))
         (write-text! (path-ref config 'grub-temporary)
                      (car (config-ref config 'old-grub))
                      #o644))
        ((bootcfg-rollback)
         (write-journal! config
                         (history-through %rollback "BOOTCFG-RESTORE-INTENT"))
         (replace-symlink! (car (config-ref config 'new-bootcfg))
                           (path-ref config 'bootcfg))
         (replace-symlink! (car (config-ref config 'old-bootcfg))
                           (path-ref config 'bootcfg-temporary)))))
    label))
 '(grub-forward bootcfg-forward grub-rollback bootcfg-rollback)
 '("forward GRUB temporary" "forward bootcfg temporary"
   "rollback GRUB temporary" "rollback bootcfg temporary"))

;; REVIEW-REQUIRED cases are effect-free: extras, unsafe type, ambiguity,
;; non-prefix backup, and a temporary at the wrong journal head.
(for-each
 (lambda (setup label)
   (with-fixture
    (lambda (config)
      (setup config)
      (let ((classification (assert-no-effect config label)))
        (check (string=? (car classification) "REVIEW-REQUIRED")
               (string-append label " was not review-required"))))))
 (list
  (lambda (config)
    (setup-base! config)
    (mkdir-exact! (path-ref config 'transaction-dir))
    (write-text! (string-append (path-ref config 'transaction-dir) "/extra")
                 "foreign\n" #o600))
  (lambda (config)
    (setup-base! config)
    (mkdir-exact! (path-ref config 'transaction-dir))
    (mkdir-exact! (path-ref config 'quarantine))
    (write-text! (string-append (path-ref config 'quarantine) "/foreign")
                 "foreign\n" #o600))
  (lambda (config)
    (setup-base! config)
    (mkdir-exact! (path-ref config 'transaction-dir))
    (mkdir-exact! (path-ref config 'quarantine))
    (mkdir-exact! (path-ref config 'journal-temporary)))
  (lambda (config)
    (setup-complete-bootstrap! config)
    (write-journal! config
                    (history-through %forward "BOOTCFG-PROMOTE-INTENT"))
    (write-text! (path-ref config 'backup)
                 (car (config-ref config 'old-grub)) #o644)
    (write-text! (path-ref config 'grub)
                 (car (config-ref config 'new-grub)) #o644)
    (write-text! (path-ref config 'grub-temporary)
                 (car (config-ref config 'new-grub)) #o644)
    (replace-symlink! (car (config-ref config 'new-bootcfg))
                      (path-ref config 'bootcfg-temporary)))
  (lambda (config)
    (setup-program-prefix! config)
    (setup-base! config)
    (setup-lock! config 'transaction-lock)
    (setup-lock! config 'system-lock)
    (setup-namespace! config)
    (write-text! (cadr (car (path-ref config 'durable-roots)))
                 "not a root\n" #o600))
  (lambda (config)
    (setup-complete-bootstrap! config)
    (write-journal! config '(("BEGIN" "-")))
    (write-text! (path-ref config 'backup) "not a prefix\n" #o644))
  (lambda (config)
    (setup-complete-bootstrap! config)
    (write-journal! config '(("BEGIN" "-") ("BACKUP-DONE" "-")))
    (write-text! (path-ref config 'backup)
                 (car (config-ref config 'old-grub)) #o644)
    (write-text! (path-ref config 'grub-temporary)
                 (car (config-ref config 'new-grub)) #o644)))
 '("foreign transaction child" "nonempty quarantine"
   "unsafe journal temporary type" "multiple known temporaries"
   "unsafe durable-root type" "non-prefix backup"
   "known temporary at wrong journal head"))

(format #t "~a: PASS (~a checks)~%" %program %checks)
