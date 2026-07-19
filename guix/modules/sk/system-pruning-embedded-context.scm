;;; Pure embedded-input context for a fused System-pruning program.

(define-module (sk system-pruning-embedded-context)
  #:use-module (gcrypt hash)
  #:use-module (guix base16)
  #:use-module (ice-9 rdelim)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:export (assert-transaction-inputs
            read-tsv-string
            transaction-input-paths
            transaction-input-text))

;; Share the transaction error key so legacy and fused drivers retain one
;; closed failure channel across the extracted pure helper boundary.
(define %error-key 'sk-system-pruning-transaction)

(define (%fail format-string . arguments)
  (throw %error-key (apply format #f format-string arguments)))

(define (ensure condition format-string . arguments)
  (unless condition
    (apply %fail format-string arguments)))

(define (safe-relative-path? path)
  (and (string? path)
       (not (string-null? path))
       (not (string-prefix? "/" path))
       (not (string-prefix? "./" path))
       (not (string-suffix? "/" path))
       (not (string-contains path "//"))
       (not
        (any (lambda (component)
               (member component '("." ".." "")))
             (string-split path #\/)))))

(define (records-with-key records key)
  (filter (lambda (record)
            (and (pair? record) (string=? (car record) key)))
          records))

(define (single-record records key fields)
  (let ((matches (records-with-key records key)))
    (ensure (= (length matches) 1)
            "expected one ~a record, found ~a"
            key (length matches))
    (ensure (= (length (car matches)) fields)
            "~a record has the wrong field count"
            key)
    (car matches)))

(define (multi-records records key fields)
  (let ((matches (records-with-key records key)))
    (for-each
     (lambda (record)
       (ensure (= (length record) fields)
               "~a record has the wrong field count"
               key))
     matches)
    matches))

(define (string-sha256 text)
  (bytevector->base16-string
   (bytevector-hash
    (string->utf8 text)
    (hash-algorithm sha256))))

(define (utf8-size text)
  (bytevector-length (string->utf8 text)))

(define (read-tsv-port port source)
  (let loop ((line-number 1)
             (result '()))
    (let ((line (read-line port)))
      (if (eof-object? line)
          (reverse result)
          (begin
            (ensure (not (string-null? line))
                    "blank TSV row at ~a:~a"
                    source line-number)
            (ensure (not (string-index line #\return))
                    "carriage return in TSV row at ~a:~a"
                    source line-number)
            (loop (+ line-number 1)
                  (cons (string-split line #\tab) result)))))))

(define (read-tsv-string text)
  "Parse TEXT as strict TSV without consulting the filesystem."
  (ensure (string? text) "embedded TSV input is not text")
  (call-with-input-string text
    (lambda (port)
      (read-tsv-port port "embedded TSV"))))

(define (transaction-input-paths records)
  "Return the closed repository-relative input paths from manifest RECORDS."
  (append
   (map (lambda (record) (list-ref record 2))
        (multi-records records "implementation-input" 4))
   (list (list-ref (single-record records "crash-registry" 3) 1)
         (list-ref (single-record records "new-grub-source" 4) 1))))

(define (transaction-input-text inputs relative)
  "Return exact text for RELATIVE from the closed INPUTS alist."
  (let ((entry (assoc relative inputs)))
    (ensure entry "embedded transaction input is missing: ~a" relative)
    (cdr entry)))

(define (assert-input-digest inputs relative expected label)
  (let* ((text (transaction-input-text inputs relative))
         (actual (string-sha256 text)))
    (ensure (string=? actual expected)
            "~a SHA256 drift: expected ~a, got ~a"
            label expected actual)))

(define (assert-transaction-inputs records inputs)
  "Validate INPUTS as the exact path-to-text set bound by RECORDS."
  (ensure (list? inputs) "embedded transaction inputs are not a proper list")
  (for-each
   (lambda (entry)
     (ensure (and (pair? entry)
                  (string? (car entry))
                  (string? (cdr entry)))
             "embedded transaction input has invalid shape: ~s"
             entry)
     (ensure (safe-relative-path? (car entry))
             "unsafe embedded transaction input path: ~s"
             (car entry)))
   inputs)
  (let ((actual (map car inputs))
        (expected (transaction-input-paths records)))
    (ensure (= (length actual) (length (delete-duplicates actual)))
            "embedded transaction inputs contain duplicate paths")
    (ensure (= (length expected) (length (delete-duplicates expected)))
            "transaction manifest aliases embedded input paths")
    (ensure (and (= (length actual) (length expected))
                 (every (lambda (path) (member path expected)) actual)
                 (every (lambda (path) (member path actual)) expected))
            "embedded transaction input paths differ from the manifest"))
  (for-each
   (lambda (record)
     (assert-input-digest
      inputs
      (list-ref record 2)
      (list-ref record 3)
      (list-ref record 1)))
   (multi-records records "implementation-input" 4))
  (let* ((source (single-record records "new-grub-source" 4))
         (relative (list-ref source 1))
         (text (transaction-input-text inputs relative))
         (expected-size (string->number (list-ref source 3) 10))
         (actual-size (utf8-size text)))
    (assert-input-digest
     inputs relative (list-ref source 2) "tracked D2b GRUB artifact")
    (ensure (= actual-size expected-size)
            "tracked D2b GRUB artifact size drift: expected ~a, got ~a"
            expected-size actual-size))
  (let ((registry (single-record records "crash-registry" 3)))
    (assert-input-digest
     inputs
     (list-ref registry 1)
     (list-ref registry 2)
     "crash-point registry"))
  inputs)
