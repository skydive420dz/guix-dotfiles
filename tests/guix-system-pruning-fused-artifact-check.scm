;;; Source-only checks for the D4b computed-file construction.

(use-modules (gcrypt hash)
             (guix base16)
             (guix gexp)
             (ice-9 textual-ports)
             (rnrs bytevectors)
             (sk system-pruning-fused-artifact))

(define %program "guix-system-pruning-fused-artifact-check")

(define (fail format-string . arguments)
  (format (current-error-port)
          "~a: FAIL: ~a~%"
          %program
          (apply format #f format-string arguments))
  (exit 1))

(define (assert condition format-string . arguments)
  (unless condition
    (apply fail format-string arguments)))

(define (assert-equal actual expected label)
  (assert (equal? actual expected)
          "~a: expected ~s, got ~s"
          label expected actual))

(define (text-sha256 text)
  (bytevector->base16-string
   (bytevector-hash (string->utf8 text)
                    (hash-algorithm sha256))))

(define (repo-text repository relative)
  (call-with-input-file
      (string-append repository "/" relative)
    get-string-all))

(define (identity-table-text identities)
  (apply
   string-append
   (map
    (lambda (identity)
      (format #f "~a\t~a\t~a\t~a~%"
              (list-ref identity 0)
              (list-ref identity 1)
              (list-ref identity 2)
              (list-ref identity 3)))
    identities)))

(define (tree-count tree expected)
  (cond
   ((pair? tree)
    (+ (tree-count (car tree) expected)
       (tree-count (cdr tree) expected)))
   ((equal? tree expected) 1)
   (else 0)))

(define (subform-count tree predicate)
  (+ (if (predicate tree) 1 0)
     (if (pair? tree)
         (+ (subform-count (car tree) predicate)
            (subform-count (cdr tree) predicate))
         0)))

(define arguments (cdr (command-line)))
(unless (= (length arguments) 2)
  (fail "expected canonical repository and clean-git HEAD arguments"))

(define repository (car arguments))
(define repository-head (cadr arguments))
(assert (and (absolute-file-name? repository)
             (string=?
              repository
              (canonicalize-path repository)))
        "repository is not canonical and absolute")
(assert (= (string-length repository-head) 40)
        "clean-git repository HEAD has the wrong length")
(assert-equal sk:d4a-source-checkpoint
              "41e11155f817c8ccf2f8e8b3c9c62af566f53209"
              "frozen D4a checkpoint constant")
(assert-equal
 sk:d4a-fused-renderer-identity
 '("guix/modules/sk/system-pruning-fused-source.scm"
   "c2b96decd5a85a9764c3c66bb0a72a517599f1b101969f240027a54758f3cb57"
   32667)
 "published renderer identity")
(assert-equal (length sk:d4a-fused-input-identities)
              18
              "published fused-input identity count")
(assert-equal
 (text-sha256
  (identity-table-text sk:d4a-fused-input-identities))
 "b95f52ccc7da4a965e0d8e25822a67785d2482dfab610b29652a27c4bfc6bc7e"
 "published fused-input identity table")

;; The loader independently checks all 19 path/digest/size records and the
;; manifest's own closed 17-input binding before it returns.
(define inputs (sk:load-d4a-fused-inputs repository))
(assert-equal (map car inputs)
              (map car sk:d4a-fused-input-identities)
              "loaded published input labels")
(define rendered-a (sk:render-d4a-fused-source repository))
(define rendered-b
  (sk:render-d4a-fused-source repository))

(assert-equal rendered-a rendered-b "deterministic source-only render")
(assert-equal
 sk:d4a-fused-render-identity
 '("95b84e29853a2327bffab857383cf78a30ab41b965144fd298edc384335b9d70"
   956987)
 "published D4a rendered-source identity")
(assert-equal (text-sha256 rendered-a)
              (car sk:d4a-fused-render-identity)
              "published D4a rendered-source SHA256")
(assert-equal (bytevector-length (string->utf8 rendered-a))
              (cadr sk:d4a-fused-render-identity)
              "published D4a rendered-source UTF-8 size")
(assert (string-suffix? "\n" rendered-a)
        "rendered source lacks one terminal LF")
