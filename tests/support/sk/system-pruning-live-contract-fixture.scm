;;; Shared pure fixture for the P5.2b-D4c.1a live semantic core.

(define-module (sk system-pruning-live-contract-fixture)
  #:export (%live-boundary
            %live-root-names
            make-live-observation
            replace-live-observation))

(define %live-boundary
  '((schema . "p5.2b-system-prune-live-boundary/v1")
    (mode . "LIVE-TRANSACTION")
    (grant-policy . "DISTINCT-EXACT-D5-TOKEN")
    (manifest-sha
     . "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    (source-checkpoint
     . "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    (packet-sha
     . "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc")
    (program
     . ("/gnu/store/00000000000000000000000000000000-system-pruning-loaded.scm"
        "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        "4096"))
    (boot-id . "01234567-89ab-cdef-0123-456789abcdef")
    (selector . "1")
    (roots
     . (("candidate"
         "candidate-g1"
         "1"
         "/gnu/store/11111111111111111111111111111111-system")
        ("bootcfg-old"
         "old-bootcfg"
         "-"
         "/gnu/store/22222222222222222222222222222222-grub.cfg")
        ("bootcfg-new"
         "new-bootcfg"
         "-"
         "/gnu/store/33333333333333333333333333333333-grub.cfg")))))

(define %live-root-names
  '("candidate-g1" "old-bootcfg" "new-bootcfg"))

(define (make-live-observation program base transaction-lock system-lock
                               root-base namespace durable transaction-dir
                               quarantine journal backup)
  `((protected? . #t)
    (foreign? . #f)
    (selected-links . prestate)
    (program-root . ,program)
    (transaction-base . ,base)
    (transaction-lock . ,transaction-lock)
    (system-lock . ,system-lock)
    (recovery-root-base . ,root-base)
    (root-namespace . ,namespace)
    (durable-roots . ,durable)
    (transaction-dir . ,transaction-dir)
    (quarantine . ,quarantine)
    (quarantine-entries . ,(if (eq? quarantine 'absent) 'absent 'empty))
    (journal . ,journal)
    (journal-history . ,(if (eq? journal 'begin)
                            '(("BEGIN" "-"))
                            '()))
    (live-grub . old)
    (live-bootcfg . old)
    (grub-temporary . absent)
    (bootcfg-temporary . absent)
    (backup . ,backup)))

(define (replace-live-observation observation key value)
  (map (lambda (entry)
         (if (eq? (car entry) key)
             (cons key value)
             entry))
       observation))
