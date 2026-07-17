;;; Immutable Guix Home wiring for the generated GuixPC theme.

(define-module (sk theme-home)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:export (sk:theme-home-bundle
            sk:theme-home-xdg-configuration-files
            sk:theme-home-xdg-data-files
            sk:theme-home-fish-fragment))

(define %adapter-paths
  '((emacs . "emacs.el")
    (kitty . "kitty.conf")
    (fish . "fish.fish")
    (gtk3 . "gtk3.ini")
    (gtk4 . "gtk4.ini")
    (x-session . "x-session.sh")))

(define (theme-build-module-name? name)
  (or (guix-module-name? name)
      (equal? name '(sk theme))))

(define (sk:theme-home-bundle token-source wallpaper-source)
  "Return an immutable bundle rendered from TOKEN-SOURCE and WALLPAPER-SOURCE.

Both arguments must be file-like objects already captured by Guix.  Rendering
and asset validation happen in the isolated derivation, never by reading the
live checkout, Home directory, profile, display, or network."
  (with-imported-modules
      (source-module-closure
       '((guix build utils)
         (sk theme))
       #:select? theme-build-module-name?)
    (computed-file
     "sk-theme-home-bundle"
     #~(begin
         (use-modules (guix build utils)
                      (ice-9 match)
                      (sk theme))

         (define output #$output)
         (define adapters (string-append output "/adapters"))
         (define wallpaper-relative
           "assets/wallpapers/waifu-cyberpunk.png")

         (define theme
           (call-with-input-file #$token-source sk:read-theme))

         (unless (eq? (assq-ref theme 'kind) 'production)
           (error "Guix Home theme bundle requires production tokens"))

         (mkdir-p adapters)
         (mkdir-p (dirname
                   (string-append output "/" wallpaper-relative)))
         (copy-file #$wallpaper-source
                    (string-append output "/" wallpaper-relative))
         (copy-file #$token-source (string-append output "/tokens.scm"))

         (let ((errors (sk:theme-asset-errors theme output)))
           (unless (null? errors)
             (error "Guix Home theme asset validation failed" errors)))

         (for-each
          (match-lambda
            ((target . contents)
             (let ((name (assq-ref '#$%adapter-paths target)))
               (unless name
                 (error "unmapped generated theme target" target))
               (call-with-output-file
                   (string-append adapters "/" name)
                 (lambda (port)
                   (set-port-encoding! port "UTF-8")
                   (display contents port))))))
          (sk:render-all theme))))))

(define (bundle-file bundle relative)
  (file-append bundle relative))

(define (sk:theme-home-xdg-configuration-files bundle)
  "Return the XDG configuration mappings owned by BUNDLE."
  (map (lambda (entry)
         (list (car entry) (bundle-file bundle (cdr entry))))
       '(("emacs/sk-theme-generated.el" . "/adapters/emacs.el")
         ("kitty/kitty.conf" . "/adapters/kitty.conf")
         ("gtk-3.0/settings.ini" . "/adapters/gtk3.ini")
         ("gtk-4.0/settings.ini" . "/adapters/gtk4.ini")
         ("sk-theme/x-session.sh" . "/adapters/x-session.sh")
         ("sk-theme/tokens.scm" . "/tokens.scm"))))

(define (sk:theme-home-xdg-data-files bundle)
  "Return the XDG data mappings owned by BUNDLE."
  (list
   (list "sk-theme/assets/wallpapers/waifu-cyberpunk.png"
         (bundle-file
          bundle
          "/assets/wallpapers/waifu-cyberpunk.png"))))

(define (sk:theme-home-fish-fragment bundle)
  "Return BUNDLE's generated Fish fragment."
  (bundle-file bundle "/adapters/fish.fish"))
