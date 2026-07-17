'((schema-version . 2)
  (kind . production)
  (provenance
   (palette-authority . frozen-modus-subset)
   (theme . modus-vivendi-tinted)
   (palette-source . "GNU Emacs 30.2 etc/themes/modus-vivendi-tinted-theme.el")
   (modus-version . "4.4.0")
   (theme-source-sha256 . "4ecca25fc420989fc8520a3717135a60c068f9bc1e575f4a42e1fe5826f0e3dd")
   (core-source-sha256 . "26dc9f44271008ce27c63a97b21835b0ebe1a374660f0ac96b5f931ece23b97a")
   (guix-revision . "a8391f2d7451c2463ba253ffa9872fa6f27485d7")
   (emacs-version . "30.2")
   (mapping-version . 1))
  (roles
   (canvas . "#0d0e1c")
   (surface . "#1d2235")
   (surface-raised . "#4a4f69")
   (text . "#ffffff")
   (text-muted . "#c6daff")
   (text-disabled . "#989898")
   (accent . "#2fafff")
   (on-accent . "#0d0e1c")
   (selection . "#555a66")
   (on-selection . "#ffffff")
   (focus . "#79a8ff")
   (success . "#6ae4b9")
   (warning . "#fec43f")
   (error . "#ff5f59")
   (border . "#61647a")
   (shadow . "#000000")
   (cursor . "#ff66ff")
   (on-cursor . "#0d0e1c"))
  (ansi
   (black . "#000000")
   (red . "#ff5f59")
   (green . "#44bc44")
   (yellow . "#d0bc00")
   (blue . "#2fafff")
   (magenta . "#feacd0")
   (cyan . "#00d3d0")
   (white . "#a6a6a6")
   (bright-black . "#595959")
   (bright-red . "#ff6b55")
   (bright-green . "#00c06f")
   (bright-yellow . "#fec43f")
   (bright-blue . "#79a8ff")
   (bright-magenta . "#b6a0ff")
   (bright-cyan . "#6ae4b9")
   (bright-white . "#ffffff"))
  (typography
   (fixed-family . "JetBrainsMono Nerd Font Mono")
   (ui-family . "JetBrainsMono Nerd Font")
   (ui-size-pt . 11)
   (fallback-families
    "Symbols Nerd Font Mono"
    "Noto Color Emoji"
    "Font Awesome"
    "Material Icons"))
  (desktop
   (color-scheme . dark)
   (gtk3-theme . "Adwaita-dark")
   (gtk4-theme . "Adwaita")
   (icon-theme . "Papirus-Dark")
   (cursor-theme . "Bibata-Modern-Ice")
   (cursor-size-px . 32)
   (logical-dpi . 96)
   (integer-scale . 1)
   (scale-ownership . inherit-verified)
   (gtk4-test-application . "gtk4-widget-factory"))
  (calibrations
   (emacs-face-height-tenths-pt . 120)
   (kitty-font-size-pt . 14.0)
   (picom-emacs-opacity-percent . 85)
   (kitty-background-opacity-ratio . 0.0)
   (kitty-cursor-trail-role . focus))
  (assets
   (wallpaper
    (path . "assets/wallpapers/waifu-cyberpunk.png")
    (fit . zoom)))
  (contrast
   (primary-text-min . 7)
   (secondary-text-min . 9/2)
   (ui-component-min . 3)
   (transparent-hand-test-required? . #t))
  (fish
   (prompt
    (path
     (foreground . text)
     (background . none)
     (attributes))
    (path-background
     (foreground . none)
     (background . surface-raised)
     (attributes))
    (git-branch
     (foreground . accent)
     (background . none)
     (attributes))
    (git-status
     (foreground . text-muted)
     (background . none)
     (attributes))
    (success
     (foreground . success)
     (background . none)
     (attributes))
    (error
     (foreground . error)
     (background . none)
     (attributes)))
   (syntax
    (normal
     (foreground . text)
     (background . none)
     (attributes))
    (command
     (foreground . success)
     (background . none)
     (attributes))
    (keyword
     (foreground . accent)
     (background . none)
     (attributes bold))
    (quote
     (foreground . warning)
     (background . none)
     (attributes))
    (redirection
     (foreground . accent)
     (background . none)
     (attributes bold))
    (end
     (foreground . success)
     (background . none)
     (attributes))
    (error
     (foreground . error)
     (background . none)
     (attributes))
    (param
     (foreground . text)
     (background . none)
     (attributes))
    (valid-path
     (foreground . text)
     (background . none)
     (attributes underline))
    (option
     (foreground . accent)
     (background . none)
     (attributes))
    (comment
     (foreground . text-muted)
     (background . none)
     (attributes italics))
    (selection
     (foreground . on-selection)
     (background . selection)
     (attributes bold))
    (operator
     (foreground . accent)
     (background . none)
     (attributes))
    (escape
     (foreground . warning)
     (background . none)
     (attributes))
    (autosuggestion
     (foreground . text-disabled)
     (background . none)
     (attributes))
    (cancel
     (foreground . error)
     (background . none)
     (attributes reverse))
    (search-match
     (foreground . on-selection)
     (background . selection)
     (attributes bold))
    (history-current
     (foreground . on-selection)
     (background . selection)
     (attributes bold))
    (host
     (foreground . text-muted)
     (background . none)
     (attributes))
    (host-remote
     (foreground . warning)
     (background . none)
     (attributes))
    (status
     (foreground . error)
     (background . none)
     (attributes))
    (cwd
     (foreground . success)
     (background . none)
     (attributes))
    (cwd-root
     (foreground . error)
     (background . none)
     (attributes))
    (user
     (foreground . success)
     (background . none)
     (attributes))
    (background
     (foreground . none)
     (background . canvas)
     (attributes))
    (statement-terminator
     (foreground . accent)
     (background . none)
     (attributes)))
   (pager
    (progress
     (foreground . on-accent)
     (background . accent)
     (attributes bold))
    (background
     (foreground . none)
     (background . surface)
     (attributes))
    (prefix
     (foreground . accent)
     (background . none)
     (attributes bold underline))
    (completion
     (foreground . text)
     (background . none)
     (attributes))
    (description
     (foreground . text-muted)
     (background . none)
     (attributes italics))
    (secondary-background
     (foreground . none)
     (background . surface-raised)
     (attributes))
    (secondary-prefix
     (foreground . accent)
     (background . none)
     (attributes bold))
    (secondary-completion
     (foreground . text)
     (background . none)
     (attributes))
    (secondary-description
     (foreground . text-muted)
     (background . none)
     (attributes italics))
    (selected-background
     (foreground . none)
     (background . selection)
     (attributes))
    (selected-prefix
     (foreground . on-selection)
     (background . selection)
     (attributes bold))
    (selected-completion
     (foreground . on-selection)
     (background . selection)
     (attributes))
    (selected-description
     (foreground . on-selection)
     (background . selection)
     (attributes italics))))
  (targets emacs kitty fish gtk3 gtk4 x-session))