(assert (not (string-index rendered-a #\return))
        "rendered source contains CR")

(define artifact
  (sk:published-d4a-fused-artifact repository))
(assert (computed-file? artifact)
        "constructor did not return one computed-file")
(assert-equal (computed-file-name artifact)
              "system-pruning-loaded.scm"
              "computed-file output name")
(assert-equal sk:fused-artifact-output-name
              "system-pruning-loaded.scm"
              "frozen output-name constant")
(assert-equal (computed-file-options artifact)
              '(#:local-build? #t
                #:graft? #f
                #:substitutable? #f)
              "computed-file lowering options")
(define artifact-interface
  (resolve-interface '(sk system-pruning-fused-artifact)))
(assert (not (module-variable artifact-interface 'fused-artifact))
        "generic input-taking constructor escaped the module interface")
(assert (procedure?
         (module-ref artifact-interface
                     'sk:published-d4a-fused-artifact))
        "exact repository-taking constructor is not exported")

;; This is an inert structural projection.  It does not call `lower-object',
;; open a store connection, create a derivation, or realize an output.
(define builder
  (gexp->approximate-sexp
   (computed-file-gexp artifact)))

(assert (= (tree-count builder 'call-with-output-file) 1)
        "builder does not open exactly one output")
(assert (= (tree-count builder 'set-port-encoding!) 1)
        "builder does not select UTF-8 exactly once")
(assert (= (tree-count builder 'display) 1)
        "builder does not write the rendered source exactly once")
(assert (= (tree-count builder 'chmod) 1)
        "builder does not set output mode exactly once")
(assert
 (= (subform-count
     builder
     (lambda (form)
       (and (list? form)
            (= (length form) 3)
            (eq? (car form) 'chmod)
            (= (caddr form) #o555))))
    1)
 "builder does not set exact executable/read-only mode 0555")
(assert (= (tree-count builder rendered-a) 1)
        "builder does not contain the exact rendered source once")
(assert (= (tree-count builder '*approximate*) 2)
        "output placeholder escaped its write/mode-only boundary")

(for-each
 (lambda (forbidden)
   (assert (= (tree-count builder forbidden) 0)
           "builder contains forbidden store/mutation capability: ~a"
           forbidden))
 '(computed-file
   gexp->derivation
   lower-object
   with-store
   open-connection
   built-derivations
   add-temp-root
   add-indirect-root
   delete-file
   rename-file
   mkdir))

(define artifact-source
  (repo-text
   repository
   "guix/modules/sk/system-pruning-fused-artifact.scm"))
(for-each
 (lambda (forbidden)
   (assert (not (string-contains artifact-source forbidden))
           "artifact source contains forbidden lowering capability: ~a"
           forbidden))
 '("gexp->derivation"
   "lower-object"
   "with-store"
   "open-connection"
   "built-derivations"))

(define build-expression-source
  (repo-text
   repository
   "guix/machines/guixpc/p5.2b-d4b-fused-program.scm"))
(assert (string-contains
         build-expression-source
         "(sk:published-d4a-fused-artifact")
        "build expression does not return the reviewed file-like object")
(assert (string-contains
         build-expression-source
         "(getenv \"SK_P52B_D4B_ACCEPTANCE_TOKEN\")")
        "build expression lacks its accidental-direct-lowering guard")
(assert (string-contains
         build-expression-source
         "p5.2b-d4b-realize/v1|helper=")
        "build expression does not bind the reviewed token schema")
(assert (string-contains
         build-expression-source
         "|root=none|live-action=none")
        "build expression token scope does not forbid roots/live action")
(assert (not (string-contains
              build-expression-source
              "(sk:load-d4a-fused-inputs"))
        "build expression exposes an alternate input-taking path")
(for-each
 (lambda (forbidden)
   (assert (not (string-contains build-expression-source forbidden))
           "build expression contains direct lowering capability: ~a"
           forbidden))
 '("gexp->derivation"
   "lower-object"
   "with-store"
   "open-connection"
   "built-derivations"))

(format #t "schema\tp5.2b-d4b-fused-artifact-source/v1~%")
(format #t "mode\tSOURCE-ONLY~%")
(format #t "authorization\tNOT-GRANTED~%")
(format #t "source-checkpoint\t~a~%" sk:d4a-source-checkpoint)
(format #t "repository-head\t~a~%" repository-head)
(format #t "input-identities\t19~%")
(format #t "rendered-source-sha256\t~a~%"
        (text-sha256 rendered-a))
(format #t "rendered-source-bytes\t~a~%"
        (bytevector-length (string->utf8 rendered-a)))
(format #t "computed-file-name\t~a~%"
        (computed-file-name artifact))
(format #t "lowered\tFALSE~%")
(format #t "realized\tFALSE~%")
(format #t "~a: PASS~%" %program)
