;;; Immutable artifact constructor for the published D4a fused source.

(define-module (sk system-pruning-fused-artifact)
  #:use-module (gcrypt hash)
  #:use-module (guix base16)
  #:use-module (guix gexp)
  #:use-module (ice-9 textual-ports)
  #:use-module (rnrs bytevectors)
  #:use-module (sk system-pruning-fused-source)
  #:export (sk:d4a-fused-input-identities
            sk:d4a-fused-render-identity
            sk:d4a-fused-renderer-identity
            sk:d4a-source-checkpoint
            sk:fused-artifact-output-name
            sk:load-d4a-fused-inputs
            sk:published-d4a-fused-artifact
            sk:render-d4a-fused-source))

(define %error-key 'sk-system-pruning-fused-artifact)

(define sk:d4a-source-checkpoint
  "41e11155f817c8ccf2f8e8b3c9c62af566f53209")

(define sk:fused-artifact-output-name
  "system-pruning-loaded.scm")

(define sk:d4a-fused-renderer-identity
  '("guix/modules/sk/system-pruning-fused-source.scm"
    "c2b96decd5a85a9764c3c66bb0a72a517599f1b101969f240027a54758f3cb57"
    32667))

(define sk:d4a-fused-render-identity
  '("95b84e29853a2327bffab857383cf78a30ab41b965144fd298edc384335b9d70"
    956987))

