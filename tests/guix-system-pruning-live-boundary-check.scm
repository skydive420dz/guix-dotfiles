;;; Pure positive and adversarial tests for the D4c.1a live boundary.

(use-modules (gcrypt hash)
             (guix base16)
             (rnrs bytevectors)
             ((sk system-pruning-live-manifest) #:prefix manifest:)
             (sk system-pruning-live-boundary)
             (sk system-pruning-live-contract-fixture)
             (srfi srfi-1))

(define %program "guix-system-pruning-live-boundary-check")
(define %checks 0)

(define (check condition label)
  (set! %checks (+ %checks 1))
  (unless condition (error %program label)))

(define (expect-failure thunk label)
  (set! %checks (+ %checks 1))
  (unless
      (catch sk:live-boundary-error-key
        (lambda () (thunk) #f)
        (lambda _ #t))
    (error %program (string-append "expected failure: " label))))

(define (replace-association alist key value)
  (map (lambda (entry)
         (if (eq? (car entry) key) (cons key value) entry))
       alist))

(define (replace-first text old new)
  (let ((index (string-contains text old)))
    (and index
         (string-append (substring text 0 index)
                        new
                        (substring text (+ index (string-length old)))))))

(define (history-with-terminal terminal)
  (find (lambda (trace)
          (string=? (car (last trace)) terminal))
        (sk:legal-live-journal-traces %live-boundary)))

(define (history-through trace event-name)
  (let loop ((remaining trace) (result '()))
    (let* ((item (car remaining))
           (next (append result (list item))))
      (if (string=? (car item) event-name)
          next
          (loop (cdr remaining) next)))))

(define (text-sha256 text)
  (bytevector->base16-string
   (bytevector-hash (string->utf8 text) (hash-algorithm sha256))))

(define (load-live-manifest-fixture)
  (let* ((module (make-module 0))
         (path (string-append
                (dirname (current-filename))
                "/guix-system-pruning-live-manifest-check.scm")))
    (module-use! module (resolve-interface '(guile)))
    (let ((output
           (with-output-to-string
             (lambda ()
               (save-module-excursion
                (lambda ()
                  (set-current-module module)
                  (primitive-load path)))))))
      (check
       (string=? output
                 "guix-system-pruning-live-manifest-check: PASS (90 checks)\n")
       "canonical live-manifest fixture did not pass in isolation"))
    (module-ref module '%manifest)))

(check (equal? (sk:assert-live-boundary %live-boundary) %live-boundary)
       "closed live boundary was rejected")
(check (equal? (sk:live-boundary-roots %live-boundary)
               (cdr (assq 'roots %live-boundary)))
       "live root accessor drifted")
(check
 (equal?
  (sk:live-boundary-program-root %live-boundary)
  '("/var/guix/gcroots/p52b-system-prune-program-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    "/gnu/store/00000000000000000000000000000000-system-pruning-loaded.scm"))
 "direct program-root formula did not bind the manifest SHA256")

(define %manifest-fixture (load-live-manifest-fixture))
(define %derived-boundary
  (sk:make-live-boundary
   %manifest-fixture
   "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
   "/gnu/store/00000000000000000000000000000000-system-pruning-loaded.scm"
   "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
   "4096"))
(define %fixture-manifest-sha
  (manifest:sk:live-manifest-text-sha256
   (manifest:sk:render-live-manifest %manifest-fixture)))

(check (string=? (cdr (assq 'manifest-sha %derived-boundary))
                 %fixture-manifest-sha)
       "constructor did not derive the canonical manifest SHA256")
(check (string=? (cdr (assq 'source-checkpoint %derived-boundary))
                 (cadr (manifest:sk:live-manifest-single-record
                        %manifest-fixture "source-checkpoint")))
       "constructor did not derive the source checkpoint")
(check (string=? (cdr (assq 'boot-id %derived-boundary))
                 (cadr (manifest:sk:live-manifest-single-record
                        %manifest-fixture "boot-id")))
       "constructor did not derive the boot ID")
(check (string=? (cdr (assq 'selector %derived-boundary)) "1")
       "constructor did not derive the exact selected generation")
(check (equal? (sk:live-boundary-roots %derived-boundary)
               (map cdr
                    (manifest:sk:live-manifest-recovery-roots
                     %manifest-fixture)))
       "constructor did not derive the exact recovery roots")
(check (string=? (car (sk:live-boundary-program-root %derived-boundary))
                 (string-append
                  "/var/guix/gcroots/p52b-system-prune-program-"
                  %fixture-manifest-sha))
       "constructor program-root formula drifted")

(for-each
 (lambda (case)
   (expect-failure
    (lambda () (sk:assert-live-boundary case))
    "malformed live boundary accepted"))
 (list
  (reverse %live-boundary)
  (replace-association %live-boundary 'mode "FIXTURE-ONLY")
  (replace-association %live-boundary 'grant-policy "NONE")
  (replace-association %live-boundary 'manifest-sha "A")
  (replace-association
   %live-boundary 'manifest-sha
   (string-append "١" (make-string 63 #\a)))
  (replace-association %live-boundary 'packet-sha
                       "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC")
  (replace-association %live-boundary 'boot-id
                       "01234567-89AB-CDEF-0123-456789ABCDEF")
  (replace-association %live-boundary 'boot-id
                       "٠1234567-89ab-cdef-0123-456789abcdef")
  (replace-association %live-boundary 'selector "01")
  (replace-association
   %live-boundary 'program
   '("/gnu/store/00000000000000000000000000000000-other.scm"
     "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
     "4096"))
  (replace-association
   %live-boundary 'roots
   (reverse (cdr (assq 'roots %live-boundary))))
  (replace-association
   %live-boundary 'roots
   (cons
    (list "candidate" "candidate-g١" "١"
          "/gnu/store/11111111111111111111111111111111-system")
    (cdr (cdr (assq 'roots %live-boundary)))))))

(define %traces (sk:legal-live-journal-traces %live-boundary))
(define %forward (history-with-terminal "COMPLETE"))
(define %rollback (history-with-terminal "ROLLED-BACK"))

(check (pair? %traces) "live journal automaton is empty")
(check %forward "live journal automaton lacks COMPLETE")
(check %rollback "live journal automaton lacks ROLLED-BACK")
(check (every (lambda (trace)
                (equal? (sk:parse-live-journal
                         %live-boundary
                         (sk:render-live-journal %live-boundary trace))
                        trace))
              %traces)
       "a complete live journal trace did not round-trip")

(define %begin '(("BEGIN" "-")))
(define %begin-text (sk:render-live-journal %live-boundary %begin))
(define %event-offset (string-contains %begin-text "event\t1\t"))
(define %journal-header-text (substring %begin-text 0 %event-offset))

(define (render-unchecked-journal history)
  (let loop ((remaining history)
             (sequence 1)
             (previous (text-sha256 %journal-header-text))
             (rows '()))
    (if (null? remaining)
        (string-append %journal-header-text
                       (string-concatenate (reverse rows)))
        (let* ((item (car remaining))
               (payload
                (string-append "event\t" (number->string sequence) "\t"
                               (car item) "\t" (cadr item) "\t"
                               previous "\n"))
               (digest (text-sha256 payload))
               (row (string-append
                     "event\t" (number->string sequence) "\t"
                     (car item) "\t" (cadr item) "\t"
                     previous "\t" digest "\n")))
          (loop (cdr remaining) (+ sequence 1) digest (cons row rows))))))

(check (equal? (sk:parse-live-journal %live-boundary %begin-text) %begin)
       "BEGIN live journal did not round-trip")
(check (eq? (sk:live-journal-history-status %live-boundary %begin) 'begin)
       "BEGIN live journal status drifted")
(check (pair? (sk:live-journal-legal-successors %live-boundary %begin))
       "BEGIN live journal has no successor")

(let* ((successor (car (sk:live-journal-legal-successors
                        %live-boundary %begin)))
       (appended (sk:append-live-journal-event
                  %live-boundary %begin-text successor)))
  (check (equal? (sk:parse-live-journal %live-boundary appended)
                 (append %begin (list successor)))
         "live journal append did not preserve history"))

(for-each
 (lambda (case)
   (expect-failure
    (lambda () (sk:parse-live-journal %live-boundary case))
    "noncanonical live journal accepted"))
 (list
  ""
  (substring %begin-text 0 (- (string-length %begin-text) 1))
  (string-append (substring %begin-text 0 10) "\r"
                 (substring %begin-text 10))
  (string-append (substring %begin-text 0 10) (string #\nul)
                 (substring %begin-text 10))
  (replace-first %begin-text "LIVE-TRANSACTION" "FIXTURE-ONLY")
  (replace-first %begin-text
                 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                 "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")
  (string-append (substring %begin-text 0 (- (string-length %begin-text) 2))
                 "0\n")))

(expect-failure
 (lambda ()
   (sk:assert-legal-live-journal-successor
    %live-boundary %begin '("COMMITTED" "-")))
 "illegal live journal jump accepted")
(expect-failure
 (lambda ()
   (sk:assert-legal-live-journal-successor
    %live-boundary %begin '("BACKUP-DONE" "wrong-subject")))
 "live journal subject widening accepted")

(define %committed (history-through %forward "COMMITTED"))
(define %rollback-begin (history-through %rollback "ROLLBACK-BEGIN"))
(for-each
 (lambda (history label)
   (expect-failure
    (lambda ()
      (sk:parse-live-journal
       %live-boundary (render-unchecked-journal history)))
    label))
 (list
  (append %begin '(("BACKUP-DONE" "-") ("BACKUP-DONE" "-")))
  (append %begin '(("ROOTS-READY" "-")))
  (append %begin '(("ROOTS-READY" "-") ("BACKUP-DONE" "-")))
  (append %committed '(("ROLLBACK-BEGIN" "-")))
  (append %rollback-begin '(("GRUB-REPLACE-DONE" "-")))
  (append %forward '(("BEGIN" "-"))))
 '("hash-valid duplicate event"
   "hash-valid skipped event"
   "hash-valid reordered events"
   "hash-valid rollback after commit"
   "hash-valid forward event after rollback"
   "hash-valid event after terminal"))

(check (string=? (car (last %forward)) "COMPLETE")
       "forward journal does not terminate at COMPLETE")
(check (string=? (car (last %rollback)) "ROLLED-BACK")
       "rollback journal does not terminate at ROLLED-BACK")
(check (every (lambda (trace)
                (not (any (lambda (event)
                            (string=? (cadr event) "program-root"))
                          trace)))
              %traces)
       "journal automaton tried to remove the program root")

(format #t "~a: PASS (~a checks)~%" %program %checks)
