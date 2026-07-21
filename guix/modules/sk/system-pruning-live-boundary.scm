;;; Pure live transaction and journal boundary for P5.2b-D4c.1a.

(define-module (sk system-pruning-live-boundary)
  #:use-module (gcrypt hash)
  #:use-module (guix base16)
  #:use-module (rnrs bytevectors)
  #:use-module ((sk system-pruning-live-manifest) #:prefix manifest:)
  #:use-module (srfi srfi-1)
  #:export (sk:live-boundary-error-key
            sk:live-boundary-schema
            sk:live-journal-schema
            sk:make-live-boundary
            sk:assert-live-boundary
            sk:live-boundary-roots
            sk:live-boundary-program-root
            sk:legal-live-journal-traces
            sk:call-with-live-journal-trace-cache
            sk:legal-live-journal-prefix?
            sk:live-journal-legal-successors
            sk:live-journal-head
            sk:live-journal-history-status
            sk:assert-legal-live-journal-history
            sk:assert-legal-live-journal-successor
            sk:render-live-journal
            sk:parse-live-journal
            sk:append-live-journal-event))

(define sk:live-boundary-error-key
  'sk-system-pruning-live-boundary)

(define sk:live-boundary-schema
  "p5.2b-system-prune-live-boundary/v1")

(define sk:live-journal-schema
  "p5.2b-system-prune-live-journal/v1")

(define %boundary-keys
  '(schema mode grant-policy manifest-sha source-checkpoint packet-sha
    program boot-id selector roots))

(define %guix-base32-alphabet
  "0123456789abcdfghijklmnpqrsvwxyz")