;; Each entry is (LABEL REPOSITORY-RELATIVE-PATH SHA256 UTF8-SIZE).
;; The order is the exact `sk:fused-input-labels' order accepted by D4a.
(define sk:d4a-fused-input-identities
  '((root-backend-source
     "guix/modules/sk/system-pruning-root-backend.scm"
     "fd84cf488ba79f1b5c6bb423897b7f90f4752d7eecfc2e262142705a464294e3"
     13468)
    (boundary-source
     "guix/modules/sk/system-pruning-boundary.scm"
     "870482f6131d7e52d3e287dd8b5abe26b0c64a46f34f577dc05232f7e4a1935a"
     37613)
    (orchestrator-source
     "guix/modules/sk/system-pruning-orchestrator.scm"
     "348eb22b794336f89f1f3b02cecb87ee1778334fcade9c53f5f1912dc8906617"
     30636)
    (reconciliation-source
     "guix/modules/sk/system-pruning-reconciliation.scm"
     "dfb55ef748037371c748d5daecbf9264db8f06c212fb16a3f0aaa7ff6b49ce05"
     34373)
    (embedded-context-source
     "guix/modules/sk/system-pruning-embedded-context.scm"
     "9fc9f332d6e4621ecbdbc5380fed703695973009ed41acb1f55c1f59ce99565d"
     6034)
    (transaction-core-source
     "guix/modules/sk/system-pruning-transaction.scm"
     "5177432c05d4382f3da4fafc03c92194220c85b17e0fa638b79e0af6fe3d6bea"
     92784)
    (phase-engine-source
     "guix/modules/sk/system-pruning-phase-engine.scm"
     "43cdf56193558087e69bac5317099dedcd64afa2d63116f1f3d0dba8b7afdde8"
     27609)
    (fixture-runtime-source
     "guix/modules/sk/system-pruning-fixture-runtime.scm"
     "93c017005b54edd7c61937e5dff41384e817832fe3afc48932afb374bf47a200"
     30568)
    (fused-driver-source
     "scripts/guix-system-pruning-fused-driver.scm"
     "4167d51d06abead3871e99f2e8cf9b7c87df297dad717adf7901eb0eb63c1343"
     20829)
    (manifest
     "tests/fixtures/guix-system-pruning-transaction/manifest.tsv"
     "0bf2ce08c06ec4b27053a2f7af3fd5d20c3c37bda2e739a00d0a6c68e6d9ce61"
     6828)
    (crash-registry
     "tests/fixtures/guix-system-pruning-transaction/phase-registry.tsv"
     "bd17a2423d9a0fcea86f3eba23cbb52699379b54853eae510597ed7a160aba86"
     2144)
    (retained-grub
     "docs/audits/data/2026-07-19-p5.2b-d2b-retained-grub.cfg"
     "70965414824c26e1712c6a7a51efd9517633eb3c83f36f88927565c87807496b"
     5163)
    (legacy-driver
     "scripts/guix-system-pruning-transaction.scm"
     "817a35d454bcbcee8b5ed64dcfbd126ee586bc06135eaf3321dbbc80ff78d9e2"
     669)
    (legacy-launcher
     "scripts/guix-system-pruning-transaction"
     "ac54a3de3d4fe60dd15177158c71106fe890363af6cb581b35902120fa11a105"
     4500)
    (profile-lock-holder
     "tests/fixtures/guix-system-pruning-transaction/profile-lock-holder.scm"
     "63855f7fd6edffdcc461af26088658eeb174ba3286192218d38fae7946972b18"
     1059)
    (old-grub-fixture
     "tests/fixtures/guix-system-pruning-transaction/old-grub.cfg"
     "1ac81963a8c65596be9ca3b196396a2025c30cbf3a56b189045756158bf4ef13"
     874)
    (pins-fixture
     "tests/fixtures/guix-system-pruning-transaction/generation-pins.tsv"
     "cffa2f01a6a8083753b71add5624fba25cee6c74e703c77593e35573268dbee4"
     199)
    (efi-fixture
     "tests/fixtures/guix-system-pruning-transaction/efi-sentinel.txt"
     "069c1ed4a330dfd29e78e7ad208cee06316370f341dc3b7029ab6ff44dff4509"
     53)))

(define (%fail format-string . arguments)
  (throw %error-key (apply format #f format-string arguments)))

(define (ensure condition format-string . arguments)
  (unless condition
    (apply %fail format-string arguments)))

(define (text-sha256 text)
  (bytevector->base16-string
   (bytevector-hash (string->utf8 text)
                    (hash-algorithm sha256))))

(define (utf8-size text)
  (bytevector-length (string->utf8 text)))

(define (canonical-repository repository)
  (ensure (and (string? repository)
               (absolute-file-name? repository))
          "repository is not an absolute path: ~s"
          repository)
  (let ((canonical
         (false-if-exception (canonicalize-path repository))))
    (ensure (and canonical
                 (string=? repository canonical)
                 (eq? 'directory (stat:type (lstat canonical))))
            "repository is not one canonical directory: ~s"
            repository)
    canonical))

(define (read-identified-text repository identity)
  (let* ((label (car identity))
         (relative (list-ref identity 1))
         (expected-sha (list-ref identity 2))
         (expected-size (list-ref identity 3))
         (file (string-append repository "/" relative)))
    (ensure (and (file-exists? file)
                 (eq? 'regular (stat:type (lstat file))))
            "D4a input is not a repository-owned regular file: ~a"
            relative)
    (let ((text (call-with-input-file file get-string-all)))
      (ensure (string=? (text-sha256 text) expected-sha)
              "D4a input SHA256 drift: ~a"
              relative)
      (ensure (= (utf8-size text) expected-size)
              "D4a input UTF-8 size drift: ~a"
              relative)
      (cons label text))))

(define (sk:load-d4a-fused-inputs repository)
  "Load the exact published D4a renderer inputs from REPOSITORY.

This source-only operation performs no lowering, store connection, build, or
realization.  It rejects any renderer or input byte drift before returning the
closed association list accepted by `sk:render-fused-program'."
  (let* ((repo (canonical-repository repository))
         (renderer
          (read-identified-text
           repo
           (cons 'renderer sk:d4a-fused-renderer-identity)))
         (inputs
          (map (lambda (identity)
                 (read-identified-text repo identity))
               sk:d4a-fused-input-identities)))
    (ensure (eq? (car renderer) 'renderer)
            "D4a renderer identity label drift")
    (ensure (equal? (map car sk:d4a-fused-input-identities)
                    sk:fused-input-labels)
            "D4a artifact input labels or order drift")
    (sk:assert-fused-inputs inputs)))

(define (sk:render-d4a-fused-source repository)
  "Render the exact published D4a fixture program without a store operation."
  (sk:render-fused-program
   (sk:load-d4a-fused-inputs repository)))

(define (fused-artifact inputs)
  "Return one inert computed-file for already validated fixture INPUTS.

Constructing this file-like object does not lower or realize it.  A separate
`guix build -f' expression owns that explicit D4b boundary."
  (let ((rendered (sk:render-fused-program inputs)))
    (ensure
     (string=? (text-sha256 rendered)
               (car sk:d4a-fused-render-identity))
     "rendered D4a artifact SHA256 drift")
    (ensure
     (= (utf8-size rendered)
        (cadr sk:d4a-fused-render-identity))
     "rendered D4a artifact UTF-8 size drift")
    (computed-file
     sk:fused-artifact-output-name
     #~(begin
         (call-with-output-file #$output
           (lambda (port)
             (set-port-encoding! port "UTF-8")
             (display #$rendered port)))
         (chmod #$output #o555))
     #:local-build? #t
     #:options '(#:graft? #f
                 #:substitutable? #f))))

(define (sk:published-d4a-fused-artifact repository)
  "Return the one computed-file built only from published D4a REPOSITORY.

No public constructor accepts an alternate input set.  This exact entry point
revalidates the frozen renderer plus all 18 fused inputs before it constructs
the inert file-like object."
  (fused-artifact
   (sk:load-d4a-fused-inputs repository)))
