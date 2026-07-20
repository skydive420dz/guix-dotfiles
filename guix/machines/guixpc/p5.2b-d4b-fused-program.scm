;;; Build-only expression for the exact published D4a fixture program.

(use-modules (sk system-pruning-fused-artifact))

(define %acceptance-token
  (getenv "SK_P52B_D4B_ACCEPTANCE_TOKEN"))

;; The repository-owned realization gate validates the whole fresh token.
;; This second guard makes an accidental direct `guix build -f' fail before
;; constructing a lowerable object.
(unless
    (and (string? %acceptance-token)
         (string-prefix?
          "p5.2b-d4b-realize/v1|helper="
          %acceptance-token)
         (string-contains %acceptance-token
                          "|snapshot=")
         (string-suffix?
          "|uid=1000|host=guixpc|system=x86_64-linux|lower=1|realize-or-confirm=1|substitutes=0|grafts=0|offload=0|root=none|live-action=none"
          %acceptance-token)
         (not (string-index %acceptance-token #\newline))
         (not (string-index %acceptance-token #\return)))
  (error "D4b exact realization acceptance token is absent"))

(define %repository
  (canonicalize-path
   (dirname
    (dirname
     (dirname
      (dirname (current-filename)))))))

;; This last expression is a file-like object.  Construction is inert; only
;; the token-gated two-phase helper may lower and realize it.
(sk:published-d4a-fused-artifact %repository)