(define (%fail format-string . arguments)
  (throw sk:live-boundary-error-key
         (apply format #f format-string arguments)))

(define (ensure condition format-string . arguments)
  (unless condition
    (apply %fail format-string arguments)))

(define (all predicate values)
  (every predicate values))

(define (ascii-digit? character)
  (and (char>=? character #\0)
       (char<=? character #\9)))

(define (ascii-letter? character)
  (or (and (char>=? character #\a)
           (char<=? character #\z))
      (and (char>=? character #\A)
           (char<=? character #\Z))))

(define (alist-value alist key)
  (let ((entry (assq key alist)))
    (ensure entry "missing live-boundary record: ~s" key)
    (cdr entry)))

(define (records-with-key records key)
  (filter (lambda (record)
            (and (pair? record) (string=? (car record) key)))
          records))

(define (single-record records key)
  (let ((matches (records-with-key records key)))
    (ensure (= (length matches) 1)
            "live manifest does not contain one ~a record" key)
    (car matches)))

(define (canonical-positive-decimal? value)
  (and (string? value)
       (not (string-null? value))
       (all ascii-digit? (string->list value))
       (not (char=? (string-ref value 0) #\0))))

(define (hex-string? value length)
  (and (string? value)
       (= (string-length value) length)
       (all (lambda (character)
              (or (ascii-digit? character)
                  (and (char>=? character #\a)
                       (char<=? character #\f))))
            (string->list value))))

(define (uuid? value)
  (and (string? value)
       (= (string-length value) 36)
       (equal? (map (lambda (index) (string-ref value index))
                    '(8 13 18 23))
               '(#\- #\- #\- #\-))
       (all (lambda (index)
              (or (member index '(8 13 18 23))
                  (let ((character (string-ref value index)))
                    (or (ascii-digit? character)
                        (and (char>=? character #\a)
                             (char<=? character #\f))))))
            (iota 36))))

(define (safe-name? value)
  (and (string? value)
       (not (string-null? value))
       (not (member value '("." "..")))
       (all (lambda (character)
              (or (ascii-letter? character)
                  (ascii-digit? character)
                  (memv character '(#\- #\_ #\. #\:))))
            (string->list value))))

(define (normalized-absolute-path? path)
  (and (string? path)
       (string-prefix? "/" path)
       (not (string=? path "/"))
       (not (string-suffix? "/" path))
       (not (string-contains path "//"))
       (not (any (lambda (component)
                   (member component '("." ".." "")))
                 (cdr (string-split path #\/))))))

(define (store-item? path suffix)
  (and (normalized-absolute-path? path)
       (string-prefix? "/gnu/store/" path)
       (let* ((name (substring path (string-length "/gnu/store/")))
              (dash (string-index name #\-)))
         (and dash
              (= dash 32)
              (not (string-contains name "/"))
              (> (string-length name) 33)
              (all (lambda (character)
                     (string-index %guix-base32-alphabet character))
                   (string->list (substring name 0 dash)))
              (string-suffix? suffix name)))))

(define (string-sha256 value)
  (bytevector->base16-string
   (bytevector-hash
    (string->utf8 value)
    (hash-algorithm sha256))))

(define (strictly-increasing-decimals? values)
  (let loop ((remaining values) (previous #f))
    (if (null? remaining)
        #t
        (let ((number (and (canonical-positive-decimal? (car remaining))
                           (string->number (car remaining) 10))))
          (and number
               (or (not previous) (< previous number))
               (loop (cdr remaining) number))))))

(define (candidate-root? root)
  (and (list? root)
       (= (length root) 4)
       (let ((kind (list-ref root 0))
             (name (list-ref root 1))
             (subject (list-ref root 2))
             (target (list-ref root 3)))
         (and (string=? kind "candidate")
              (canonical-positive-decimal? subject)
              (string=? name (string-append "candidate-g" subject))
              (store-item? target "-system")))))

(define (bootcfg-root? root kind name)
  (and (list? root)
       (= (length root) 4)
       (string=? (list-ref root 0) kind)
       (string=? (list-ref root 1) name)
       (string=? (list-ref root 2) "-")
       (store-item? (list-ref root 3) "-grub.cfg")))

(define (replace-manifest-sha formula sha)
  (let ((marker "{manifest-sha256}"))
    (ensure (string? formula) "live formula is not text")
    (let ((index (string-contains formula marker)))
      (ensure index "live formula lacks its manifest marker")
      (ensure (not (string-contains
                    formula marker (+ index (string-length marker))))
              "live formula does not contain one manifest marker")
      (string-append (substring formula 0 index)
                     sha
                     (substring formula
                                (+ index (string-length marker)))))))

(define (sk:make-live-boundary manifest-records packet-sha
                               program-path program-sha program-size)
  "Derive one closed D5 transaction identity from canonical review records.

This constructor performs no environment lookup and grants no action.  The
packet and program identities are future D4c.3/D5 inputs; all remaining
identity and root records are derived from the validated D4c.1 manifest."
  (let* ((checked (manifest:sk:assert-live-manifest manifest-records))
         (manifest-text (manifest:sk:render-live-manifest checked))
         (manifest-sha (manifest:sk:live-manifest-text-sha256 manifest-text))
         (source (cadr (single-record checked "source-checkpoint")))
         (boot-id (cadr (single-record checked "boot-id")))
         (selector (list-ref (single-record checked "selector") 2))
         (roots (map cdr
                     (manifest:sk:live-manifest-recovery-roots checked)))
         (boundary
          `((schema . ,sk:live-boundary-schema)
            (mode . "LIVE-TRANSACTION")
            (grant-policy . "DISTINCT-EXACT-D5-TOKEN")
            (manifest-sha . ,manifest-sha)
            (source-checkpoint . ,source)
            (packet-sha . ,packet-sha)
            (program . (,program-path ,program-sha ,program-size))
            (boot-id . ,boot-id)
            (selector . ,selector)
            (roots . ,roots))))
    (sk:assert-live-boundary boundary)))

(define (sk:assert-live-boundary boundary)
  "Return BOUNDARY after validating its exact production transaction model."
  (ensure (and (list? boundary)
               (all pair? boundary)
               (equal? (map car boundary) %boundary-keys))
          "live boundary differs from the closed ordered model")
  (ensure (string=? (alist-value boundary 'schema)
                    sk:live-boundary-schema)
          "live boundary schema drift")
  (ensure (string=? (alist-value boundary 'mode) "LIVE-TRANSACTION")
          "live boundary mode is not LIVE-TRANSACTION")
  (ensure (string=? (alist-value boundary 'grant-policy)
                    "DISTINCT-EXACT-D5-TOKEN")
          "live boundary grant policy drift")
  (ensure (hex-string? (alist-value boundary 'manifest-sha) 64)
          "live boundary manifest SHA256 is invalid")
  (ensure (hex-string? (alist-value boundary 'source-checkpoint) 40)
          "live boundary source checkpoint is invalid")
  (ensure (hex-string? (alist-value boundary 'packet-sha) 64)
          "live boundary packet SHA256 is invalid")
  (let ((program (alist-value boundary 'program)))
    (ensure (and (list? program) (= (length program) 3))
            "live boundary program tuple has the wrong shape")
    (ensure (store-item? (list-ref program 0)
                         "-system-pruning-loaded.scm")
            "live boundary program path is not the fused store item")
    (ensure (hex-string? (list-ref program 1) 64)
            "live boundary program SHA256 is invalid")
    (ensure (canonical-positive-decimal? (list-ref program 2))
            "live boundary program size is not canonical"))
  (ensure (uuid? (alist-value boundary 'boot-id))
          "live boundary boot ID is invalid")
  (let* ((selector (alist-value boundary 'selector))
         (roots (alist-value boundary 'roots)))
    (ensure (and (list? roots) (>= (length roots) 3))
            "live boundary recovery roots are incomplete")
    (let* ((candidates (drop-right roots 2))
           (old (list-ref roots (- (length roots) 2)))
           (new (last roots))
           (generations (map (lambda (root) (list-ref root 2)) candidates)))
      (ensure (all candidate-root? candidates)
              "live candidate roots differ from the closed model")
      (ensure (strictly-increasing-decimals? generations)
              "live candidate roots are not in generation order")
      (ensure (bootcfg-root? old "bootcfg-old" "old-bootcfg")
              "live old-bootcfg root is not penultimate")
      (ensure (bootcfg-root? new "bootcfg-new" "new-bootcfg")
              "live new-bootcfg root is not final")
      (ensure (not (string=? (list-ref old 3) (list-ref new 3)))
              "live old/new bootcfg targets are identical")
      (ensure (string=? selector (string-join generations ","))
              "live selector differs from the candidate roots"))
    (ensure (= (length (map cadr roots))
               (length (delete-duplicates (map cadr roots))))
            "live recovery-root names are duplicated")
    (ensure (all (lambda (root) (safe-name? (cadr root))) roots)
            "live recovery-root name is unsafe"))
  boundary)

(define (sk:live-boundary-roots boundary)
  (alist-value (sk:assert-live-boundary boundary) 'roots))

(define (sk:live-boundary-program-root boundary)
  "Return the direct durable program-root path and exact program target."
  (let* ((checked (sk:assert-live-boundary boundary))
         (sha (alist-value checked 'manifest-sha))
         (program (alist-value checked 'program)))
    (list
     (replace-manifest-sha
      manifest:sk:live-manifest-program-root-formula sha)
     (car program))))

(define (event name subject)
  (list name subject))

(define (root-events name roots)
  (append-map
   (lambda (root)
     (let ((subject (cadr root)))
       (list (event (string-append name "-INTENT") subject)
             (event (string-append name "-DONE") subject))))
   roots))

(define (candidate-events name roots)
  (append-map
   (lambda (root)
     (let ((subject (list-ref root 2)))
       (list (event (string-append name "-INTENT") subject)
             (event (string-append name "-DONE") subject))))
   (drop-right roots 2)))

(define (forward-before-commit boundary)
  (let ((roots (sk:live-boundary-roots boundary)))
    (append
     (list (event "BEGIN" "-")
           (event "BACKUP-DONE" "-")
           (event "ROOTS-READY" "-")
           (event "GRUB-REPLACE-INTENT" "-")
           (event "GRUB-REPLACE-DONE" "-")
           (event "BOOTCFG-PROMOTE-INTENT" "-")
           (event "BOOTCFG-PROMOTE-DONE" "-"))
     (candidate-events "LINK-EXCLUDE" roots)
     (list (event "LINKS-STAGED" "-"))
     (candidate-events "LINK-DISCARD" roots)
     (list (event "LINKS-COMMITTED" "-")
           (event "POSTFLIGHT-VERIFIED" "-")))))

(define (cleanup-events boundary terminal)
  (append
   (root-events
    (if (string=? terminal "COMPLETE")
        "ROOT-REMOVE"
        "ROLLBACK-ROOT-REMOVE")
    (sk:live-boundary-roots boundary))
   (list (event terminal "-"))))

(define (rollback-events boundary forward-prefix)
  (let ((roots (sk:live-boundary-roots boundary)))
    (append
     (list (event "ROLLBACK-BEGIN" "-"))
     (candidate-events "LINK-RESTORE" roots)
     (list (event "LINKS-RESTORED" "-"))
     (if (member (event "GRUB-REPLACE-DONE" "-") forward-prefix)
         (list (event "GRUB-RESTORE-INTENT" "-")
               (event "GRUB-RESTORE-DONE" "-"))
         '())
     (if (member (event "BOOTCFG-PROMOTE-DONE" "-") forward-prefix)
         (list (event "BOOTCFG-RESTORE-INTENT" "-")
               (event "BOOTCFG-RESTORE-DONE" "-"))
         '())
     (list (event "PRESTATE-VERIFIED" "-"))
     (cleanup-events boundary "ROLLED-BACK"))))

(define (list-prefix? prefix whole)
  (and (<= (length prefix) (length whole))
       (equal? prefix (take whole (length prefix)))))

(define %live-journal-trace-cache (make-parameter #f))

(define (deep-snapshot value)
  (cond
   ((pair? value)
    (cons (deep-snapshot (car value))
          (deep-snapshot (cdr value))))
   ((string? value) (string-copy value))
   (else value)))

(define (compute-legal-traces boundary)
  (let* ((before (forward-before-commit boundary))
         (committed (append before (list (event "COMMITTED" "-"))))
         (cleanup (cleanup-events boundary "COMPLETE"))
         (rollback-traces
          (map (lambda (length)
                 (let ((prefix (take before length)))
                   (append prefix (rollback-events boundary prefix))))
               (iota (length before) 1))))
    (append
     (list (append committed cleanup))
     (map
      (lambda (length)
        (append committed
                (take cleanup length)
                (list (event "FORWARD-RECOVERY-BEGIN" "-"))
                (drop cleanup length)))
      (iota (length cleanup)))
     rollback-traces)))

(define (legal-traces/internal boundary)
  (let* ((checked (sk:assert-live-boundary boundary))
         (cached (%live-journal-trace-cache)))
    (if (and cached (equal? (car cached) checked))
        (cdr cached)
        (compute-legal-traces (deep-snapshot checked)))))

(define (sk:legal-live-journal-traces boundary)
  "Return a private copy of every legal forward and rollback trace."
  (deep-snapshot (legal-traces/internal boundary)))

(define (sk:call-with-live-journal-trace-cache boundary thunk)
  "Run THUNK with one dynamically scoped immutable live journal automaton."
  (ensure (procedure? thunk)
          "live journal cache continuation is not a procedure")
  (let* ((checked (sk:assert-live-boundary boundary))
         (snapshot (deep-snapshot checked))
         (traces (compute-legal-traces snapshot)))
    (parameterize ((%live-journal-trace-cache (cons snapshot traces)))
      (thunk))))

(define (valid-event-shape? item)
  (and (list? item)
       (= (length item) 2)
       (string? (car item))
       (string? (cadr item))
       (safe-name? (car item))
       (safe-name? (cadr item))))

(define (sk:legal-live-journal-prefix? boundary history)
  (and (list? history)
       (pair? history)
       (all valid-event-shape? history)
       (any (lambda (trace) (list-prefix? history trace))
            (legal-traces/internal boundary))))

(define (sk:live-journal-legal-successors boundary history)
  (ensure (sk:legal-live-journal-prefix? boundary history)
          "live journal history is not a legal closed-trace prefix")
  (deep-snapshot
   (delete-duplicates
    (filter-map
     (lambda (trace)
       (and (list-prefix? history trace)
            (< (length history) (length trace))
            (list-ref trace (length history))))
     (legal-traces/internal boundary)))))

(define (sk:live-journal-head boundary history)
  (last (sk:assert-legal-live-journal-history boundary history)))

(define (sk:live-journal-history-status boundary history)
  (let ((head (car (sk:live-journal-head boundary history))))
    (cond
     ((and (= (length history) 1) (string=? head "BEGIN")) 'begin)
     ((member head '("COMPLETE" "ROLLED-BACK")) 'terminal)
     (else 'active))))

(define (sk:assert-legal-live-journal-history boundary history)
  (ensure (sk:legal-live-journal-prefix? boundary history)
          "live journal history is not a legal closed-trace prefix")
  history)

(define (sk:assert-legal-live-journal-successor boundary history successor)
  (ensure (valid-event-shape? successor)
          "proposed live journal successor has an invalid shape")
  (ensure (member successor
                  (sk:live-journal-legal-successors boundary history))
          "proposed live journal successor is illegal: ~s" successor)
  successor)

(define (journal-header boundary)
  (let* ((checked (sk:assert-live-boundary boundary))
         (program (alist-value checked 'program)))
    (list
     (list "schema" sk:live-journal-schema)
     (list "mode" "LIVE-TRANSACTION")
     (list "manifest-sha256" (alist-value checked 'manifest-sha))
     (list "source-checkpoint" (alist-value checked 'source-checkpoint))
     (list "packet-sha256" (alist-value checked 'packet-sha))
     (list "program-path" (list-ref program 0))
     (list "program-sha256" (list-ref program 1))
     (list "program-size" (list-ref program 2))
     (list "boot-id" (alist-value checked 'boot-id))
     (list "selector" (alist-value checked 'selector)))))

(define (tsv-line fields)
  (string-append (string-join fields "\t") "\n"))

(define (journal-header-text boundary)
  (string-concatenate (map tsv-line (journal-header boundary))))

(define (journal-payload sequence event-name subject previous)
  (tsv-line
   (list "event" (number->string sequence) event-name subject previous)))

(define (journal-record sequence event-name subject previous)
  (let ((payload (journal-payload sequence event-name subject previous)))
    (list "event"
          (number->string sequence)
          event-name
          subject
          previous
          (string-sha256 payload))))

(define (strict-tsv-records text)
  (ensure (and (string? text) (not (string-null? text)))
          "live journal input is empty or non-text")
  (ensure (not (string-index text #\nul))
          "live journal input contains NUL")
  (ensure (not (string-index text #\return))
          "live journal input contains CR")
  (ensure (string-suffix? "\n" text)
          "live journal bytes are not canonical LF-terminated text")
  (let ((lines (drop-right (string-split text #\newline) 1)))
    (ensure (and (pair? lines)
                 (all (lambda (line) (not (string-null? line))) lines))
            "live journal contains an empty or incomplete row")
    (map (lambda (line) (string-split line #\tab)) lines)))

(define (sk:render-live-journal boundary history)
  "Render one validated history as the canonical live SHA-256 journal."
  (sk:assert-legal-live-journal-history boundary history)
  (let loop ((remaining history)
             (sequence 1)
             (previous (string-sha256 (journal-header-text boundary)))
             (records '()))
    (if (null? remaining)
        (string-append
         (journal-header-text boundary)
         (string-concatenate (map tsv-line (reverse records))))
        (let* ((item (car remaining))
               (record
                (journal-record sequence (car item) (cadr item) previous)))
          (loop (cdr remaining)
                (+ sequence 1)
                (list-ref record 5)
                (cons record records))))))

(define (sk:parse-live-journal boundary text)
  "Parse one complete non-empty canonical live journal."
  (let* ((header (journal-header boundary))
         (records (strict-tsv-records text)))
    (ensure (> (length records) (length header))
            "live journal has no event history")
    (ensure (equal? (take records (length header)) header)
            "live journal header or transaction identity differs")
    (let loop ((remaining (drop records (length header)))
               (sequence 1)
               (previous (string-sha256 (journal-header-text boundary)))
               (history '()))
      (if (null? remaining)
          (sk:assert-legal-live-journal-history
           boundary (reverse history))
          (let ((record (car remaining)))
            (ensure (and (= (length record) 6)
                         (string=? (car record) "event"))
                    "live journal event row has an invalid shape")
            (let* ((sequence-text (list-ref record 1))
                   (event-name (list-ref record 2))
                   (subject (list-ref record 3))
                   (prior (list-ref record 4))
                   (digest (list-ref record 5))
                   (payload
                    (journal-payload sequence event-name subject prior)))
              (ensure (string=? sequence-text (number->string sequence))
                      "live journal sequence is not canonical")
              (ensure (string=? prior previous)
                      "live journal hash-chain predecessor differs")
              (ensure (string=? digest (string-sha256 payload))
                      "live journal event digest differs")
              (loop (cdr remaining)
                    (+ sequence 1)
                    digest
                    (cons (list event-name subject) history))))))))

(define (sk:append-live-journal-event boundary text successor)
  "Append one unique legal event and return canonical journal bytes."
  (let* ((history (sk:parse-live-journal boundary text))
         (successors
          (sk:live-journal-legal-successors boundary history)))
    (sk:assert-legal-live-journal-successor boundary history successor)
    (ensure (= (count (lambda (candidate) (equal? candidate successor))
                      successors)
               1)
            "live journal successor is not unique")
    (let* ((expected (append history (list successor)))
           (rendered (sk:render-live-journal boundary expected)))
      (ensure (equal? (sk:parse-live-journal boundary rendered) expected)
              "rendered live journal append did not re-parse exactly")
      rendered)))
